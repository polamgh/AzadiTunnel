#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${FALLBACK_TEST_WAIT_SEC:-240}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/fallback-chain-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== fallback-chain-test.sh ==="
echo "Command: $0 ${DEVICE}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -5

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestEnableSmartFallback -UITestForceFallbackFailCDN \
  -UITestSetProtocol cdnFronting -UITestSetBeastMode 1 -UITestForceBootstrap -UITestAutoConnect \
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

required = ["FALLBACK_CHAIN_STARTED", "FALLBACK_ATTEMPT", "FALLBACK_SUCCESS"]
missing = [r for r in required if not any_log(r)]
cdn_fail = any_log("FALLBACK_FAILED") and "transport=cdn" in "".join(logs)
internet = any_log("INTERNET_TEST_PASSED") or any_log("QUALITY_HTTPS_204_PASSED")

print("--- verification ---")
for r in required:
    print("OK" if r not in missing else f"MISSING {r}")
print(f"cdn_failed_logged={cdn_fail} internet={internet}")

if missing:
    print(f"FAIL: missing {missing}")
    sys.exit(1)
if not cdn_fail:
    print("WARN: expected CDN step failure log (UITestForceFallbackFailCDN)")
if not internet:
    print("FAIL: no internet after fallback")
    sys.exit(1)
print("PASS: fallback chain")
PY

echo "Log file: ${LOG_OUT}"
