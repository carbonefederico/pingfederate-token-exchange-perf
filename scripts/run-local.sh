#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command k6
for name in PF_TOKEN_URL CLIENT_ID CLIENT_SECRET SUBJECT_SIGNING_KEY_FILE; do
  require_value "${name}"
done
[[ -f "${SUBJECT_SIGNING_KEY_FILE}" ]] || {
  echo "Signing key not found: ${SUBJECT_SIGNING_KEY_FILE} (run make keys)" >&2
  exit 1
}

export SUBJECT_SIGNING_KEY="$(cat "${SUBJECT_SIGNING_KEY_FILE}")"

k6 run "${ROOT_DIR}/helm/loadtest/files/token-exchange.js"

