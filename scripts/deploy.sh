#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
require_command python3
require_value PING_IDENTITY_DEVOPS_USER
require_value PING_IDENTITY_DEVOPS_KEY
require_value SERVER_PROFILE_URL
require_value SERVER_PROFILE_PATH

PING_CHART_VERSION="${PING_CHART_VERSION:-0.15.0}"
SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH:-main}"

# The bulk config embeds the subject-token verification JWKS as a value, so
# it must be present and its content passed as a container env var.
JWKS_FILE="${ROOT_DIR}/server-profiles/pingfederate-token-exchange/instance/server/default/data/perf-subject-jwks.json"
[[ -f "${JWKS_FILE}" ]] || {
  echo "Verification JWKS not found: ${JWKS_FILE} (run make keys)" >&2
  exit 1
}
require_value PERF_CLIENT_SECRET

PERF_SUBJECT_JWKS="$(python3 -c 'import json,sys; print(json.dumps(json.dumps(json.load(open(sys.argv[1]))))[1:-1])' "${JWKS_FILE}")"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create secret generic devops-secret \
  --from-literal=PING_IDENTITY_DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER}" \
  --from-literal=PING_IDENTITY_DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY}" \
  --from-literal=PING_IDENTITY_ACCEPT_EULA="${PING_IDENTITY_ACCEPT_EULA:-YES}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add pingidentity https://helm.pingidentity.com/ --force-update
helm repo update pingidentity

helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --namespace "${NAMESPACE}" \
  --version "${PING_CHART_VERSION}" \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_URL="${SERVER_PROFILE_URL}" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_PATH="${SERVER_PROFILE_PATH}" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH}" \
  --set-string pingfederate-admin.envs.SUBJECT_ISSUER="${SUBJECT_ISSUER:-https://pf-perf-subject}" \
  --set-string pingfederate-admin.envs.SUBJECT_AUDIENCE="${SUBJECT_AUDIENCE:-perf-test-client}" \
  --set-string pingfederate-admin.envs.OUTPUT_ISSUER="${OUTPUT_ISSUER:-https://pf-pingfederate-engine}" \
  --set-string pingfederate-admin.envs.OUTPUT_AUDIENCE="${OUTPUT_AUDIENCE:-token-exchange-perf}" \
  --set-string pingfederate-admin.envs.PERF_CLIENT_ID="${CLIENT_ID:-perf-test-client}" \
  --set-string pingfederate-admin.envs.PERF_CLIENT_SECRET="${PERF_CLIENT_SECRET}" \
  --set-string pingfederate-admin.envs.PERF_SUBJECT_JWKS="${PERF_SUBJECT_JWKS}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_URL="${SERVER_PROFILE_URL}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_PATH="${SERVER_PROFILE_PATH}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH}" \
  --wait --timeout 15m

echo
kubectl -n "${NAMESPACE}" get pods,services -l "app.kubernetes.io/instance=${PF_RELEASE}" -o wide
