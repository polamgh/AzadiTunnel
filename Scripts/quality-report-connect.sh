#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${QUALITY_TEST_WAIT_SEC:-90}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/quality-report-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== quality-report-connect.sh ==="
echo "Command: $0 ${DEVICE}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -5

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback \
  -UITestSetProtocol auto -UITestSetBeastMode 1 -UITestForceBootstrap -UITestAutoConnect \
  2>&1 | tee -a "${LOG_OUT}" || true

sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >>"${LOG_OUT}" 2>&1 || true

python3 - "${LOG_OUT}" <<'PY'
import plistlib, sys
from pathlib import Path

log_path = Path(sys.argv[1])
logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", []) if Path("/tmp/azadi-group.plist").exists() else []

def any_log(sub):
    return any(sub in l for l in logs)

required = [
    "QUALITY_TEST_STARTED",
    "QUALITY_PROTOCOL",
    "QUALITY_LATENCY_MS",
    "QUALITY_REPORT_READY",
]
missing = [r for r in required if not any_log(r)]
https_ok = any_log("QUALITY_HTTPS_204_PASSED")
https_fail = any_log("QUALITY_HTTPS_204_FAILED")
internet = any_log("INTERNET_TEST_PASSED")

print("--- verification ---")
for r in required:
    print("OK" if r not in missing else f"MISSING {r}")
print(f"HTTPS204 passed={https_ok} failed={https_fail} internet={internet}")

if missing:
    print(f"FAIL: missing {missing}")
    sys.exit(1)
if not https_ok and not internet:
    print("FAIL: no HTTPS 204 or internet test pass")
    sys.exit(1)
print("PASS: quality report")
PY

echo "Log file: ${LOG_OUT}"
