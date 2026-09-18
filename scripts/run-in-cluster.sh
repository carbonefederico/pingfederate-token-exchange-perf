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
# per-agent k6 logs and metric streams (the pods TTL-clean after 1h, so
# capture them here), plus the monitor CSV if it is running.
run_dir="${ROOT_DIR}/results/${run_id}"
mkdir -p "${run_dir}"

# Run metadata (M2/auditability): every resolved variable that defines the
# run, plus the cluster context. The report reads thresholds from here so
# the PASS/FAIL gate is the same one the profiles declared.
{
  echo "{"
  echo "  \"run_id\": \"${run_id}\","
  echo "  \"profile\": \"${PROFILE:-<none, .env only>}\","
  echo "  \"timestamp_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  for v in AGENTS RATE DURATION WARMUP PRE_ALLOCATED_VUS MAX_VUS P95_MS SUCCESS_RATE \
           CLIENT_ID CLIENT_AUTH_METHOD SUBJECT_ISSUER SUBJECT_AUDIENCE SUBJECT_USER_COUNT \
           SUBJECT_TOKEN_LIFETIME PER_AGENT_CLIENTS NAMESPACE PF_RELEASE LOADTEST_RELEASE; do
    [[ -n "${!v:-}" ]] && printf '  "%s": "%s",\n' "${v}" "${!v}"
  done
  echo "  \"k6_image\": \"$(helm -n "${NAMESPACE}" get values "${LOADTEST_RELEASE}" -a 2>/dev/null | grep -oE 'repository: .*|tag: .*' | tr -d ' ' | paste -sd':' - | head -1 || echo unknown)\","
  echo "  \"nodes\": ["
  kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
for n in json.load(sys.stdin)['items']:
    print('    ' + json.dumps({'name': n['metadata']['name'], 'instance_type': n['metadata']['labels'].get('beta.kubernetes.io/instance-type', '?'), 'allocatable_cpu': n['status']['allocatable']['cpu']}) + ',')
" 2>/dev/null || true
  echo "  ]"
  echo "  \"engine_pods\": ["
  kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PF_RELEASE},app.kubernetes.io/name=pingfederate-engine" -o json 2>/dev/null | python3 -c "
import json, sys
for p in json.load(sys.stdin)['items']:
    print('    ' + json.dumps({'name': p['metadata']['name'], 'node': p['spec']['nodeName'], 'started': p['status']['startTime']}) + ',')
" 2>/dev/null || true
  echo "  ]"
} > "${run_dir}/env.json"
# Strip trailing commas before '}' or ']' (the looped printf emits trailing commas).
python3 -c 'import re,sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(re.sub(r",(\s*[}\]])", lambda m: m.group(1), t))' "${run_dir}/env.json"

helm uninstall "${LOADTEST_RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1 || true
helm install "${LOADTEST_RELEASE}" "${ROOT_DIR}/helm/loadtest" "${helm_args[@]}"

job_name="${LOADTEST_RELEASE}-${run_id}"
echo "Following ${job_name}; the command exits non-zero if k6 thresholds fail."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
  -l "job-name=${job_name}" --timeout=5m

# Snapshot each agent's metric stream while it is still Running — kubectl cp
# cannot exec into a completed pod, so the tail of each stream is whatever
# the newest successful snapshot holds. Copy to a temp file per agent and
# keep the LARGEST snapshot (a cp racing k6's writes can truncate; bigger is
# strictly more data). Poll every 3s to minimize tail loss.
echo "Capturing metric streams while agents run (${agent_count} agents)..."
declare -A running_seen best_size
while true; do
  pending=0
  for i in $(seq 0 $((agent_count - 1))); do
    [[ "${running_seen[$i]:-}" == "done" ]] && continue
    pod="$(kubectl -n "${NAMESPACE}" get pods -l "job-name=${job_name}" \
      -o jsonpath="{range .items[?(@.metadata.annotations['batch\.kubernetes\.io/job-completion-index']=='${i}')]}{.metadata.name}{end}" 2>/dev/null)"
    if [[ -z "${pod}" ]]; then
      pending=1
      continue
    fi
    phase="$(kubectl -n "${NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
    if [[ "${phase}" == "Running" ]]; then
      tmp="${run_dir}/.agent-${i}-metrics.json.tmp"
      if kubectl -n "${NAMESPACE}" cp "${pod}:/out/k6.json" "${tmp}" -c k6 >/dev/null 2>&1; then
        size="$(wc -c < "${tmp}" 2>/dev/null || echo 0)"
        prev="${best_size[$i]:-0}"
        if [[ "${size}" -ge "${prev}" ]]; then
          mv "${tmp}" "${run_dir}/agent-${i}-metrics.json"
          best_size[$i]="${size}"
        else
          rm -f "${tmp}"  # truncated mid-write; keep the previous larger snapshot
        fi
      fi
      running_seen[$i]=1
      pending=1
    elif [[ "${phase}" == "Succeeded" ]]; then
      running_seen[$i]=done
    else
      pending=1
    fi
  done
  [[ "${pending}" -eq 0 ]] && break
  sleep 3
done

kubectl -n "${NAMESPACE}" logs -f "job/${job_name}" || true

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

# Capture every agent's end-of-run summary before the TTL deletes the pods.
echo "Capturing per-agent results to ${run_dir}..."
for i in $(seq 0 $((agent_count - 1))); do
  pod="$(kubectl -n "${NAMESPACE}" get pods -o jsonpath="{range .items[?(@.metadata.annotations['batch\.kubernetes\.io/job-completion-index']=='${i}')]}{.metadata.name}{end}" 2>/dev/null)"
  if [[ -n "${pod}" ]]; then
    kubectl -n "${NAMESPACE}" logs "${pod}" -c k6 > "${run_dir}/agent-${i}.log" 2>/dev/null || true
  fi
done
kubectl -n "${NAMESPACE}" get "job/${job_name}" -o wide > "${run_dir}/job.txt" 2>&1 || true
echo "Results saved: ${run_dir}/"
echo "Generate the dashboard with: make report RUN=${run_id}"