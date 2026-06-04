#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/iap-smoke-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== iap-products-smoke-test.sh ==="

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -3

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestLoadIAPProducts \
  2>&1 | tee -a "${LOG_OUT}" || true

sleep 10
"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >>"${LOG_OUT}" 2>&1 || true

python3 - <<'PY'
import plistlib, sys
from pathlib import Path

logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", []) if Path("/tmp/azadi-group.plist").exists() else []
loading = any("IAP_PRODUCTS_LOADING" in l for l in logs)
loaded = any("IAP_PRODUCTS_LOADED" in l for l in logs)
if not loading or not loaded:
    print("FAIL: missing IAP load logs")
    sys.exit(1)
print("PASS: IAP product loading smoke (count may be 0 without App Store Connect)")
PY

echo "Log file: ${LOG_OUT}"
