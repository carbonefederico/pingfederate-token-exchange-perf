#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

echo "PingFederate admin: https://localhost:9999/pingfederate/app"
kubectl -n "${NAMESPACE}" port-forward "service/${PF_RELEASE}-pingfederate-admin" 9999:9999

