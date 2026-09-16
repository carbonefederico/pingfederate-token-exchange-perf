#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

# Optional load profile: PROFILE=agents loads profiles/<name>.env on top of
# .env. Values in the profile win, so a profile fully describes the test.
PROFILE="${PROFILE:-}"
if [[ -n "${PROFILE}" ]]; then
  profile_file="${ROOT_DIR}/profiles/${PROFILE}.env"
  [[ -f "${profile_file}" ]] || {
    echo "Profile not found: ${profile_file}" >&2
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  source "${profile_file}"
  set +a
fi

# Expand ${ROOT_DIR} inside .env/profile values such as USERS_FILE and
# SUBJECT_SIGNING_KEY_FILE.
for path_var in USERS_FILE SUBJECT_SIGNING_KEY_FILE PERF_SSL_SERVER_P12_FILE; do
  if [[ -n "${!path_var:-}" && "${!path_var}" == *'${ROOT_DIR}'* ]]; then
    export "${path_var}=${!path_var//\$\{ROOT_DIR\}/${ROOT_DIR}}"
  fi
done

NAMESPACE="${NAMESPACE:-pf-perf}"
PF_RELEASE="${PF_RELEASE:-pf}"
LOADTEST_RELEASE="${LOADTEST_RELEASE:-pf-te-test}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "Required value is empty: ${name}" >&2
    exit 1
  }
}

