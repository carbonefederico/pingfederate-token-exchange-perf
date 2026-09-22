#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for script in "${ROOT_DIR}"/scripts/*.sh; do
  bash -n "${script}"
done

if command -v helm >/dev/null 2>&1; then
  helm lint "${ROOT_DIR}/helm/loadtest"
  helm template pf-te-test "${ROOT_DIR}/helm/loadtest" --set-string runId=validate >/dev/null
  helm lint "${ROOT_DIR}/helm/jwks-server"
  helm template jwks-server "${ROOT_DIR}/helm/jwks-server" \
    --set-string jwksJson='{"keys":[]}' \
    --set-string tlsCert=YWJj --set-string tlsKey=YWJj >/dev/null
else
  echo "helm is not installed; skipped Helm render validation."
fi

if command -v node >/dev/null 2>&1; then
  node --check "${ROOT_DIR}/helm/loadtest/files/token-exchange.js"
fi

echo "Static validation passed."

