#!/usr/bin/env bash
# Reproducible build of PsiphonTunnel.xcframework from shirokhorshid/psiphon-tunnel-core.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/Vendor"
PIN_FILE="${SCRIPT_DIR}/PSIPHON_PINNED_COMMIT"
BUILD_ROOT="${SCRIPT_DIR}/build"
SRC_DIR="${BUILD_ROOT}/psiphon-tunnel-core"

PINNED="$(tr -d '[:space:]' < "${PIN_FILE}")"
REPO_URL="https://github.com/shirokhorshid/psiphon-tunnel-core.git"

echo "Pinned commit: ${PINNED}"

mkdir -p "${BUILD_ROOT}"
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

git -C "${SRC_DIR}" fetch --depth 1 origin "${PINNED}" 2>/dev/null || git -C "${SRC_DIR}" fetch origin
git -C "${SRC_DIR}" checkout -f "${PINNED}"

# Xcode 26+ SDK: netinet6/in6.h is no longer a public module header.
grep -rl 'netinet6/in6.h' "${SRC_DIR}/MobileLibrary/iOS/PsiphonTunnel" 2>/dev/null | while read -r f; do
  sed -i '' 's/#import <netinet6\/in6.h>/#import <netinet\/in.h>/' "${f}"
done

if [[ -n "${GOROOT:-}" && -x "${GOROOT}/bin/go" ]]; then
  export PATH="${GOROOT}/bin:${PATH}"
fi
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/go/bin:${PATH:-}"
which go >/dev/null
export GOROOT="$(go env GOROOT)"
export PATH="${GOROOT}/bin:${PATH}"
GO_VERSION_REQUIRED="1.26.3"
GO_VERSION="$(go version | sed -E -n 's/.*go([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
if [[ "${GO_VERSION}" != "${GO_VERSION_REQUIRED}" ]]; then
  echo "Go ${GO_VERSION_REQUIRED} required (GOROOT=${GOROOT}); got ${GO_VERSION:-unknown}"
  exit 1
fi

# shirokhorshid/psiphon-tunnel-core: in-proxy is ON by default (!PSIPHON_DISABLE_INPROXY).
# PSIPHON_ENABLE_INPROXY does not exist in this fork (Shiro Android CI tag is a no-op here).
# Never pass PSIPHON_DISABLE_INPROXY — Conduit requires broker/WebRTC/pion code.
if [[ "${PSIPHON_DISABLE_INPROXY:-}" == "1" ]] || [[ "${PSIPHON_IOS_BUILD_TAGS:-}" == *"PSIPHON_DISABLE_INPROXY"* ]]; then
  echo "FAIL: Refusing build with PSIPHON_DISABLE_INPROXY (Conduit would be broken)"
  exit 1
fi
export PSIPHON_IOS_BUILD_TAGS="${PSIPHON_IOS_BUILD_TAGS:-}"

cd "${SRC_DIR}/MobileLibrary/iOS"
if [[ -n "${PSIPHON_IOS_BUILD_TAGS}" ]]; then
  bash ./build-psiphon-framework.sh "${PSIPHON_IOS_BUILD_TAGS}"
else
  bash ./build-psiphon-framework.sh
fi

XC_OUT="${SRC_DIR}/MobileLibrary/iOS/build/PsiphonTunnel.xcframework"
if [[ ! -d "${XC_OUT}" ]]; then
  echo "Build did not produce PsiphonTunnel.xcframework"
  exit 1
fi

mkdir -p "${VENDOR_DIR}"
rm -rf "${VENDOR_DIR}/PsiphonTunnelCore.xcframework"
cp -R "${XC_OUT}" "${VENDOR_DIR}/PsiphonTunnelCore.xcframework"

# Module map name remains PsiphonTunnel inside the xcframework.
file "${VENDOR_DIR}/PsiphonTunnelCore.xcframework/ios-arm64/PsiphonTunnel.framework/PsiphonTunnel" || true
chmod +x "${SCRIPT_DIR}/verify-inproxy-framework.sh"
PSIPHON_IOS_BUILD_TAGS="${PSIPHON_IOS_BUILD_TAGS}" "${SCRIPT_DIR}/verify-inproxy-framework.sh" "${VENDOR_DIR}/PsiphonTunnelCore.xcframework"
echo "OK: ${VENDOR_DIR}/PsiphonTunnelCore.xcframework"
