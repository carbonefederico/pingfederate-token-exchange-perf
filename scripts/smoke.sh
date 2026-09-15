#!/usr/bin/env bash
# One manual token exchange from the workstation: signs a subject JWT with
# the local signing key (make keys), then exchanges it for a PingFederate
# access token. Run after port-forwarding the engine Service (see README) so
# PF_TOKEN_URL points at https://localhost:9031/as/token.oauth2.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command curl
require_command openssl
require_command python3
for name in PF_TOKEN_URL CLIENT_ID CLIENT_SECRET SUBJECT_SIGNING_KEY_FILE; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (run make keys)" >&2
  exit 1
}

SUBJECT_ISSUER="${SUBJECT_ISSUER:-https://pf-perf-subject}"
SUBJECT_AUDIENCE="${SUBJECT_AUDIENCE:-${CLIENT_ID}}"
SUBJECT_USER="${SUBJECT_USER:-perf-user-001}"
SUBJECT_TOKEN_TYPE="${SUBJECT_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}"
REQUESTED_TOKEN_TYPE="${REQUESTED_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}"

# Build and sign the RS256 subject JWT (same claim contract as the k6 script).
subject_token="$(python3 - "${SUBJECT_SIGNING_KEY_FILE}" "${SUBJECT_ISSUER}" "${SUBJECT_AUDIENCE}" "${SUBJECT_USER}" <<'PYEOF'
import base64, json, subprocess, sys, time
key, iss, aud, sub = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
header = {"alg": "RS256", "typ": "JWT", "kid": "perf-subject-key"}
payload = {"iss": iss, "sub": sub, "aud": aud, "iat": now, "exp": now + 300, "jti": f"smoke-{now}"}
si = b64u(json.dumps(header).encode()) + "." + b64u(json.dumps(payload).encode())
sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=si.encode(), capture_output=True).stdout
print(si + "." + b64u(sig))
PYEOF
)"

curl_args=(
  --silent --show-error --fail-with-body
  --request POST "${PF_TOKEN_URL}"
  --header "Content-Type: application/x-www-form-urlencoded"
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange"
  --data-urlencode "subject_token=${subject_token}"
  --data-urlencode "subject_token_type=${SUBJECT_TOKEN_TYPE}"
  --data-urlencode "requested_token_type=${REQUESTED_TOKEN_TYPE}"
)

[[ "${INSECURE_SKIP_TLS_VERIFY:-false}" == "true" ]] && curl_args+=(--insecure)
[[ -n "${RESOURCE:-}" ]] && curl_args+=(--data-urlencode "resource=${RESOURCE}")
[[ -n "${AUDIENCE:-}" ]] && curl_args+=(--data-urlencode "audience=${AUDIENCE}")
[[ -n "${SCOPE:-}" ]] && curl_args+=(--data-urlencode "scope=${SCOPE}")
[[ -n "${ACTOR_TOKEN:-}" ]] && curl_args+=(--data-urlencode "actor_token=${ACTOR_TOKEN}" --data-urlencode "actor_token_type=${ACTOR_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}")

if [[ "${CLIENT_AUTH_METHOD:-client_secret_basic}" == "client_secret_post" ]]; then
  curl_args+=(--data-urlencode "client_id=${CLIENT_ID}" --data-urlencode "client_secret=${CLIENT_SECRET}")
else
  curl_args+=(--user "${CLIENT_ID}:${CLIENT_SECRET}")
fi

response="$(curl "${curl_args[@]}")"
if command -v jq >/dev/null 2>&1; then
  echo "${response}" | jq 'del(.access_token, .refresh_token, .id_token)'
else
  echo "Token exchange succeeded (response token material intentionally not printed)."
fi
