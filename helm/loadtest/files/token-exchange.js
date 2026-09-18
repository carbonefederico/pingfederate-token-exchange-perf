import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
// NOTE: no `import crypto from 'k6/crypto'` — that legacy module shadows the
// global WebCrypto `crypto` object that provides `crypto.subtle`.

const successRate = new Rate('token_exchange_success');
const latency = new Trend('token_exchange_latency', true);
const oauthErrors = new Counter('token_exchange_oauth_errors');

const required = ['PF_TOKEN_URL', 'CLIENT_ID', 'CLIENT_SECRET', 'SUBJECT_SIGNING_KEY'];
for (const key of required) {
  if (!__ENV[key]) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
}

const totalRate = Number(__ENV.TOTAL_RATE || __ENV.RATE || 50);
const agentCount = Number(__ENV.AGENT_COUNT || 1);
const agentIndex = Number(__ENV.AGENT_INDEX || 0);
if (agentIndex >= agentCount) {
  throw new Error(`AGENT_INDEX (${agentIndex}) must be less than AGENT_COUNT (${agentCount})`);
}
// Each agent drives its share of the total rate.
const rate = Math.max(1, Math.round(totalRate / agentCount));

const preAllocatedVUs = Number(__ENV.PRE_ALLOCATED_VUS || 25);
const maxVUs = Number(__ENV.MAX_VUS || 200);
const p95Ms = Number(__ENV.P95_MS || 500);
const minimumSuccessRate = Number(__ENV.SUCCESS_RATE || 0.99);

// Subject tokens are self-signed (RS256) inside each iteration. The private
// key is the predefined key whose public JWKS the PingFederate profile
// validates against; claims rotate so no two requests carry the same token.
const subjectIssuer = __ENV.SUBJECT_ISSUER || 'https://pf-perf-subject';
const subjectAudience = __ENV.SUBJECT_AUDIENCE || __ENV.CLIENT_ID;
const userCount = Number(__ENV.SUBJECT_USER_COUNT || 100);
const tokenLifetimeSec = Number(__ENV.SUBJECT_TOKEN_LIFETIME || 300);

// k6's WebCrypto needs the DER bytes of the PKCS#8 key: strip PEM armor and
// base64-decode once at init time.
const pkcs8Der = new Uint8Array(
  encoding.b64decode(
    __ENV.SUBJECT_SIGNING_KEY
      .replace(/-----[^-]+-----/g, '')
      .replace(/\s+/g, ''),
    'std',
  ),
);
// Import once per VU would still be per-iteration under constant-arrival-rate;
// instead import lazily and cache the CryptoKey promise.
let signingKeyPromise = null;
function getSigningKey() {
  if (!signingKeyPromise) {
    signingKeyPromise = crypto.subtle.importKey(
      'pkcs8',
      pkcs8Der,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['sign'],
    );
  }
  return signingKeyPromise;
}

function b64urlJson(object) {
  return encoding.b64encode(JSON.stringify(object), 'rawurl');
}

