#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/legal-pages-smoke-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== legal-pages-smoke-test.sh ===" | tee "${LOG_OUT}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnelUITests \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee -a "${LOG_OUT}.build" | tail -8

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee -a "${LOG_OUT}.build" | tail -5

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcodebuild test -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnelUITests \
  -destination "platform=iOS,id=${DEVICE}" \
  -only-testing:AzadiTunnelUITests/AzadiTunnelLegalTests/testLegalAndPrivacyPagesOpen \
  2>&1 | tee -a "${LOG_OUT}"

echo "Log file: ${LOG_OUT}"
