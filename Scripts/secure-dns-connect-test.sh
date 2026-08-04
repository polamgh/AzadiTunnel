#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${SECURE_DNS_WAIT_SEC:-120}"
MODE="${SECURE_DNS_MODE:-doh}"
PROVIDER="${SECURE_DNS_PROVIDER:-cloudflare}"
CUSTOM_DOH_URL="${SECURE_DNS_CUSTOM_DOH_URL:-}"
EXPECT="${SECURE_DNS_EXPECT:-doh}"
PROXY_ONLY="${SECURE_DNS_PROXY_ONLY:-0}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/secure-dns-test-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== secure-dns-connect-test.sh ==="
echo "Device: ${DEVICE}"
echo "Wait: ${WAIT_SEC}s"
echo "Mode: ${MODE}"
echo "Provider: ${PROVIDER}"
echo "Expect: ${EXPECT}"
echo "Proxy Only: ${PROXY_ONLY}"

if [[ "${MODE}" != "doh" ]]; then
  echo "Secure DNS is mandatory DoH; SECURE_DNS_MODE must be doh" >&2
  exit 2
fi

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -8

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

launch_args=(
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback
  -UITestSetProtocol auto -UITestSetBeastMode 1 -UITestForceBootstrap -UITestAutoConnect
  -UITestSetProxyOnlyMode "${PROXY_ONLY}"
  -UITestSetSecureDNSMode "${MODE}" -UITestSetSecureDNSProvider "${PROVIDER}"
  -UITestVerifyFeatures
)
if [[ -n "${CUSTOM_DOH_URL}" ]]; then
  launch_args+=(-UITestSetSecureDNSCustomDoHURL "${CUSTOM_DOH_URL}")
fi
if [[ "${PROXY_ONLY}" != "1" ]]; then
  launch_args+=(-UITestVerifySecureDNS)
fi

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  "${launch_args[@]}" 2>&1 | tee -a "${LOG_OUT}" || true

echo "Waiting ${WAIT_SEC}s..."
sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >>"${LOG_OUT}" 2>&1 || true

python3 - "${LOG_OUT}" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
expect = os.environ.get("SECURE_DNS_EXPECT", "doh").strip().lower()
logs = []
if Path("/tmp/azadi-group.plist").exists():
    logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def any_sub(sub):
    return [line for line in logs if sub in line]

def any_all(*parts):
    return [line for line in logs if all(part in line for part in parts)]

def last(sub):
    for line in reversed(logs):
        if sub in line:
            return line
    return None

def require(label, ok):
    print(("OK " if ok else "MISSING ") + label)
    if not ok:
        failures.append(label)

interesting = [
    "UITEST_SETTINGS",
    "SECURE_DNS_ENABLED",
    "SECURE_DNS_ADMISSION_CONFIG",
    "TUNNEL_DNS_ADVERTISED",
    "TUNNEL_HTTP_PROXY",
    "SECURE_DNS_BYPASS_DETECTED",
    "SECURE_DNS_TEST_STARTED",
    "SECURE_DNS_TEST_OK",
    "SECURE_DNS_TEST_FAILED",
    "PROXY_ONLY_NO_DEFAULT_ROUTE",
    "PROXY_ONLY_NO_SYSTEM_PROXY",
    "FEATURE_OK secure_dns_test",
    "FEATURE_FAIL secure_dns_test",
    "FEATURE_OK internet_probe",
    "FEATURE_OK main_app_ip_https",
    "FEATURE_OK main_app_http",
    "FEATURE_FAIL internet_probe",
    "FEATURE_FAIL main_app_ip_https",
    "FEATURE_FAIL main_app_http",
]

print("--- verification ---")
print("log_lines", len(logs))
print("expect", expect)
for token in interesting:
    line = last(token)
    if line:
        print(line)

failures = []

if expect == "doh":
    require("SECURE_DNS_ENABLED", bool(any_sub("SECURE_DNS_ENABLED")))
    require(
        "SECURE_DNS_ADMISSION_CONFIG max_in_flight=4 max_queued=64",
        bool(any_all("SECURE_DNS_ADMISSION_CONFIG", "max_in_flight=4", "max_queued=64")),
    )
    require("TUNNEL_DNS_ADVERTISED", bool(any_sub("TUNNEL_DNS_ADVERTISED")))
    require("SECURE_DNS_TEST_STARTED", bool(any_sub("SECURE_DNS_TEST_STARTED")))
    require("SECURE_DNS_TEST_OK", bool(any_sub("SECURE_DNS_TEST_OK")))
    require("FEATURE_OK secure_dns_test", bool(any_all("FEATURE_OK", "secure_dns_test")))
    require("FEATURE_OK internet_probe", bool(any_all("FEATURE_OK", "internet_probe")))
    require("FEATURE_OK main_app_ip_https", bool(any_all("FEATURE_OK", "main_app_ip_https")))
    require("FEATURE_OK main_app_http", bool(any_all("FEATURE_OK", "main_app_http")))
    require("no FEATURE_FAIL internet_probe", not any_all("FEATURE_FAIL", "internet_probe"))
    require("no FEATURE_FAIL main_app_ip_https", not any_all("FEATURE_FAIL", "main_app_ip_https"))
    require("no FEATURE_FAIL main_app_http", not any_all("FEATURE_FAIL", "main_app_http"))
elif expect == "proxy-only":
    require("PROXY_ONLY_NO_DEFAULT_ROUTE", bool(any_sub("PROXY_ONLY_NO_DEFAULT_ROUTE")))
    require("PROXY_ONLY_NO_SYSTEM_PROXY", bool(any_sub("PROXY_ONLY_NO_SYSTEM_PROXY")))
    require("no TUNNEL_DNS_ADVERTISED", not any_sub("TUNNEL_DNS_ADVERTISED"))
    require("no PACKET_FORWARDING_STARTED", not any_sub("PACKET_FORWARDING_STARTED"))
else:
    print(f"FAIL: expected scenario must be doh or proxy-only, got {expect!r}")
    sys.exit(1)

if failures:
    print(f"FAIL: missing checks: {failures}")
    print(f"Log file: {log_path}")
    sys.exit(1)

print(f"PASS: Secure DNS scenario {expect}")
PY

echo "Log file: ${LOG_OUT}"
