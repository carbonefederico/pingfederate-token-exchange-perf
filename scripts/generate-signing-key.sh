#!/usr/bin/env bash
# Generate the RSA keypair used for subject-token signing in the perf lab.
#
#   keys/subject-signing.key   PKCS#8 private key (git-ignored) — loaded into
#                              the k6 Pods via the pf-loadtest Secret
#   server-profiles/pingfederate-token-exchange/instance/server/default/data/
#     perf-subject-jwks.json   public verification JWKS — pushed with the
#                              server profile so PingFederate can validate
#
# The key is the "predefined key" of the test design: it must be stable
# across runs, so this script refuses to overwrite an existing key without
# --force. After --force, push the updated profile and redeploy before
# running the test.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command openssl
require_command python3

force=0
[[ "${1:-}" == "--force" ]] && force=1

KEYS_DIR="${ROOT_DIR}/keys"
PRIVATE_KEY="${KEYS_DIR}/subject-signing.key"
JWKS_PATH="server-profiles/pingfederate-token-exchange/instance/server/default/data/perf-subject-jwks.json"
JWKS_FILE="${ROOT_DIR}/${JWKS_PATH}"

# TLS material for the in-cluster JWKS endpoint: PingFederate requires an
# HTTPS JWKS URL, so the endpoint needs a server certificate the JVM trusts.
TLS_KEY="${KEYS_DIR}/jwks-server-tls.key"
TLS_CRT="${ROOT_DIR}/server-profiles/pingfederate-token-exchange/instance/server/default/data/perf-jwks-server.crt"

if [[ -f "${PRIVATE_KEY}" && "${force}" -ne 1 ]]; then
  echo "Signing key already exists: ${PRIVATE_KEY}" >&2
  echo "Keep it — the subject tokens must keep verifying against the same public key." >&2
  echo "Regenerate deliberately with: ./scripts/generate-signing-key.sh --force" >&2
  exit 1
fi

mkdir -p "${KEYS_DIR}"
mkdir -p "$(dirname "${JWKS_FILE}")"

echo "Generating RSA-2048 subject signing key..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "${PRIVATE_KEY}" 2>/dev/null
chmod 600 "${PRIVATE_KEY}"

# Build the JWKS: extract the RSA modulus from the private key as hex, then
# convert to base64url (big-endian, leading zero bytes stripped). The public
# exponent for a generated key is always 65537 (AQAB).
echo "Extracting public key to embedded JWKS (${JWKS_PATH})..."
modulus_hex="$(openssl rsa -in "${PRIVATE_KEY}" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')"
[[ -n "${modulus_hex}" ]] || { echo "Could not extract modulus from ${PRIVATE_KEY}" >&2; exit 1; }

n_b64url="$(python3 - "${modulus_hex}" <<'PYEOF'
import sys, base64
b = bytes.fromhex(sys.argv[1])
while len(b) > 1 and b[0] == 0:
    b = b[1:]
print(base64.urlsafe_b64encode(b).decode().rstrip("="))
PYEOF
)"

# A JWKS document ({"keys": [...]}) is what PingFederate's JWT Token
# Processor 2.0 expects in its embedded-JWKS field.
cat > "${JWKS_FILE}" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "RS256",
      "kid": "perf-subject-key",
      "n": "${n_b64url}",
      "e": "AQAB"
    }
  ]
}
EOF

# The JWKS endpoint's TLS certificate: self-signed, CN = the in-cluster
# Service DNS name, valid long enough to outlive every campaign. The private
# key stays in keys/ (git-ignored); the cert travels with the server profile
# so PingFederate's truststore hook can import it at startup.
if [[ -f "${TLS_CRT}" && "${force}" -ne 1 ]]; then
  echo "JWKS endpoint TLS cert already exists: ${TLS_CRT}"
else
  echo "Generating JWKS endpoint TLS certificate (CN=perf-jwks-server)..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
    -subj "/CN=perf-jwks-server" \
    -addext "subjectAltName=DNS:perf-jwks-server" 2>/dev/null
  chmod 600 "${TLS_KEY}"
fi

echo "Written:"
echo "  ${PRIVATE_KEY}  (k6 signing key; keep secret)"
echo "  ${JWKS_FILE}  (commit + push with the server profile)"
echo "  ${TLS_KEY}  (jwks-server TLS key; keep secret)"
echo "  ${TLS_CRT}  (jwks-server TLS cert; commit + push — PF imports it)"
echo
echo "Next: push the server-profiles/ directory to your profiles repo, then make deploy."
