#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
for name in PF_TOKEN_URL CLIENT_ID CLIENT_SECRET SUBJECT_SIGNING_KEY_FILE; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (run make keys)" >&2
  exit 1
}

args=(
  --from-literal=PF_TOKEN_URL="${PF_TOKEN_URL}"
  --from-literal=CLIENT_ID="${CLIENT_ID}"
  --from-literal=CLIENT_SECRET="${CLIENT_SECRET}"
  --from-literal=CLIENT_AUTH_METHOD="${CLIENT_AUTH_METHOD:-client_secret_basic}"
  --from-file=SUBJECT_SIGNING_KEY="${SUBJECT_SIGNING_KEY_FILE}"
  --from-literal=SUBJECT_ISSUER="${SUBJECT_ISSUER:-https://pf-perf-subject}"
  --from-literal=SUBJECT_AUDIENCE="${SUBJECT_AUDIENCE:-${CLIENT_ID}}"
  --from-literal=SUBJECT_USER_COUNT="${SUBJECT_USER_COUNT:-100}"
  --from-literal=SUBJECT_TOKEN_LIFETIME="${SUBJECT_TOKEN_LIFETIME:-300}"
  --from-literal=SUBJECT_TOKEN_TYPE="${SUBJECT_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}"
  --from-literal=REQUESTED_TOKEN_TYPE="${REQUESTED_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}"
  --from-literal=RESOURCE="${RESOURCE:-}"
  --from-literal=AUDIENCE="${AUDIENCE:-}"
  --from-literal=SCOPE="${SCOPE:-}"
  --from-literal=ACTOR_TOKEN="${ACTOR_TOKEN:-}"
  --from-literal=ACTOR_TOKEN_TYPE="${ACTOR_TOKEN_TYPE:-urn:ietf:params:oauth:token-type:access_token}"
  --from-literal=RATE="${RATE:-50}"
  --from-literal=DURATION="${DURATION:-5m}"
  --from-literal=WARMUP="${WARMUP:-30s}"
  --from-literal=REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
  --from-literal=PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-25}"
  --from-literal=MAX_VUS="${MAX_VUS:-200}"
  --from-literal=P95_MS="${P95_MS:-500}"
  --from-literal=SUCCESS_RATE="${SUCCESS_RATE:-0.99}"
  --from-literal=INSECURE_SKIP_TLS_VERIFY="${INSECURE_SKIP_TLS_VERIFY:-true}"
)

kubectl -n "${NAMESPACE}" create secret generic pf-loadtest "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -
