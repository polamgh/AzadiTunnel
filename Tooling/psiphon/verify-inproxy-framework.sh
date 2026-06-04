#!/usr/bin/env bash
# Verify PsiphonTunnelCore.xcframework was built with in-proxy (not PSIPHON_DISABLE_INPROXY).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XC="${1:-${ROOT}/Vendor/PsiphonTunnelCore.xcframework}"
BIN="${XC}/ios-arm64/PsiphonTunnel.framework/PsiphonTunnel"
TAGS="${PSIPHON_IOS_BUILD_TAGS:-}"

if [[ ! -f "${BIN}" ]]; then
  echo "PSIPHON_INPROXY_BUILD enabled=unknown"
  echo "PSIPHON_INPROXY_BUILD_TAGS value=${TAGS:-<not built yet>}"
  echo "PSIPHON_INPROXY_SYMBOLS_FOUND false"
  echo "FAIL: missing ${BIN}"
  exit 1
fi

if [[ "${TAGS}" == *"PSIPHON_DISABLE_INPROXY"* ]]; then
  echo "PSIPHON_INPROXY_BUILD enabled=false"
  echo "PSIPHON_INPROXY_BUILD_TAGS value=${TAGS}"
  echo "PSIPHON_INPROXY_SYMBOLS_FOUND false"
  echo "FAIL: PSIPHON_DISABLE_INPROXY must not be set for Conduit"
  exit 1
fi

# Fork uses //go:build !PSIPHON_DISABLE_INPROXY (default on). PSIPHON_ENABLE_INPROXY is not defined in this fork.
if [[ -z "${TAGS}" ]]; then
  EFFECTIVE="default_inproxy_on"
elif [[ "${TAGS}" == *"PSIPHON_ENABLE_INPROXY"* ]]; then
  EFFECTIVE="noop_tag_enable_inproxy_still_on"
else
  EFFECTIVE="${TAGS}"
fi

echo "PSIPHON_INPROXY_BUILD enabled=true"
echo "PSIPHON_INPROXY_BUILD_TAGS value=${EFFECTIVE}"

FOUND=0
MISSING=0
check() {
  if grep -aq "$1" <(strings "${BIN}" 2>/dev/null); then
    echo "PSIPHON_INPROXY_PROBE found=$1"
    FOUND=$((FOUND + 1))
  else
    echo "PSIPHON_INPROXY_PROBE missing=$1"
    MISSING=$((MISSING + 1))
  fi
}

check "INPROXY-WEBRTC"
check "inproxy-broker"
check "InproxyBrokerClientManager"
check "inproxy: selected broker"
check "no broker specs"
check "pion"
check "tailscale"

INPROXY_NM=$(nm "${BIN}" 2>/dev/null | grep -ci inproxy || echo 0)
echo "PSIPHON_INPROXY_NM_COUNT value=${INPROXY_NM}"

if [[ "${MISSING}" -gt 2 ]] || [[ "${INPROXY_NM}" -lt 50 ]]; then
  echo "PSIPHON_INPROXY_SYMBOLS_FOUND false"
  exit 1
fi

echo "PSIPHON_INPROXY_SYMBOLS_FOUND true"
exit 0
