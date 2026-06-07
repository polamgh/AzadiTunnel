#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${SECURE_DNS_WAIT_SEC:-120}"
MODE="${SECURE_DNS_MODE:-doh}"
PROVIDER="${SECURE_DNS_PROVIDER:-cloudflare}"
BLOCK_CLEARTEXT="${SECURE_DNS_BLOCK_CLEARTEXT:-0}"
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
echo "Block cleartext: ${BLOCK_CLEARTEXT}"
echo "Expect: ${EXPECT}"
echo "Proxy Only: ${PROXY_ONLY}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -8

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

launch_args=(
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback
  -UITestSetProtocol auto -UITestSetBeastMode 1 -UITestForceBootstrap -UITestAutoConnect
  -UITestSetProxyOnlyMode "${PROXY_ONLY}"
  -UITestSetSecureDNSMode "${MODE}" -UITestSetSecureDNSProvider "${PROVIDER}"
  -UITestSetSecureDNSBlockCleartext "${BLOCK_CLEARTEXT}"
  -UITestVerifyFeatures
)
if [[ -n "${CUSTOM_DOH_URL}" ]]; then
  launch_args+=(-UITestSetSecureDNSCustomDoHURL "${CUSTOM_DOH_URL}")
fi
if [[ "${MODE}" != "off" && "${PROXY_ONLY}" != "1" ]]; then
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
    "SECURE_DNS_DISABLED",
    "TUNNEL_DNS_ADVERTISED",
    "SECURE_DNS_SYSTEM_PROXY",
    "TUNNEL_HTTP_PROXY",
    "DNS_QUERY_RECEIVED",
    "SECURE_DNS_SELECTED",
    "SECURE_DNS_DOH_CONNECT",
    "SECURE_DNS_DOH_QUERY_OK",
    "SECURE_DNS_DOH_QUERY_FAILED",
    "DNS_LEGACY_FALLBACK",
    "SECURE_DNS_CLEAR_TEXT_BLOCKED",
    "DNS_RESPONSE_SENT",
    "SECURE_DNS_SYSTEM_HTTP_RESOLVED",
    "SECURE_DNS_SYSTEM_HTTP_PROXY_FALLBACK",
    "SECURE_DNS_BYPASS_DETECTED",
    "PROXY_ONLY_NO_DEFAULT_ROUTE",
    "PROXY_ONLY_NO_SYSTEM_PROXY",
    "FEATURE_OK secure_dns_test",
    "FEATURE_FAIL secure_dns_test",
]

print("--- verification ---")
print("log_lines", len(logs))
print("expect", expect)
for token in interesting:
    line = last(token)
    if line:
        print(line)

failures = []

if expect == "off":
    require("SECURE_DNS_DISABLED", bool(any_sub("SECURE_DNS_DISABLED")))
    require("no SECURE_DNS_DOH_QUERY_OK", not any_sub("SECURE_DNS_DOH_QUERY_OK"))
    require("no SECURE_DNS_DOH_CONNECT", not any_sub("SECURE_DNS_DOH_CONNECT"))
    require("legacy/off connectivity path", bool(any_sub("INTERNET_TEST_PASSED") or any_all("DNS_RESPONSE_SENT", "secure=false")))
elif expect == "doh":
    require("SECURE_DNS_ENABLED", bool(any_sub("SECURE_DNS_ENABLED")))
    require("TUNNEL_DNS_ADVERTISED", bool(any_sub("TUNNEL_DNS_ADVERTISED")))
    require("SECURE_DNS_SYSTEM_PROXY using_loopback_bridge", bool(any_all("SECURE_DNS_SYSTEM_PROXY", "using_loopback_bridge")))
    require("TUNNEL_HTTP_PROXY secure_dns_bridge=true", bool(any_all("TUNNEL_HTTP_PROXY", "secure_dns_bridge=true")))
    require("DNS_QUERY_RECEIVED", bool(any_sub("DNS_QUERY_RECEIVED")))
    require("SECURE_DNS_SELECTED mode=doh", bool(any_all("SECURE_DNS_SELECTED", "mode=doh")))
    require("SECURE_DNS_DOH_CONNECT proxy=socks", bool(any_all("SECURE_DNS_DOH_CONNECT", "proxy=socks")))
    require("SECURE_DNS_DOH_QUERY_OK", bool(any_sub("SECURE_DNS_DOH_QUERY_OK")))
    require("DNS_RESPONSE_SENT secure=true", bool(any_all("DNS_RESPONSE_SENT", "secure=true")))
    require("no DNS_LEGACY_FALLBACK", not any_sub("DNS_LEGACY_FALLBACK"))
elif expect == "fallback":
    require("SECURE_DNS_SELECTED mode=doh", bool(any_all("SECURE_DNS_SELECTED", "mode=doh")))
    require("SECURE_DNS_DOH_QUERY_FAILED", bool(any_sub("SECURE_DNS_DOH_QUERY_FAILED")))
    require("DNS_LEGACY_FALLBACK", bool(any_sub("DNS_LEGACY_FALLBACK")))
    require("DNS_RESPONSE_SENT secure=false", bool(any_all("DNS_RESPONSE_SENT", "secure=false")))
    require("no SECURE_DNS_CLEAR_TEXT_BLOCKED", not any_sub("SECURE_DNS_CLEAR_TEXT_BLOCKED"))
elif expect == "blocked":
    require("SECURE_DNS_SELECTED mode=doh", bool(any_all("SECURE_DNS_SELECTED", "mode=doh")))
    require("SECURE_DNS_DOH_QUERY_FAILED", bool(any_sub("SECURE_DNS_DOH_QUERY_FAILED")))
    require("SECURE_DNS_CLEAR_TEXT_BLOCKED", bool(any_sub("SECURE_DNS_CLEAR_TEXT_BLOCKED")))
    require("DNS_RESPONSE_SENT servfail", bool(any_all("DNS_RESPONSE_SENT", "servfail=blocked_cleartext")))
    require("no DNS_LEGACY_FALLBACK", not any_sub("DNS_LEGACY_FALLBACK"))
elif expect == "proxy-only":
    require("PROXY_ONLY_NO_DEFAULT_ROUTE", bool(any_sub("PROXY_ONLY_NO_DEFAULT_ROUTE")))
    require("PROXY_ONLY_NO_SYSTEM_PROXY", bool(any_sub("PROXY_ONLY_NO_SYSTEM_PROXY")))
    require("no TUNNEL_DNS_ADVERTISED", not any_sub("TUNNEL_DNS_ADVERTISED"))
    require("no PACKET_FORWARDING_STARTED", not any_sub("PACKET_FORWARDING_STARTED"))
else:
    print(f"FAIL: unknown SECURE_DNS_EXPECT={expect!r}")
    sys.exit(1)

if failures:
    print(f"FAIL: missing checks: {failures}")
    print(f"Log file: {log_path}")
    sys.exit(1)

print(f"PASS: Secure DNS scenario {expect}")
PY

echo "Log file: ${LOG_OUT}"
