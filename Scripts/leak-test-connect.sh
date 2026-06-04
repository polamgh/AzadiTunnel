#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${LEAK_TEST_WAIT_SEC:-90}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/leak-test-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== leak-test-connect.sh ==="
echo "Command: $0 ${DEVICE}"
echo "Wait: ${WAIT_SEC}s"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -5

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback \
  -UITestSetProtocol auto -UITestSetBeastMode 1 -UITestForceBootstrap -UITestAutoConnect \
  2>&1 | tee -a "${LOG_OUT}" || true

echo "Waiting ${WAIT_SEC}s..."
sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >>"${LOG_OUT}" 2>&1 || true

python3 - "${LOG_OUT}" <<'PY'
import plistlib, sys
from pathlib import Path

log_path = Path(sys.argv[1])
logs = []
if Path("/tmp/azadi-group.plist").exists():
    logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def last(sub):
    for line in reversed(logs):
        if sub in line:
            return line
    return None

checks = [
    "LEAK_TEST_STARTED",
    "LEAK_TEST_PUBLIC_IP",
    "LEAK_TEST_DNS_RESULT",
    "LEAK_TEST_IPV6_RESULT",
    "LEAK_TEST_RESULT",
]
missing = [c for c in checks if not any(c in l for l in logs)]
connected = last("PSIPHON_CONNECTED_PROTOCOL")
internet = last("INTERNET_TEST_PASSED") or last("QUALITY_HTTPS_204_PASSED")
leak_result = last("LEAK_TEST_RESULT")

print("--- verification ---")
for c in checks:
    print("OK" if c not in missing else f"MISSING {c}", c)
if connected:
    print(connected)
if internet:
    print(internet)
if leak_result:
    print(leak_result)

protocol = connected or ""
if missing:
    print(f"FAIL: missing logs: {missing}")
    sys.exit(1)
if not internet and not any("INTERNET_TEST" in l for l in logs):
    print("FAIL: no internet/204 verification")
    sys.exit(1)
print(f"PASS: leak test protocol={protocol}")
PY

echo "Log file: ${LOG_OUT}"
