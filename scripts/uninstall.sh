#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command helm

helm uninstall "${LOADTEST_RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1 || true
helm uninstall "${PF_RELEASE}" --namespace "${NAMESPACE}"
helm uninstall "${JWKS_RELEASE:-jwks-server}" --namespace "${NAMESPACE}" >/dev/null 2>&1 || true
echo "Namespace ${NAMESPACE} and its Secrets were retained."

