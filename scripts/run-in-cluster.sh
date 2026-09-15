#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
"${ROOT_DIR}/scripts/create-loadtest-secret.sh"

agent_count="${AGENTS:-1}"
helm_args=(--set-string runId)
run_id="$(date -u +%Y%m%d%H%M%S)"

helm_args=(
  --namespace "${NAMESPACE}"
  --set-string runId="${run_id}"
  --set-string agentCount="${agent_count}"
)

helm uninstall "${LOADTEST_RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1 || true
helm install "${LOADTEST_RELEASE}" "${ROOT_DIR}/helm/loadtest" "${helm_args[@]}"

job_name="${LOADTEST_RELEASE}-${run_id}"
echo "Following ${job_name}; the command exits non-zero if k6 thresholds fail."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
  -l "job-name=${job_name}" --timeout=5m
kubectl -n "${NAMESPACE}" logs -f "job/${job_name}"

succeeded="$(kubectl -n "${NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.succeeded}')"
if [[ "${succeeded}" != "1" ]]; then
  echo "k6 Job failed (usually because a request check or threshold failed)." >&2
  kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide >&2
  exit 1
fi
