#!/bin/bash
# Build Vendor/PsiphonTunnelCore.xcframework for local dev and Xcode Cloud.
set -euo pipefail

log() { echo "[build-psiphon-vendor] $*"; }

if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
  REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH}"
else
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

cd "${REPO_ROOT}"
log "REPO_ROOT=${REPO_ROOT}"

GO_INSTALL_ROOT="${HOME}/.xcode-cloud/go"
GO_ROOT="${GO_INSTALL_ROOT}/go"

install_go_1_26() {
  if command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -qE 'go1\.26'; then
    export GOROOT="$(go env GOROOT)"
    export PATH="$(go env GOROOT)/bin:${PATH}"
    log "Go already installed: $(go version)"
    return 0
  fi

  ARCH="$(uname -m)"
  case "${ARCH}" in
    arm64) GO_ARCH=arm64 ;;
    x86_64) GO_ARCH=amd64 ;;
    *) log "Unsupported macOS arch: ${ARCH}"; exit 1 ;;
  esac

  GO_VERSION="1.26.0"
  GO_TAR="go${GO_VERSION}.darwin-${GO_ARCH}.tar.gz"

  log "Installing Go ${GO_VERSION} (${GO_ARCH}) to ${GO_ROOT} ..."
  mkdir -p "${GO_INSTALL_ROOT}"
  curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
  rm -rf "${GO_ROOT}"
  tar -C "${GO_INSTALL_ROOT}" -xzf "/tmp/${GO_TAR}"
  export GOROOT="${GO_ROOT}"
  export PATH="${GO_ROOT}/bin:${PATH}"

  go version | grep -qE 'go1\.26' || {
    log "Go 1.26 install failed"
    exit 1
  }
  log "Go ready: $(go version)"
}

if [[ -d "${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework/ios-arm64/PsiphonTunnel.framework" ]]; then
  log "Vendor/PsiphonTunnelCore.xcframework already present."
  exit 0
fi

install_go_1_26
export GOROOT="${GOROOT:-$(go env GOROOT)}"
export PATH="${GOROOT}/bin:${PATH}"

log "Building PsiphonTunnelCore.xcframework ..."
bash "${REPO_ROOT}/Tooling/psiphon/build-ios-xcframework.sh"

test -d "${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework" || {
  log "FAIL: build finished but Vendor/PsiphonTunnelCore.xcframework is missing"
  exit 1
}

log "OK: ${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework"
