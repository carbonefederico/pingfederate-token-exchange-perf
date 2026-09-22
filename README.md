# PingFederate token-exchange performance test

This project deploys the following Ping Identity Kubernetes topology and drives RFC 8693 token exchange from inside the cluster:

- 1 PingFederate administration Pod
- 2 PingFederate engine Pods behind one Kubernetes Service
- 1 disposable k6 Job generating a constant arrival rate (or N parallel agent Pods with a profile)

The load is sent directly to the engine Service on port 9031. Administration traffic on port 9999 is not part of the benchmark.

Subject tokens are **self-signed by the load generator** (RS256 with the predefined key in `keys/subject-signing.key`) and validated by PingFederate, which **fetches the matching public JWKS over HTTP** from an in-cluster endpoint (`http://perf-jwks-server/jwks.json`, deployed with the loadtest chart) — the production-shaped issuer-publishes/verifier-fetches key distribution, with PF's JWKS fetch, caching, and refresh on the measured path. User authentication is not part of the measurement. Each request carries a freshly signed token whose subject rotates through 100 synthetic users, so no token is ever replayed. The PingFederate side (token processor, access token manager, token exchange policy, OAuth client) is declarative: the server profile carries it as `instance/bulk-config/data.json.subst`, which the PF image imports at startup — see `docs/pingfederate-configuration.md`.

## Scope of this campaign

This campaign is a **baseline characterization** of the RFC 8693 token-exchange path at fixed reference load levels up to **500 exchanges/second**: token-endpoint latency (p50/p90/p95/max), achieved throughput, error rate, and PingFederate pod CPU/memory, measured over five-minute steady windows at each reference level.

**Deliberately out of scope — this data does not support conclusions about:**

- the saturation point, maximum sustainable throughput, capacity, headroom, or recommended operating limits — no reference level is run to failure;
- behavior above 500 exchanges/second;
- overload, burst, failure, and recovery behavior;
- autoscaling (the engine topology is fixed at two pods);
- deployments whose token path adds persistent-store access or opaque subject-token validation — for those, these results are a floor, not a measurement (see Benchmark assumptions).

The bound is a design decision, not an omission: the cluster is shared with workloads this project does not own, and deliberately driving co-tenants toward a failure point is not authorized. Reference levels are therefore fixed points, measured as-is, and load stops there. Capacity conclusions would require a separate campaign on isolated infrastructure.

### Reference results — campaign of 2026-09-21/22 (lab namespace, r5.xlarge nodes, n=3 per level)

| Stage | Target rate | Requests | avg | median | p90 | p95 | p99 |
|---|---|---:|---:|---:|---:|---:|---:|
| 100/s | 100.0% achieved | 30,008 | 5.42 ms | 5.06 ms | 6.91 ms | 7.54 ms | 9.72 ms |
| 250/s | 100.0% achieved | 75,007 | 5.23 ms | 4.77 ms | 6.63 ms | 7.44 ms | 10.80 ms |
| 500/s | 100.0% achieved | 150,008 | 5.88 ms | 5.33 ms | 7.70 ms | 9.51 ms | 15.31 ms |


Protocol: three ascending rounds (100 → 250 → 500, ×3); each row is the **median
run** of its three, selected by measured p95. Per-run p95s — 100/s:
7.23/7.54/7.72 ms · 250/s: 7.31/7.44/8.09 ms · 500/s: 9.03/9.51/10.01 ms
(median runs: `20260922100552`, `20260922094734`, `20260922095635`). All nine
runs passed the generator-health gates (zero dropped iterations, 100% achieved
rate, 100% success). Every latency column comes from the same measured window
(warmup excluded), pooled across all ten agents. The Requests column includes
the graceful-stop tail — a few iterations complete just past the 300 s window,
hence 30,008 rather than 30,000. The 30 s-cadence ~2 ms latency wave
(Benchmark assumption 6) is inside these numbers. The full per-run HTML
reports are published in `reports/` — throughput, latency, latency-breakdown,
engine and node CPU over time, per-agent details. Latency grows monotonically
across the tested range; behavior above 500/s is untested (Scope of this
campaign).

### Measurement basis

