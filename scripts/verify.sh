#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command kubectl

engine_selector="app.kubernetes.io/instance=${PF_RELEASE},app.kubernetes.io/name=pingfederate-engine"
ready_engines="$(kubectl -n "${NAMESPACE}" get pods -l "${engine_selector}" --no-headers 2>/dev/null | awk '$2 == "1/1" && $3 == "Running" {count++} END {print count+0}')"

kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${PF_RELEASE}" -o wide

if [[ "${ready_engines}" -ne 2 ]]; then
  echo "Expected exactly 2 ready PingFederate engine Pods; found ${ready_engines}." >&2
  exit 1
fi

echo "Verified: two PingFederate engine Pods are Running and Ready."