// Build and sign one RS256 subject token. Returns a promise resolving to
// the compact JWT.
async function buildSubjectToken(vu, iter) {
  const now = Math.floor(Date.now() / 1000);
  const userIndex = (iter + vu) % userCount;
  const header = { alg: 'RS256', typ: 'JWT', kid: 'perf-subject-key' };
  const payload = {
    iss: subjectIssuer,
    sub: `perf-user-${String(userIndex + 1).padStart(3, '0')}`,
    // With per-agent clients, the subject token's audience is the agent's
    // own client id (the profile lists all ten as allowed audiences).
    aud: __ENV.PER_AGENT_CLIENTS === 'true' && __ENV.AGENT_INDEX !== undefined
      ? `perf-agent-${__ENV.AGENT_INDEX}`
      : subjectAudience,
    iat: now,
    exp: now + tokenLifetimeSec,
    jti: `${vu}-${iter}-${now}`,
  };
  const signingInput = `${b64urlJson(header)}.${b64urlJson(payload)}`;
  const key = await getSigningKey();
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${encoding.b64encode(signature, 'rawurl')}`;
}

export const options = {
  insecureSkipTLSVerify: (__ENV.INSECURE_SKIP_TLS_VERIFY || 'false') === 'true',
  discardResponseBodies: false,
  scenarios: {
    // Warmup: full-rate ramp that fills connection pools and lets the JVM
    // JIT-compile hot paths. Its traffic is tagged and excluded from the
    // measured thresholds; the measured scenario starts after it finishes.
    warmup: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: __ENV.WARMUP || '30s',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '5s',
      exec: 'warmupIteration',
      tags: { phase: 'warmup' },
      startTime: '0s',
    },
    token_exchange: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs,
      maxVUs,
      gracefulStop: '30s',
      // Starts once the warmup scenario has finished.
      startTime: __ENV.WARMUP || '30s',
      tags: { phase: 'measured' },
    },
  },
  thresholds: {
    // Thresholds apply to the aggregate; the measured scenario's metrics are
    // what the report reads — warmup traffic is tagged phase=warmup and
    // excluded by the report generator.
    token_exchange_success: [`rate>=${minimumSuccessRate}`],
    token_exchange_latency: [`p(95)<${p95Ms}`],
    http_req_failed: ['rate<0.01'],
    // Dropped iterations invalidate a stress stage: when required concurrency
    // (rate x latency) exceeds maxVUs, k6 silently sheds load and latency
    // looks fine because the excess requests were never sent. Any drop
    // fails the stage — count per agent (the metric is per-agent aggregate,
    // warmup included; a nonzero count means the generator shed load).
    dropped_iterations: ['count==0'],
  },
  tags: {
    system_under_test: 'pingfederate',
    operation: 'token_exchange',
  },
};

function addIfPresent(body, key, value) {
  if (value) body[key] = value;
}

// Warmup iterations run the same measured path — they warm connections, JIT
// and caches — but their metric points carry phase=warmup so the report can
// exclude them.
export async function warmupIteration() {
  await doExchange();
}

export default async function () {
  await doExchange();
}

async function doExchange() {
  // Fresh self-signed subject token per iteration; users rotate round-robin
  // so consecutive requests authenticate different subjects.
  const subjectToken = await buildSubjectToken(__VU, __ITER);

  // One OAuth client per agent: perf-agent-<AGENT_INDEX>. The profile
  // provisions matching clients; CLIENT_ID is the base name. With the
  // default single-client profile (CLIENT_ID unchanged), agents share it.
  let clientId = __ENV.CLIENT_ID;
  if (__ENV.PER_AGENT_CLIENTS === 'true' && __ENV.AGENT_INDEX !== undefined) {
    clientId = `perf-agent-${__ENV.AGENT_INDEX}`;
  }

  const body = {
    grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token: subjectToken,
    subject_token_type: __ENV.SUBJECT_TOKEN_TYPE || 'urn:ietf:params:oauth:token-type:access_token',
    requested_token_type: __ENV.REQUESTED_TOKEN_TYPE || 'urn:ietf:params:oauth:token-type:access_token',
  };

  addIfPresent(body, 'resource', __ENV.RESOURCE);
  addIfPresent(body, 'audience', __ENV.AUDIENCE);
  addIfPresent(body, 'scope', __ENV.SCOPE);
  addIfPresent(body, 'actor_token', __ENV.ACTOR_TOKEN);
  if (__ENV.ACTOR_TOKEN) {
    body.actor_token_type = __ENV.ACTOR_TOKEN_TYPE || 'urn:ietf:params:oauth:token-type:access_token';
  }

  const params = {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    tags: { name: 'POST /as/token.oauth2' },
    timeout: __ENV.REQUEST_TIMEOUT || '30s',
  };

  if ((__ENV.CLIENT_AUTH_METHOD || 'client_secret_basic') === 'client_secret_post') {
    body.client_id = clientId;
    body.client_secret = __ENV.CLIENT_SECRET;
  } else {
    params.headers.Authorization = `Basic ${encoding.b64encode(`${clientId}:${__ENV.CLIENT_SECRET}`)}`;
  }

  const response = http.post(__ENV.PF_TOKEN_URL, body, params);
  latency.add(response.timings.duration);

  let payload = null;
  try {
    payload = response.json();
  } catch (_) {
    // The checks below report a non-JSON response without logging token material.
  }

  const ok = check(response, {
    'HTTP status is 200': (r) => r.status === 200,
    'response contains access_token': () => Boolean(payload && payload.access_token),
    'response contains issued_token_type': () => Boolean(payload && payload.issued_token_type),
  });

  successRate.add(ok);
  if (!ok) oauthErrors.add(1);
}
