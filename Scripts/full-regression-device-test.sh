#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="${ROOT}/Tooling/test-logs/full-regression-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"
chmod +x "${ROOT}/Scripts/"*.sh 2>/dev/null || true

gap_between_tests() {
  local sec="${REGRESSION_GAP_SEC:-25}"
  echo "Cool-down ${sec}s before next test..." | tee -a "${SUMMARY}"
  sleep "${sec}"
}

run_test() {
  local name="$1"
  shift
  echo "" | tee -a "${SUMMARY}"
  echo "======== ${name} ========" | tee -a "${SUMMARY}"
  if "$@" >>"${SUMMARY}" 2>&1; then
    echo "RESULT: PASS ${name}" | tee -a "${SUMMARY}"
    return 0
  else
    echo "RESULT: FAIL ${name}" | tee -a "${SUMMARY}"
    return 1
  fi
}

FAIL=0

run_test "Auto+Beast" "${ROOT}/Scripts/beast-auto-connect-test.sh" "${DEVICE}" || FAIL=1
run_test "CDN+Beast" env CDN_TEST_BEAST=1 "${ROOT}/Scripts/cdn-fronting-connect-test.sh" "${DEVICE}" || FAIL=1
run_test "CDN no Beast" env CDN_TEST_BEAST=0 CDN_FRONTING_WAIT_SEC=180 "${ROOT}/Scripts/cdn-fronting-connect-test.sh" "${DEVICE}" || FAIL=1
run_test "Leak test" "${ROOT}/Scripts/leak-test-connect.sh" "${DEVICE}" || FAIL=1
gap_between_tests
run_test "Quality report" "${ROOT}/Scripts/quality-report-connect.sh" "${DEVICE}" || FAIL=1
gap_between_tests
export FALLBACK_TEST_WAIT_SEC="${FALLBACK_TEST_WAIT_SEC:-300}"
run_test "Fallback chain" "${ROOT}/Scripts/fallback-chain-test.sh" "${DEVICE}" || FAIL=1
gap_between_tests
run_test "Debug report" "${ROOT}/Scripts/debug-report-test.sh" "${DEVICE}" || FAIL=1
gap_between_tests
run_test "IAP smoke" "${ROOT}/Scripts/iap-products-smoke-test.sh" "${DEVICE}" || FAIL=1

echo "" | tee -a "${SUMMARY}"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "FINAL: PASS" | tee -a "${SUMMARY}"
  echo "Summary log: ${SUMMARY}"
  exit 0
else
  echo "FINAL: FAIL" | tee -a "${SUMMARY}"
  echo "Summary log: ${SUMMARY}"
  exit 1
fi