- Each reference level is run **three times per campaign**, in ascending rounds (100 → 250 → 500, repeated three times). The rounds — not three consecutive runs per level — distribute time-of-campaign evenly across levels, so environmental drift shows up as run-to-run spread rather than hiding inside one level's number. The README's reference table reports the **median run** of the three, selected by measured p95; the per-run p95s are quoted alongside it. Three consecutive rounds characterize short-term repeatability on one cluster state — they do not establish statistical significance or day-to-day variance.
- A run is included only if it passed the generator-health gates: zero dropped iterations, achieved rate ≥ 98% of target, success ≥ threshold. A run that fails a gate is rerun and both attempts are recorded — never silently swapped or averaged in.
- The first run after a fresh deployment is discarded by protocol: the engines are warmed with one throwaway sanity run (the `.env` defaults) before the campaign's first round, so every counted run satisfies the continuously-warmed assumption (Benchmark assumption 5) identically.
- Every latency column in the reference table (avg/median/p90/p95/p99) is computed from the **same measured window**: all raw datapoints of the measured scenario, pooled across all ten agents, warmup excluded. These values are recorded per run in `results/<run_id>/summary.json` (`pooled_latency`) and rendered into the per-run report published in `reports/` — the README table is reproducible from the reports.
- The achieved rate is part of the result, not an assumption: k6's `dropped_iterations` and the achieved-vs-target percentage are recorded with every run. A run that dropped iterations measured less load than its target rate — do not quote it at the target rate.
- The nodes are shared: co-tenant load during a run is visible in the report's node-CPU panel and is an uncontrolled environmental factor.

## Prerequisites

- Kubernetes cluster and a working `kubectl` context
- Helm 3
- Ping DevOps user/key or an equivalent licensed image setup
- A git repository to host the server profile (push `server-profiles/` there)
- `python3` and `openssl` for `make keys` and the smoke test
- Metrics Server if you want `make monitor`

The project pins the official Ping chart to `0.15.0` and the k6 image to `2.2.0`. Change these in `.env` and `helm/loadtest/values.yaml` deliberately when upgrading.

## Repository layout

```
helm/pingfederate/     Values for Ping's official ping-devops chart: 1 admin + 2
                       engine Pods, anti-affinity across nodes, lab sizing.
helm/jwks-server/      The JWKS endpoint PF fetches its verification keys from
                       (nginx, TLS) — its own release so the key source survives
                       loadtest reinstalls.
helm/loadtest/         The k6 agent chart: an indexed Job, N parallel agent Pods,
                       each running the same script (helm/loadtest/files/…) with
                       its share of the total rate.
server-profiles/       The PingFederate server profile: instance/bulk-config/
                       data.json.subst is the declarative configuration imported
                       at every admin startup; instance/server/default/data/
                       carries the public JWKS and the JWKS endpoint's TLS cert
                       (both committed; keys/ for the private halves is
                       git-ignored). Push this directory to your own repo.
profiles/              Load profiles: stage-100/250/500.env (the campaign
                       ladder) and agents.env. Each fully describes its run —
                       RATE, AGENTS, thresholds, RFC 8693 parameters.
scripts/               One script per make target: deploy, verify, smoke,
                       run-in-cluster (the k6 Job + result collection), monitor,
                       generate-report.py.
results/               Per-run working artifacts, one directory per run: per-agent
                       k6 logs and metric streams, env.json, the pod-usage CSV,
                       report.html + summary.json. Large and lab-local (not in
                       version control); the published layer is reports/.
reports/               The published HTML reports, one per run of the reference
                       campaign (self-contained, no external resources). This is
                       the only result layer in version control — what a
                       reviewer is pointed at; every chart's underlying numbers
                       come from the per-run measured-window statistics.
docs/                  The PF-side configuration in depth (objects, claims,
                       JWKS URL mode).
.env                   Your lab's credentials and endpoints — git-ignored, never
                       committed (see .env.example for the documented shape).
```

Configuration flows one way: `.env` → `make deploy` (jwks-server release, then PingFederate whose pods clone the server profile and import the bulk config at startup) → profiles select a reference level → `results/` accumulates one directory per run, which `generate-report.py` turns into the HTML report published in `reports/`.

## Quick start

Every command runs **on your workstation, from this project root**. Nothing is run by hand inside the cluster: the `make` targets read `.env` and drive `kubectl`/`helm` against your cluster context themselves. During the campaign you will use two terminals side by side; both are on the workstation.

