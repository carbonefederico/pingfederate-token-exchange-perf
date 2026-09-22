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

# The bulk config configures the subject-token processor in JWKS URL mode:
# PingFederate fetches verification keys from ${SUBJECT_JWKS_URL} — the
# production-shaped distribution path — rather than embedding a copy. The
# endpoint is this project's own nginx chart (helm/jwks-server), deployed
# first as its own release (JWKS_RELEASE) so the key source exists before
# PingFederate starts and never disappears with the loadtest release.
JWKS_FILE="${ROOT_DIR}/server-profiles/pingfederate-token-exchange/instance/server/default/data/perf-subject-jwks.json"
[[ -f "${JWKS_FILE}" ]] || {
  echo "Verification JWKS not found: ${JWKS_FILE} (run make keys)" >&2
  exit 1
}
JWKS_JSON="$(cat "${JWKS_FILE}")"
# The endpoint's TLS material: PF requires an https:// JWKS URL, so the
# endpoint needs a server certificate and PF's JVM must trust it (the
# profile's pre-start hook imports the cert into the JVM truststore).
TLS_KEY_FILE="${ROOT_DIR}/keys/jwks-server-tls.key"
TLS_CRT_FILE="${ROOT_DIR}/server-profiles/pingfederate-token-exchange/instance/server/default/data/perf-jwks-server.crt"
[[ -f "${TLS_KEY_FILE}" && -f "${TLS_CRT_FILE}" ]] || {
  echo "jwks-server TLS material not found (run make keys)" >&2
  exit 1
}
TLS_KEY_B64="$(base64 -i "${TLS_KEY_FILE}" | tr -d '\n')"
TLS_CRT_B64="$(base64 -i "${TLS_CRT_FILE}" | tr -d '\n')"
require_value PERF_CLIENT_SECRET

# The bulk import is full-state: it must carry the SSL server keypair the
# instance will activate (bulk_config_ssl_server_config_invalid otherwise).
# The p12 (git-ignored, holds a private key) and its password come from the
# operator's environment: PERF_SSL_SERVER_P12_FILE and PERF_SSL_SERVER_P12_PASSWORD.
P12_FILE="${PERF_SSL_SERVER_P12_FILE:-${ROOT_DIR}/server-profiles/pingfederate-token-exchange/ssl-server.p12}"
[[ -f "${P12_FILE}" ]] || {
  echo "SSL server p12 not found: ${P12_FILE} (see .env.example)" >&2
  exit 1
}
require_value PERF_SSL_SERVER_P12_PASSWORD
PERF_SSL_SERVER_P12_FILEDATA="$(base64 -i "${P12_FILE}" | tr -d '\n')"

# The SSL p12 password and file data travel through a generated values file
# (filedata is long base64). The JWKS JSON travels through a second one for
# the jwks-server release: it cannot ride --set-string (helm splits values
# on commas), and each release needs its own file since values are top-level.
GENERATED_VALUES="$(mktemp -t pf-perf-values).yaml"
mv "${GENERATED_VALUES%.yaml}" "${GENERATED_VALUES}"
JWKS_VALUES="$(mktemp -t jwks-values).yaml"
mv "${JWKS_VALUES%.yaml}" "${JWKS_VALUES}"
trap 'rm -f "${GENERATED_VALUES}" "${JWKS_VALUES}"' EXIT

# Helm reads the values file as YAML: escape the JSON's backslashes and
# quotes once so .Values.jwksJson is the raw JWKS document.
JWKS_JSON_YAML="${JWKS_JSON//\\/\\\\}"
JWKS_JSON_YAML="${JWKS_JSON_YAML//\"/\\\"}"
cat > "${JWKS_VALUES}" <<EOF
jwksJson: "${JWKS_JSON_YAML}"
tlsCert: "${TLS_CRT_B64}"
tlsKey: "${TLS_KEY_B64}"
EOF

cat > "${GENERATED_VALUES}" <<EOF
pingfederate-admin:
  envs:
    SUBJECT_ISSUER: "${SUBJECT_ISSUER:-https://pf-perf-subject}"
    SUBJECT_AUDIENCE: "${SUBJECT_AUDIENCE:-perf-test-client}"
    SUBJECT_JWKS_URL: "${SUBJECT_JWKS_URL:-https://perf-jwks-server/jwks.json}"
    OUTPUT_ISSUER: "${OUTPUT_ISSUER:-https://pf-pingfederate-engine}"
    OUTPUT_AUDIENCE: "${OUTPUT_AUDIENCE:-token-exchange-perf}"
    PERF_CLIENT_ID: "${CLIENT_ID:-perf-test-client}"
    PERF_CLIENT_SECRET: "${PERF_CLIENT_SECRET}"
    PERF_SSL_SERVER_P12_PASSWORD: "${PERF_SSL_SERVER_P12_PASSWORD}"
    PERF_SSL_SERVER_P12_FILEDATA: "${PERF_SSL_SERVER_P12_FILEDATA}"
    # Admin account password for the bulk config's /administrativeAccounts and
    # the import hook's own authentication. Keep the image default unless
    # PING_IDENTITY_PASSWORD is set in .env.
    PING_IDENTITY_PASSWORD: "${PING_IDENTITY_PASSWORD:-2FederateM0re}"
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

helm upgrade --install "${JWKS_RELEASE}" "${ROOT_DIR}/helm/jwks-server" \
  --namespace "${NAMESPACE}" \
  --values "${JWKS_VALUES}" \
  --wait --timeout 5m

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
