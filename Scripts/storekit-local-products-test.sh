#!/usr/bin/env bash
# Verifies StoreKit local configuration loads all 5 IAP products via XCTest on iOS Simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-${ROOT}/DerivedDataForCI}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/storekit-local-${STAMP}.log"
SIM_NAME="${SIM_NAME:-iPhone 16}"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== storekit-local-products-test.sh ===" | tee "${LOG_OUT}"

python3 - <<'PY' | tee -a "${LOG_OUT}"
import json
from pathlib import Path

path = Path("Configuration.storekit")
data = json.loads(path.read_text())
ids = {p["productID"] for p in data.get("products", [])}
for group in data.get("subscriptionGroups", []):
    for sub in group.get("subscriptions", []):
        ids.add(sub["productID"])
expected = {
    "azaditunnel.tip.small",
    "azaditunnel.tip.medium",
    "azaditunnel.tip.large",
    "azaditunnel.support.monthly",
    "azaditunnel.support.yearly",
}
missing = expected - ids
if missing:
    print("FAIL: Configuration.storekit missing product IDs:", sorted(missing))
    raise SystemExit(1)
print("PASS: Configuration.storekit defines all 5 product IDs")
PY

SIM_UDID="$(xcrun simctl list devices available 2>/dev/null | python3 -c "
import re, sys
name = sys.argv[1]
for line in sys.stdin:
    m = re.search(r'\s+(' + re.escape(name) + r'.*?)\s+\(([A-F0-9-]+)\)\s+\((Booted|Shutdown)\)', line)
    if m:
        print(m.group(2))
        break
" "${SIM_NAME}")"

if [[ -z "${SIM_UDID}" ]]; then
  echo "FAIL: simulator '${SIM_NAME}' not found" | tee -a "${LOG_OUT}"
  xcrun simctl list devices available | grep -i iphone | head -10 | tee -a "${LOG_OUT}"
  exit 1
fi

echo "Using simulator ${SIM_NAME} (${SIM_UDID})" | tee -a "${LOG_OUT}"
xcrun simctl boot "${SIM_UDID}" 2>/dev/null || true

xcodebuild build-for-testing \
  -project "${ROOT}/AzadiTunnel.xcodeproj" \
  -scheme AzadiTunnelUITests \
  -destination "platform=iOS Simulator,id=${SIM_UDID}" \
  -derivedDataPath "${DERIVED}" \
  2>&1 | tee -a "${LOG_OUT}.build" | tail -5

xcodebuild test-without-building \
  -project "${ROOT}/AzadiTunnel.xcodeproj" \
  -scheme AzadiTunnelUITests \
  -destination "platform=iOS Simulator,id=${SIM_UDID}" \
  -derivedDataPath "${DERIVED}" \
  -parallel-testing-enabled NO \
  -only-testing:AzadiTunnelUITests/AzadiTunnelLegalTests/testStoreKitLocalProductsLoad \
  2>&1 | tee -a "${LOG_OUT}" | tail -20

if grep -q "Test Case.*testStoreKitLocalProductsLoad.*passed" "${LOG_OUT}"; then
  echo "PASS: StoreKit local products UI test" | tee -a "${LOG_OUT}"
else
  echo "FAIL: testStoreKitLocalProductsLoad did not pass" | tee -a "${LOG_OUT}"
  exit 1
fi

PLIST="$(find "${HOME}/Library/Developer/CoreSimulator/Devices/${SIM_UDID}/data/Containers/Shared/AppGroup" \
  -name "group.com.polamgh.ali.AzadiTunnel.plist" 2>/dev/null | head -1)"
if [[ -n "${PLIST}" ]]; then
  python3 - <<PY | tee -a "${LOG_OUT}"
import plistlib, re, sys
from pathlib import Path
logs = plistlib.load(open("${PLIST}", "rb")).get("shared_logs", [])
loaded = [l for l in logs if "IAP_PRODUCTS_LOADED" in l]
count = 0
for line in loaded:
    m = re.search(r"count=(\d+)", line)
    if m:
        count = max(count, int(m.group(1)))
print("IAP log lines:", loaded[-2:])
if count >= 5:
    print(f"PASS: IAP_PRODUCTS_LOADED count={count}")
else:
    print(f"WARN: IAP log count={count} (UI test already passed)")
PY
fi

echo "Log file: ${LOG_OUT}"
