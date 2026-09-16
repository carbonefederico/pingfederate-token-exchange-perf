#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl
require_command helm
"${ROOT_DIR}/scripts/create-loadtest-secret.sh"

agent_count="${AGENTS:-1}"
run_id="$(date -u +%Y%m%d%H%M%S)"

helm_args=(
  --namespace "${NAMESPACE}"
  --set-string runId="${run_id}"
  --set-string agentCount="${agent_count}"
)

# Everything the report generator needs lands in results/<run_id>/: the
# per-agent k6 logs (the pods TTL-clean after 1h, so capture them here),
# plus the monitor CSV if it is running.
run_dir="${ROOT_DIR}/results/${run_id}"
mkdir -p "${run_dir}"

helm uninstall "${LOADTEST_RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1 || true
helm install "${LOADTEST_RELEASE}" "${ROOT_DIR}/helm/loadtest" "${helm_args[@]}"

job_name="${LOADTEST_RELEASE}-${run_id}"
echo "Following ${job_name}; the command exits non-zero if k6 thresholds fail."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
  -l "job-name=${job_name}" --timeout=5m
kubectl -n "${NAMESPACE}" logs -f "job/${job_name}"

# Wait for the Job to reach a terminal condition (succeeded check races the
# Job controller otherwise).
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout=2m 2>/dev/null \
  || kubectl -n "${NAMESPACE}" wait --for=condition=failed "job/${job_name}" --timeout=5s 2>/dev/null || true

succeeded="$(kubectl -n "${NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
if [[ "${succeeded}" != "${agent_count}" ]]; then
  echo "k6 Job failed (usually because a request check or threshold failed)." >&2
  kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide >&2
  exit 1
fi

# Capture every agent's summary before the TTL deletes the pods.
echo "Capturing per-agent results to ${run_dir}..."
for i in $(seq 0 $((agent_count - 1))); do
  pod="$(kubectl -n "${NAMESPACE}" get pods -o jsonpath="{range .items[?(@.metadata.annotations['batch\.kubernetes\.io/job-completion-index']=='${i}')]}{.metadata.name}{end}" 2>/dev/null)"
  if [[ -n "${pod}" ]]; then
    kubectl -n "${NAMESPACE}" logs "${pod}" -c k6 > "${run_dir}/agent-${i}.log" 2>/dev/null || true
    # The streaming metric time-series (per-request latency etc.) written by
    # k6's json output inside the pod.
    kubectl -n "${NAMESPACE}" cp "${pod}:/out/k6.json" "${run_dir}/agent-${i}-metrics.json" -c k6 2>/dev/null || true
  fi
done
kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide > "${run_dir}/job.txt" 2>&1 || true
echo "Results saved: ${run_dir}/agent-*.log"
echo "Generate the dashboard with: make report RUN=${run_id}"
