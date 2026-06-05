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
# Must match MobileLibrary/iOS/build-psiphon-framework.sh GO_VERSION_REQUIRED.
GO_VERSION_REQUIRED="1.26.3"

install_go_required() {
  if command -v go >/dev/null 2>&1; then
    local installed
    installed="$(go version | sed -E -n 's/.*go([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    if [[ "${installed}" == "${GO_VERSION_REQUIRED}" ]]; then
      export GOROOT="$(go env GOROOT)"
      export PATH="${GOROOT}/bin:${PATH}"
      log "Go already installed: $(go version)"
      return 0
    fi
    log "Found go ${installed:-unknown}; need ${GO_VERSION_REQUIRED}"
  fi

  ARCH="$(uname -m)"
  case "${ARCH}" in
    arm64) GO_ARCH=arm64 ;;
    x86_64) GO_ARCH=amd64 ;;
    *) log "Unsupported macOS arch: ${ARCH}"; exit 1 ;;
  esac

  GO_TAR="go${GO_VERSION_REQUIRED}.darwin-${GO_ARCH}.tar.gz"

  log "Installing Go ${GO_VERSION_REQUIRED} (${GO_ARCH}) to ${GO_ROOT} ..."
  mkdir -p "${GO_INSTALL_ROOT}"
  curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
  rm -rf "${GO_ROOT}"
  tar -C "${GO_INSTALL_ROOT}" -xzf "/tmp/${GO_TAR}"
  export GOROOT="${GO_ROOT}"
  export PATH="${GO_ROOT}/bin:${PATH}"

  local installed
  installed="$(go version | sed -E -n 's/.*go([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  if [[ "${installed}" != "${GO_VERSION_REQUIRED}" ]]; then
    log "Go install failed: expected ${GO_VERSION_REQUIRED}, got ${installed:-none} ($(go version 2>/dev/null || echo missing))"
    exit 1
  fi
  log "Go ready: $(go version)"
}

if [[ -d "${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework/ios-arm64/PsiphonTunnel.framework" ]]; then
  log "Vendor/PsiphonTunnelCore.xcframework already present."
  exit 0
fi

install_go_required
export GOROOT="${GOROOT:-$(go env GOROOT)}"
export PATH="${GOROOT}/bin:${PATH}"

log "Building PsiphonTunnelCore.xcframework ..."
bash "${REPO_ROOT}/Tooling/psiphon/build-ios-xcframework.sh"

test -d "${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework" || {
  log "FAIL: build finished but Vendor/PsiphonTunnelCore.xcframework is missing"
  exit 1
}

log "OK: ${REPO_ROOT}/Vendor/PsiphonTunnelCore.xcframework"
