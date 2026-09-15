#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

mkdir -p "${ROOT_DIR}/results"
output="${ROOT_DIR}/results/pod-usage-$(date -u +%Y%m%dT%H%M%SZ).csv"
echo "timestamp,pod,cpu,memory" > "${output}"
echo "Writing ${output}; press Ctrl-C to stop."

while true; do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kubectl -n "${NAMESPACE}" top pods -l "app.kubernetes.io/instance=${PF_RELEASE}" --no-headers 2>/dev/null \
    | awk -v timestamp="${timestamp}" '{print timestamp "," $1 "," $2 "," $3}' \
    >> "${output}"
  sleep "${MONITOR_INTERVAL_SECONDS:-5}"
done

