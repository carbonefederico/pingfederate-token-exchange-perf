#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
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

# The bulk import is full-state: it must carry the SSL server keypair the
# instance will activate (bulk_config_ssl_server_config_invalid otherwise).
# The p12 ships in the profile directory; the password is lab-disposable.
P12_FILE="${ROOT_DIR}/server-profiles/pingfederate-token-exchange/ssl-server.p12"
[[ -f "${P12_FILE}" ]] || {
  echo "SSL server p12 not found: ${P12_FILE}" >&2
  exit 1
}
PERF_SSL_SERVER_P12_PASSWORD='Secret1234!'
PERF_SSL_SERVER_P12_FILEDATA="$(base64 -i "${P12_FILE}" | tr -d '\n')"

# Profile values with commas (the JWKS JSON) cannot travel through
# --set-string, so the admin envs go through a generated values file.
GENERATED_VALUES="$(mktemp -t pf-perf-values).yaml"
mv "${GENERATED_VALUES%.yaml}" "${GENERATED_VALUES}"
trap 'rm -f "${GENERATED_VALUES}"' EXIT

# The env var must carry the JWKS with literal backslash-escaped quotes (the
# bulk config is JSON: the value sits inside a "..." string). Helm consumes
# YAML escaping when reading the values file, so escape once more here — the
# deployed env var ends up with \" sequences intact, which envsubst passes
# through and the bulk import parses as a quoted JSON string value.
PERF_SUBJECT_JWKS_YAML="${PERF_SUBJECT_JWKS//\\/\\\\}"
PERF_SUBJECT_JWKS_YAML="${PERF_SUBJECT_JWKS_YAML//\"/\\\"}"
cat > "${GENERATED_VALUES}" <<EOF
pingfederate-admin:
  envs:
    SUBJECT_ISSUER: "${SUBJECT_ISSUER:-https://pf-perf-subject}"
    SUBJECT_AUDIENCE: "${SUBJECT_AUDIENCE:-perf-test-client}"
    OUTPUT_ISSUER: "${OUTPUT_ISSUER:-https://pf-pingfederate-engine}"
    OUTPUT_AUDIENCE: "${OUTPUT_AUDIENCE:-token-exchange-perf}"
    PERF_CLIENT_ID: "${CLIENT_ID:-perf-test-client}"
    PERF_CLIENT_SECRET: "${PERF_CLIENT_SECRET}"
    PERF_SUBJECT_JWKS: "${PERF_SUBJECT_JWKS_YAML}"
    PERF_SSL_SERVER_P12_PASSWORD: "${PERF_SSL_SERVER_P12_PASSWORD}"
    PERF_SSL_SERVER_P12_FILEDATA: "${PERF_SSL_SERVER_P12_FILEDATA}"
EOF

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create secret generic devops-secret \
  --from-literal=PING_IDENTITY_DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER}" \
  --from-literal=PING_IDENTITY_DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY}" \
  --from-literal=PING_IDENTITY_ACCEPT_EULA="${PING_IDENTITY_ACCEPT_EULA:-YES}" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add pingidentity https://helm.pingidentity.com/ --force-update
helm repo update pingidentity

# The image's git clone reads credentials from the SERVER_PROFILE_URL itself
# (envsubst expands ${SERVER_PROFILE_GIT_USER}/${SERVER_PROFILE_GIT_PASSWORD}
# inside the pod, supplied by the chart's optional *-git-secret). Embed the
# placeholders so private repos authenticate; the hook redacts the URL in logs.
PROFILE_URL_WITH_CREDS="${SERVER_PROFILE_URL}"
case "${SERVER_PROFILE_URL}" in
  https://*)
    PROFILE_URL_WITH_CREDS="https://\${SERVER_PROFILE_GIT_USER}:\${SERVER_PROFILE_GIT_PASSWORD}@${SERVER_PROFILE_URL#https://}"
    ;;
esac

helm upgrade --install "${PF_RELEASE}" pingidentity/ping-devops \
  --namespace "${NAMESPACE}" \
  --version "${PING_CHART_VERSION}" \
  --values "${ROOT_DIR}/helm/pingfederate/values.yaml" \
  --values "${GENERATED_VALUES}" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_URL="${PROFILE_URL_WITH_CREDS}" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_PATH="${SERVER_PROFILE_PATH}" \
  --set-string pingfederate-admin.envs.SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_URL="${PROFILE_URL_WITH_CREDS}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_PATH="${SERVER_PROFILE_PATH}" \
  --set-string pingfederate-engine.envs.SERVER_PROFILE_BRANCH="${SERVER_PROFILE_BRANCH}" \
  --wait --timeout 15m

echo
kubectl -n "${NAMESPACE}" get pods,services -l "app.kubernetes.io/instance=${PF_RELEASE}" -o wide
