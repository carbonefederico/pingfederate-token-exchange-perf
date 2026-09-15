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

cat > "${JWKS_FILE}" <<EOF
{
  "kty": "RSA",
  "use": "sig",
  "alg": "RS256",
  "kid": "perf-subject-key",
  "n": "${n_b64url}",
  "e": "AQAB"
}
EOF

echo "Written:"
echo "  ${PRIVATE_KEY}  (k6 signing key; keep secret)"
echo "  ${JWKS_FILE}  (commit + push with the server profile)"
echo
echo "Next: push the server-profiles/ directory to your profiles repo, then make deploy."
