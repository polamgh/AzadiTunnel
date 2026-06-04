#!/usr/bin/env bash
# Shiro vs Azadi Conduit investigation — saves reports under Tooling/test-logs/.
# Usage: ./Scripts/conduit-community-investigation.sh [device-uuid]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="${ROOT}/Tooling/test-logs/community-investigation-${STAMP}.txt"

mkdir -p "${ROOT}/Tooling/test-logs"

run_case() {
  local name="$1"
  local mode="$2"
  local wait="$3"
  shift 3
  echo ""
  echo "========== Case ${name}: mode=${mode} wait=${wait}s =========="
  if "${ROOT}/Scripts/conduit-full-connect-test.sh" "${DEVICE}" "${mode}" "${wait}" "$@" >>"${SUMMARY}" 2>&1; then
    echo "CASE_${name}=PASS" >>"${SUMMARY}"
  else
    echo "CASE_${name}=FAIL" >>"${SUMMARY}"
  fi
}

{
  echo "=== Conduit community investigation ${STAMP} ==="
  echo "device=${DEVICE}"
  echo "shiro_android_ref=/tmp/shiro-android (TunnelManager.java buildTunnelCoreConfig)"
  echo ""
} >"${SUMMARY}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build -quiet 2>&1 | tail -3 >>"${SUMMARY}" || true

# B first (regression guard)
run_case "B_PUBLIC" "public" 120

# A community-only (long)
run_case "A_COMMUNITY" "shirokhorshid" 420

# C auto Shiro-like (no UITestDisableSmartFallback — uses extension 180s fallback)
echo "" >>"${SUMMARY}"
echo "========== Case C_AUTO: mode=auto wait=600s (Shiro auto→public) ==========" >>"${SUMMARY}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
LOG_OUT="${ROOT}/Tooling/test-logs/conduit-auto-investigation-${STAMP}.log"
WAIT_SEC=600

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1 >>"${SUMMARY}" || true
export DEVICECTL_CHILD_UITEST_PROTOCOL=conduit
export DEVICECTL_CHILD_UITEST_CONDUIT_MODE=auto
export DEVICECTL_CHILD_UITEST_BEAST_MODE=0

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestSetProtocol conduit -UITestSetConduitMode auto \
  -UITestSetBeastMode 0 -UITestForceBootstrap -UITestAutoConnect 2>&1 | tail -2 >>"${SUMMARY}" || true

echo "Waiting ${WAIT_SEC}s for auto community→public..." >>"${SUMMARY}"
sleep "${WAIT_SEC}"
"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >"${LOG_OUT}" 2>&1 || true
cp /tmp/azadi-group.plist "${LOG_OUT}.plist" 2>/dev/null || true

python3 - "${LOG_OUT}" "${SUMMARY}" "${WAIT_SEC}" <<'PY'
import plistlib, re, sys
from pathlib import Path

log_path, summary_path, wait_sec = sys.argv[1:4]
logs = []
if Path("/tmp/azadi-group.plist").exists():
    logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def last(prefix, sub=None):
    for line in reversed(logs):
        if prefix not in line:
            continue
        if sub and sub not in line:
            continue
        return line
    return None

fallback = any("CONDUIT_PUBLIC_FALLBACK" in l for l in logs)
community_final = last("COMMUNITY_FINAL_RESULT")
connected = None
for line in reversed(logs):
    if "INPROXY-WEBRTC" in line and ("CONDUIT_CONNECTED_PROTOCOL" in line or "PSIPHON_CONNECTED_PROTOCOL" in line):
        m = re.search(r"(INPROXY-WEBRTC-[A-Z0-9-]+)", line)
        if m:
            connected = m.group(1)
            break

no_match = sum(1 for l in logs if "COMMUNITY_NO_MATCH" in l or "CONDUIT_NO_MATCH" in l)
if connected and fallback:
    verdict = "COMMUNITY_FALLBACK_TO_PUBLIC"
elif connected and not fallback:
    verdict = "COMMUNITY_CONNECTED"
elif no_match > 0:
    verdict = "COMMUNITY_NO_PEER_FOUND"
else:
    verdict = "COMMUNITY_TIMEOUT"

block = [
    "",
    "=== Case C_AUTO report ===",
    f"wait_seconds={wait_sec}",
    f"public_fallback={fallback}",
    f"connected_protocol={connected or 'none'}",
    f"community_no_match_events={no_match}",
    f"community_final_log={community_final or 'none'}",
    f"verdict={verdict}",
    f"log_file={log_path}",
]
text = "\n".join(block) + "\n"
Path(summary_path).open("a").write(text)
print(text)
PY

if grep -q "verdict=COMMUNITY_CONNECTED" "${SUMMARY}" && ! grep -q "public_fallback=True" "${SUMMARY}"; then
  echo "CASE_C_AUTO=PASS_COMMUNITY" >>"${SUMMARY}"
elif grep -q "connected_protocol=INPROXY" "${SUMMARY}" && grep -q "public_fallback=True" "${SUMMARY}"; then
  echo "CASE_C_AUTO=PASS_VIA_PUBLIC_FALLBACK" >>"${SUMMARY}"
else
  echo "CASE_C_AUTO=FAIL" >>"${SUMMARY}"
fi

echo ""
echo "Investigation summary: ${SUMMARY}"
cat "${SUMMARY}"