Kubernetes namespace: all `make` targets use `NAMESPACE` from `.env` (default `pf-perf`). The raw `kubectl` examples below use `<ns>` — substitute yours. (If you drive the cluster from a Claude Code session, prefix cluster commands with `!` so they run in your shell rather than the agent's.)

### Step 0 — one-time setup (workstation)

1. **Fill in `.env`** (`cp .env.example .env`). Required values:
   - `PING_IDENTITY_DEVOPS_USER` / `PING_IDENTITY_DEVOPS_KEY` — Ping DevOps credentials (eval license).
   - `SERVER_PROFILE_URL` / `SERVER_PROFILE_PATH` — your profiles repo (step 3 below).
   - `CLIENT_SECRET` **and** `PERF_CLIENT_SECRET` — the same value twice: the bulk import creates the OAuth clients with `PERF_CLIENT_SECRET`, and k6 authenticates with `CLIENT_SECRET`.
   - `PERF_SSL_SERVER_P12_PASSWORD` — and generate the SSL keypair it protects with the `openssl` command documented in `.env.example` (`make deploy` fails without that p12 file).
   - `NAMESPACE` if not using the default.
2. **Generate the key material**: `make keys`. This creates, once and stable across the whole campaign:
   - `keys/subject-signing.key` — private RSA key, git-ignored, loaded into the k6 pods (signs every subject token);
   - `instance/server/default/data/perf-subject-jwks.json` — the matching public JWKS, committed to the server profile;
   - `keys/jwks-server-tls.key` + `instance/.../perf-jwks-server.crt` — TLS material for the in-cluster JWKS endpoint (PF imports the cert into its truststore at startup).
3. **Push the server profile**: commit and push `server-profiles/pingfederate-token-exchange/` to a git repository you own, then set `SERVER_PROFILE_URL` / `SERVER_PROFILE_PATH` / `SERVER_PROFILE_BRANCH` in `.env`. This step is mandatory, not a convenience: PingFederate's pods clone the profile from that repo at startup, which is how the JWKS and the TLS cert reach PingFederate.

### Step 1 — deploy (workstation; one command, ~10 minutes)

```bash
make validate   # lint the charts and scripts
make deploy     # deploys, in order: jwks-server → PingFederate admin + 2 engines
make verify     # confirms exactly 2 engine pods are Running and Ready
```

`make deploy` installs three Helm releases into your namespace: the **jwks-server** (nginx serving the subject-token verification JWKS over HTTPS), the **PingFederate admin**, and the **two engine pods**. The profile's bulk config then configures PF automatically at admin startup (token processor in JWKS-URL mode, access token manager, token-exchange policy, one OAuth client per agent). Confirm the import succeeded:

```bash
kubectl -n <ns> logs deploy/pf-pingfederate-admin -c pingfederate-admin | grep -i bulk
```

`INFO: Removing Imported Bulk File` = success; anything else prints the API error per failed item.

### Step 2 — smoke test (one manual exchange, from the workstation)

The smoke test runs from your workstation and needs a local path to the engines, so temporarily point `PF_TOKEN_URL` at the port-forward in `.env`:

```text
PF_TOKEN_URL=https://localhost:9031/as/token.oauth2
```

Then, with two terminals:

```bash
# Terminal A — keep running while you smoke-test:
kubectl -n <ns> port-forward service/pf-pingfederate-engine 9031:9031

# Terminal B:
make smoke
```

It signs a subject JWT locally and exchanges it; you get the response minus token material. **Then revert `PF_TOKEN_URL` to the in-cluster value (`https://pf-pingfederate-engine:9031/as/token.oauth2`) before running load** — the k6 pods resolve PF through the cluster DNS, and a forgotten localhost value makes every k6 pod fail against itself.

### Step 3 — run the campaign (two terminals, both on your workstation)

```bash
# Terminal A — resource monitor; leave running for the whole campaign:
make monitor
# writes results/pod-usage-<UTC>.csv (per-pod and per-node CPU/memory every 5s)

# Terminal B — the reference levels, in ascending order:
make test PROFILE=stage-250
make test PROFILE=stage-500
```

Each `make test` does the whole stage by itself: provisions the k6 Job (10 agent pods at the profile's rate), waits for it, streams progress, captures every agent's metric stream and end-of-run summary plus a full `env.json` of run settings into `results/<run_id>/`, and exits non-zero if any k6 threshold failed. Do not run a level above the campaign bound (500/s) — see "Scope of this campaign".

`make test` without a `PROFILE` runs the `.env` defaults (50/s, 1 agent) — useful as a post-deploy sanity run before the real stages.

### Step 4 — report

```bash
make report RUN=<run_id>   # omit RUN to use the newest results directory
```

Writes `results/<run_id>/report.html` (throughput, latency, latency breakdown, engine and node CPU over time) and `summary.json` (pooled p95, success rate, achieved-vs-target, verdict) next to the raw streams. The PASS/FAIL verdict applies the profile's thresholds plus the generator-health gates (zero dropped iterations, ≥98% achieved rate) to the measured window only.

### Example exchange (request and response)

One measured exchange — every k6 iteration performs exactly this. Secrets
are redacted; tokens are truncated for print.

Request (the subject token is signed by the load generator, RS256):

```http
POST /as/token.oauth2 HTTP/2
Host: pf-pingfederate-engine:9031
Authorization: Basic cGVyZi1hZ2VudC0zOjxwZXJmX2NsaWVudC1zZWNyZXQ->
Content-Type: application/x-www-form-urlencoded

grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange
&subject_token=eyJhbGciOiAiUlMyNTYiLCAidHlwIjogIkpXVCIs…[611 chars]
&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token
&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token
&resource=https%3A%2F%2Fmcp.example.internal%2Fmcp
&scope=mcp%3Atools%3Ainvoke
```

The subject token's claims (decoded):

```json
{
  "iss": "https://pf-perf-subject",
  "sub": "perf-user-042",
  "aud": "perf-agent-3",
  "iat": 1789978138,
  "exp": 1789978438,
  "jti": "mcp-final-1"
}
```

Response:

```http
HTTP/2 200
content-type: application/json

{
  "access_token": "eyJhbGciOiJSUzI1NiIsImtpZCI6ImVqT00tTU9X…[753 chars]",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 299
}
```

The issued access token is an RS256 `at+jwt` signed with PingFederate's
centralized signing key. Header (decoded):

```json
{
  "alg": "RS256",
  "kid": "ejOM-MOWkc272nB1UwDyUGPasY4_RS256",
  "pi.atm": "8dzf",
  "typ": "at+jwt"
}
```

Payload (decoded):

```json
{
  "scope": "mcp:tools:invoke",
  "authorization_details": [],
  "client_id": "perf-agent-3",
  "iss": "https://pf-pingfederate-engine",
  "iat": 1789978138,
  "sub": "perf-user-042",
  "aud": "https://mcp.example.internal/mcp",
  "act": {
    "sub": "perf-agent-3"
  },
  "exp": 1789978438
}
```

Reading the claims: `sub` is the subject user, taken from the subject
token's `sub` through the token-exchange processor policy; `act.sub` is the
**authenticated client id**, built by the access-token mapping's OGNL from
`context.ClientId` — the caller never sends actor material; `aud` is the
**requested resource URI** — the `resource=` parameter selects the token
manager (RFC 8707; an unmatched URI is rejected with `invalid_target`) and
the same value is fulfilled into the `aud` claim, so the token is
audience-restricted to the target MCP server; `scope` carries the requested
scope (registered in the OAuth server settings, here `mcp:tools:invoke`);
`exp - iat` is the token manager's 5-minute lifetime.

## Load profiles

A profile is a self-contained file in `profiles/<name>.env` loaded on top of `.env`:

```bash
make test PROFILE=agents
```

Profile values win over `.env`, so a profile fully describes its test. The bundled `agents` profile runs 10 parallel k6 agent Pods signing fresh subject tokens for 100 rotating synthetic users at a combined 100 exchanges/second:

1. Generate the signing key once: `make keys`.
2. Push the server profile (with the generated JWKS) to your profiles repo, set `SERVER_PROFILE_URL`, and `make deploy`.
3. Run: `make test PROFILE=agents`.

Each agent Pod runs `RATE / AGENTS` iterations per second, signs a fresh RS256 subject token per iteration (rotating `sub` through its share of the users), and exchanges it with `client_credentials`-authenticated requests. The measured path is exactly the production one and no single subject token is replayed.

Custom profiles: copy `profiles/agents.env`, adjust `AGENTS`, `RATE`, and `SUBJECT_USER_COUNT`, then `make test PROFILE=<name>`. Reference levels for this campaign live in `profiles/stage-*.env` (100–500/s) and must stay within the documented bound — see "Scope of this campaign".

## Load controls

The defaults generate 50 token exchanges per second for five minutes. Set these in `.env` (or in the profile, which wins):

| Variable | Default | Meaning |
|---|---:|---|
| `RATE` | `50` | Total iterations per second (divided across agents) |
| `AGENTS` | `1` | Parallel k6 agent Pods |
| `DURATION` | `5m` | Steady test duration |
| `PRE_ALLOCATED_VUS` | `25` | Initially allocated k6 workers per agent |
| `MAX_VUS` | `200` | Maximum workers used to sustain the rate, per agent |
| `P95_MS` | `500` | p95 latency threshold in milliseconds |
| `SUCCESS_RATE` | `0.99` | Minimum valid OAuth response rate |

Run the reference levels in `profiles/stage-*.env` in ascending order — do not run a level whose rate exceeds the campaign bound (500/s). Keep PingFederate CPU and memory requests/limits unchanged between runs. The thresholds (`P95_MS`, `SUCCESS_RATE`) are **provisional** sanity bounds for these reference levels, not production SLOs — no business requirement is attached to them.

## What the result means

k6 reports transport metrics and three test-specific metrics:

- `token_exchange_latency`: complete token endpoint response time
- `token_exchange_success`: HTTP 200 plus `access_token` and `issued_token_type`
- `token_exchange_oauth_errors`: count of failed or invalid OAuth responses

With multiple agents each k6 Pod prints its own summary; the per-agent latencies are comparable because every agent drives the same share of the rate. The Kubernetes Service should distribute requests across both engine Pods. Compare their CPU/memory samples in `results/` to catch imbalance. For precise per-node request counts, enable PingFederate access metrics/logging and aggregate by Pod name.

## Benchmark assumptions

These assumptions define what the measured numbers mean. They are design decisions, not accidents — changing any of them changes what the benchmark measures.

1. **Subject tokens are always self-contained JWTs, validated by a JWT token processor, with the verification keys fetched from a JWKS URL.** The inbound token is an RS256 JWT validated by PingFederate's JWT Token Processor 2.0 against the JWKS it fetches from `http://perf-jwks-server/jwks.json` — an nginx pod, deployed with the loadtest chart, serving the same `perf-subject-jwks.json` the load generator signs with (issuer `https://pf-perf-subject`; audience is the calling agent's own client id, `perf-agent-<N>` — the server profile provisions one OAuth client per k6 agent and lists all ten as allowed audiences, so the allowed-audience set and the `CLIENT_ID` base name are coupled to a ten-agent topology). Signature, issuer, audience and expiry checks happen against PF's JWKS cache as they would against any issuer's published endpoint: the fetch path, cache lifetime, and refresh behavior are on the measured path rather than replaced by embedded key material. The endpoint is in-cluster HTTP, so its network cost (a LAN round trip) matches an internal issuer; a geographically remote or TLS-only JWKS endpoint would add to that.

2. **No persistent storage on the hot path.** The client is `TOKEN_EXCHANGE`-grant-only — PingFederate never issues refresh tokens here, so every grant is transient and the persistent store is never read or written. Token exchange produces transient grants by definition, and JWT subject-token validation requires no grant lookup (unlike opaque PF-issued tokens, which validate via a grant-store read). This holds even for subject tokens that originally came from a refresh-token-backed session: the JWT processor validates the token on its own merits.

3. **The embedded HSQLDB is therefore out of the request path entirely.** Its known limitations (not shared between cluster nodes, not durable across restarts, trial-only licensing) do not affect these results — there is nothing for it to store, and configuration durability is provided by the bulk import re-imposing the profile on every admin restart. **This is deliberate: agent flows should not use refresh tokens through token exchange** — the agent already holds stronger credentials (its client secret), and the subject token itself carries the user authorization, so a refresh token would be redundant long-lived material to protect. Enforcement is by config (`grantTypes: ["TOKEN_EXCHANGE"]` only), not convention: PingFederate cannot issue refresh tokens here. If a future platform variant introduces opaque subject tokens validated by grant lookup, or refresh-token flows, the persistent store re-enters the hot path and this assumption must be revisited — with an external, shared datastore per Ping's production guidance.

4. **What the numbers include and exclude.** Measured: client authentication, JWT validation, token-exchange policy evaluation, output-token signing, transport. Not measured: user authentication (synthetic subjects, no IdP round-trip), persistent-grant storage (never touched), external IdP/PAZ calls. Results are therefore a *floor* for real deployments that add storage-backed validation steps.

5. **Stage numbers reflect continuously-warmed engines.** Ladder stages run sequentially against the same deployment: by the time a later stage runs, JIT compilation, caches, and JWKS parsing are hot from the preceding stages. The 30s warmup primes each run's connections, but cross-stage comparisons embed this ordering effect — the first stage of a campaign after a fresh deployment is not directly comparable to later stages. All stage numbers therefore represent a *continuously-warmed* PingFederate, which is itself a representativeness claim: production engines serving steady traffic are warm, so this matches the intended steady-state use case, at the cost of not characterizing cold-start behavior (first requests after a restart, before the warmup period).

6. **Known behavior: a 30s-cadence latency wave — real, fingerprinted, root cause not yet proven.** At sub-10 ms latencies the response-time charts show a regular sawtooth: a ~6–8 s-wide elevation of ~1.5–4 ms recurring every 30 s, simultaneous across all agents and both engines, phase-locked to each run's start (not the wall clock). Established by elimination (autocorrelation 0.80 at 30 s lag; zero connection setup or TLS at wave seconds; flat engine CPU; GC-pause correlation at chance level; no engine log entries; cycle pre-existed every prior campaign; idle engines show no clean cycle — load-dependent). Thread dumps captured within ±1 s of every wave crest (114 dumps, E3) show a **completely healthy JVM**: zero blocked threads, no lock contention, one idle selector, identical thread state at crest and trough — the stall leaves no fingerprint inside the JVM. An E2 experiment overrode the knob to `idleTimeout=120000` (the documented `PF_RUN_pf_runtime_http_idleTimeout` env mechanism, verified live in both engines' JVMs) and reran the identical stage-250 profile: the 30 s wave **remained** — per-second autocorrelation 0.57 at 30 s lag (vs 0.19 in the reference run), crest gaps predominantly 29–31 s, idle timeout already falsified as the cause. The 30 s cadence has no identified owner anywhere in the measured path; the recorded finding is a periodic stall of ~2 ms, below-the-JVM-fingerprint, cause unknown. The wave is fixed (~2 ms), measured through rather than filtered out, and negligible at production latencies; it explains texture in the charts, not any verdict. Related observation: both engines allocate ~250 MB/s even at idle (GC every ~1 s / ~6 s respectively), so JVM heap churn — not requests — dominates baseline CPU at these low rates.

