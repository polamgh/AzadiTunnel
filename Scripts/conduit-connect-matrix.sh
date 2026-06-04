#!/usr/bin/env bash
# Run Shiro-requested Conduit device matrix on one iPhone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
SCRIPT="${ROOT}/Scripts/conduit-full-connect-test.sh"
FAIL=0

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tail -4

run() {
  local mode="$1" wait="$2"
  echo ""
  echo "########## Conduit matrix: ${mode} (${wait}s) ##########"
  if "${SCRIPT}" "${DEVICE}" "${mode}" "${wait}"; then
    echo "PASS ${mode}"
  else
    echo "FAIL ${mode}"
    FAIL=1
  fi
}

run shirokhorshid 420
run public 420
run auto 600

if [[ "${FAIL}" -eq 0 ]]; then
  echo "OK: conduit matrix passed"
else
  echo "Conduit matrix had failures — see Tooling/test-logs/"
  exit 1
fi
