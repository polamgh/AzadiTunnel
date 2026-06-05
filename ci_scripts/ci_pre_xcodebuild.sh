#!/bin/bash
# Xcode Cloud: verify (or build) Psiphon vendor framework immediately before xcodebuild.
set -euo pipefail

log() { echo "[ci_pre_xcodebuild] $*"; }

if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
  REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH}"
else
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

cd "${REPO_ROOT}"
log "CI=${CI:-local} REPO_ROOT=${REPO_ROOT}"

bash "${REPO_ROOT}/ci_scripts/build-psiphon-vendor.sh"

test -d "${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework/ios-arm64/PsiphonTunnel.framework" || {
  log "FAIL: ios-arm64 slice missing in Vendor/PsiphonTunnelCore.xcframework"
  exit 1
}

ENTRY_FILE="${REPO_ROOT}/AzadiTunnel/Resources/Bundled/psiphon-embedded-server-entries.txt"
if [[ ! -s "${ENTRY_FILE}" ]]; then
  log "Bundled server entries empty; extracting from public Shiro APK ..."
  bash "${REPO_ROOT}/Tooling/psiphon/extract-shiro-bundled-from-apk.sh"
fi

test -s "${ENTRY_FILE}" || {
  log "FAIL: psiphon-embedded-server-entries.txt is still empty"
  exit 1
}

if [[ -f "${REPO_ROOT}/AzadiTunnel/Resources/Bundled/psiphon-config.local.json" ]]; then
  log "Note: gitignored local Psiphon overrides present on runner."
fi

log "ci_pre_xcodebuild complete."