7. **Subject identity count is load-neutral on this path.** The workload model derives the arrival rate from a 30,000-active-user population, but the load generator rotates only `SUBJECT_USER_COUNT` (100) synthetic subjects, each exercised far more frequently than a production user would be. This compression is valid because PingFederate performs no per-subject work on the measured path: the JWT processor validates the token from its own claims, `sub` flows through the TEPP contract into the output token as a copied string, and no state is read or written per subject (assumption 2). 100 hot identities and 30,000 cold ones therefore exercise identical code paths at identical rates. This equivalence does not survive a variant that adds per-subject resolution — datastore-backed attribute mapping, per-user decision caching, jti/replay validation — under which 100 hot users would enjoy per-user cache hits that a mostly-cold 30,000-user population would not, flattering the result. Related: k6's VU count is not a user count. VUs are interchangeable arrival-consumers sized by rate × latency (Little's law), not by population; only `RATE` models production load, VUs are plumbing, and the rotating `sub` population is token payload. Conflating the three imports closed-model thinking into this open-model design and misreads every number here.

## Configuration and safety notes

- `.env` contains credentials and is excluded from Git. Profiles in `profiles/` hold only shape settings and client IDs, never secrets. `keys/` holds the subject signing key and is also excluded.
- k6 response bodies are parsed only to validate the response; token values are never logged.
- The subject signing key must stay stable across a test campaign: every request's signature must verify against the JWKS served at `SUBJECT_JWKS_URL`. Regenerate only with `./scripts/generate-signing-key.sh --force`, then re-push the profile and redeploy.
- `INSECURE_SKIP_TLS_VERIFY=true` is suitable for the chart's internal/self-signed TLS during a lab test. Install trusted certificates and set it to `false` for a production-like test.
- The anti-affinity rule prefers different Kubernetes nodes but does not require them. Check `make verify` output if physical node separation matters.
- See `docs/pingfederate-configuration.md` for the PF objects and the profile's bulk-config behavior.

## Cleanup

```bash
make uninstall
```

Removes all three Helm releases (loadtest, PingFederate, jwks-server) from the namespace; the namespace and Secrets are intentionally retained so credentials and the signing key survive between campaigns. Delete the namespace explicitly only when you no longer need anything in it:

```bash
kubectl delete namespace <ns>
```
