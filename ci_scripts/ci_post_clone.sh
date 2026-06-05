#!/bin/bash
# Xcode Cloud: install Go, run static checks, build PsiphonTunnelCore before any action.
set -euo pipefail

log() { echo "[ci_post_clone] $*"; }

on_err() {
  log "FAILED at line ${1} (exit ${2}). See log above for [build-psiphon-vendor] / go version mismatch."
}
trap 'on_err ${LINENO} $?' ERR

# Xcode Cloud runs scripts with cwd = ci_scripts/. Use Apple's env var when set.
if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
  REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH}"
else
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

cd "${REPO_ROOT}"
log "CI=${CI:-local} REPO_ROOT=${REPO_ROOT} PWD=$(pwd)"

log "Protocol parity check ..."
python3 "${REPO_ROOT}/Scripts/verify-protocol-parity.py"

bash "${REPO_ROOT}/ci_scripts/build-psiphon-vendor.sh"

log "ci_post_clone complete."
