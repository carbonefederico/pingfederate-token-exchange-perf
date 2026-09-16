#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command kubectl

mkdir -p "${ROOT_DIR}/results"
output="${ROOT_DIR}/results/pod-usage-$(date -u +%Y%m%dT%H%M%SZ).csv"
echo "timestamp,kind,name,cpu,memory_or_pct" > "${output}"
echo "Writing ${output}; press Ctrl-C to stop."

# Which nodes host this release's pods? Resolved once up front; k6 agents are
# short-lived, so the engines and admin are what matter for node context.
nodes="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PF_RELEASE}" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')"

while true; do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Per-pod rows: timestamp,kind=pod,name,cpu,memory
  kubectl -n "${NAMESPACE}" top pods -l "app.kubernetes.io/instance=${PF_RELEASE}" --no-headers 2>/dev/null \
    | awk -v ts="${timestamp}" '{print ts ",pod," $1 "," $2 "," $3}' \
    >> "${output}"
  # Per-node rows for the nodes hosting the release: timestamp,kind=node,name,cpu_m,cpu_pct
  if [[ -n "${nodes}" ]]; then
    for node in ${nodes}; do
      kubectl top node "${node}" --no-headers 2>/dev/null \
        | awk -v ts="${timestamp}" -v n="${node}" '{print ts ",node," n "," $2 "," $3}' \
        >> "${output}"
    done
  fi
  sleep "${MONITOR_INTERVAL_SECONDS:-5}"
done
