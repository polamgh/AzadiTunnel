#!/usr/bin/env bash
# CDN Fronting connect test (Shiro parity). Expect FRONTED-MEEK-CDN-* protocol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
BEAST="${CDN_TEST_BEAST:-1}"
WAIT_SEC="${CDN_FRONTING_WAIT_SEC:-120}"
LOG_OUT="${ROOT}/Tooling/test-logs/cdn-fronting-beast${BEAST}-$(date -u +%Y%m%dT%H%M%SZ).log"

mkdir -p "${ROOT}/Tooling/test-logs"

if [[ ! -d "${APP}" ]]; then
  echo "Build first: xcodebuild -scheme AzadiTunnel -destination 'generic/platform=iOS,id=${DEVICE}' -derivedDataPath DerivedDataForCI build"
  exit 1
fi

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tail -3

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1

export DEVICECTL_CHILD_UITEST_PROTOCOL=cdnFronting
export DEVICECTL_CHILD_UITEST_BEAST_MODE="${BEAST}"
xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback -UITestSetProtocol cdnFronting -UITestSetBeastMode "${BEAST}" \
  -UITestForceBootstrap -UITestAutoConnect \
  2>&1 | tail -1 || true

echo "Waiting ${WAIT_SEC}s for CDN Fronting (beast=${BEAST})..."
sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >"${LOG_OUT}" 2>&1 || true
cp /tmp/azadi-group.plist "${LOG_OUT}.plist" 2>/dev/null || true

python3 - "${LOG_OUT}" "${BEAST}" <<'PY'
import plistlib
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
beast = sys.argv[2] == "1"
logs = []
if Path("/tmp/azadi-group.plist").exists():
    logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def last(prefix):
    for line in reversed(logs):
        if prefix in line:
            return line
    return None

cdn_cfg = last("CDN_FRONTING_CONFIG")
limits = last("CDN_FRONTING_PROTOCOL_LIMITS")
connected = last("PSIPHON_CONNECTED_PROTOCOL")
established = last("PSIPHON_TUNNEL_ESTABLISHED")
internet = last("INTERNET_TEST_PASSED") or last("internetTestPassed")
https = last("MAIN_APP_HTTP") or last("FEATURE_OK")

print("--- log file:", log_path)
for line in (cdn_cfg, limits, established, connected, internet):
    if line:
        print(line)

cdn_protocols = ("FRONTED-MEEK-CDN-OSSH", "FRONTED-MEEK-CDN-HTTP-OSSH", "FRONTED-MEEK-QUIC-OSSH")
if not cdn_cfg or "enabled=true" not in cdn_cfg:
    print("FAIL: CDN_FRONTING_CONFIG enabled=true missing")
    sys.exit(1)
if not limits or "FRONTED-MEEK-CDN" not in limits:
    print("FAIL: CDN_FRONTING_PROTOCOL_LIMITS missing FRONTED-MEEK-CDN-*")
    sys.exit(1)
if not connected:
    print("FAIL: no PSIPHON_CONNECTED_PROTOCOL")
    sys.exit(1)
if not any(p in connected for p in cdn_protocols):
    print("FAIL: connected protocol not FRONTED-MEEK-CDN-*:", connected)
    sys.exit(1)
if not established and "PSIPHON_TUNNEL_ESTABLISHED" not in str(logs):
    print("FAIL: tunnel not established")
    sys.exit(1)
if not internet and not https:
    print("WARN: internet test line not found (check INTERNET_TEST_* in log)")

print(f"PASS: CDN Fronting beast={beast} connected via CDN meek")
PY

echo "Saved: ${LOG_OUT}"
