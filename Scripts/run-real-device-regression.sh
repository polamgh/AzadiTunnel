#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

DEVICE="${1:-00008120-000170D03E10201E}"
DERIVED="${DERIVED_DATA_PATH:-${ROOT}/DerivedDataForCI}"
LOG_DIR="${ROOT}/Tooling/test-logs"
mkdir -p "${LOG_DIR}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="${LOG_DIR}/xcodebuild-uitest-${STAMP}.log"

if ! xcodebuild -showdestinations -project AzadiTunnel.xcodeproj -scheme AzadiTunnelUITests 2>/dev/null | grep -q "${DEVICE}"; then
  echo "FAIL: device ${DEVICE} not visible to Xcode (unlock iPhone, enable Developer Mode, reconnect USB)."
  xcodebuild -showdestinations -project AzadiTunnel.xcodeproj -scheme AzadiTunnelUITests 2>&1 | grep -E "platform:iOS|id:" || true
  exit 1
fi

echo "Device preflight: unlock iPhone and enable Settings → Developer → Enable UI Automation (required for XCTest on iOS 16+)."

# Warm up VPN permission + bundled config (devicectl) before XCTest runner launches the app.
if [[ -x "${ROOT}/Scripts/beast-auto-connect-test.sh" ]]; then
  echo "Warming up VPN via beast-auto-connect-test.sh ..."
  BEAST_AUTO_WAIT_SEC=60 "${ROOT}/Scripts/beast-auto-connect-test.sh" "${DEVICE}" 2>&1 | tail -8 || true
  sleep 3
fi

xcodebuild build-for-testing \
  -project AzadiTunnel.xcodeproj \
  -scheme AzadiTunnelUITests \
  -destination "platform=iOS,id=${DEVICE}" \
  -derivedDataPath "${DERIVED}" \
  -parallel-testing-enabled NO \
  2>&1 | tee "${LOG_DIR}/xcodebuild-build-for-testing-${STAMP}.log" | tail -5

XCTESTRUN="$(find "${DERIVED}/Build/Products" -name 'AzadiTunnelUITests_*.xctestrun' | head -1)"
if [[ -z "${XCTESTRUN}" ]]; then
  echo "FAIL: xctestrun not found under ${DERIVED}/Build/Products"
  exit 1
fi

python3 "${ROOT}/Scripts/patch-xctestrun-bootstrap.py" "${XCTESTRUN}"

xcodebuild test-without-building \
  -xctestrun "${XCTESTRUN}" \
  -destination "platform=iOS,id=${DEVICE}" \
  -derivedDataPath "${DERIVED}" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -destination-timeout 300 \
  2>&1 | tee "${LOG_FILE}"

echo "Saved xcodebuild log: ${LOG_FILE}"
