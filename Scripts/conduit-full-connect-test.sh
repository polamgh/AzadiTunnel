#!/usr/bin/env bash
# Full Conduit connect — success only INPROXY-WEBRTC-* (not readiness, not TLS/CDN/Meek fallback).
# Usage: ./Scripts/conduit-full-connect-test.sh [device-uuid] [conduit-mode] [wait-seconds]
#   conduit-mode: shirokhorshid | public | auto  (default shirokhorshid)
#   wait-seconds: default 420
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
CONDUIT_MODE="${2:-${CONDUIT_TEST_MODE:-shirokhorshid}}"
WAIT_SEC="${3:-${CONDUIT_FULL_WAIT_SEC:-420}}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/conduit-${CONDUIT_MODE}-full-${STAMP}.log"
REPORT_OUT="${LOG_OUT%.log}-report.txt"

mkdir -p "${ROOT}/Tooling/test-logs"

APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"

CMD=(
  xcrun devicectl device process launch
  --device "${DEVICE}"
  --terminate-existing
  "${BUNDLE}"
  --
  -UITestMode
  -UITestClearLogs
  -UITestSetProtocol conduit
  -UITestSetConduitMode "${CONDUIT_MODE}"
  -UITestSetBeastMode 0
  -UITestDisableSmartFallback
  -UITestForceBootstrap
  -UITestAutoConnect
)

if [[ ! -d "${APP}" ]]; then
  echo "Building for device ${DEVICE}..."
  xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
    -destination "generic/platform=iOS,id=${DEVICE}" \
    -derivedDataPath DerivedDataForCI build 2>&1 | tail -5
fi

echo "=== Conduit full connect: mode=${CONDUIT_MODE} wait=${WAIT_SEC}s device=${DEVICE} ==="
xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1

export DEVICECTL_CHILD_UITEST_PROTOCOL=conduit
export DEVICECTL_CHILD_UITEST_CONDUIT_MODE="${CONDUIT_MODE}"
export DEVICECTL_CHILD_UITEST_BEAST_MODE=0

echo "Launch: ${CMD[*]}"
"${CMD[@]}" 2>&1 | tail -3 || true

echo "Waiting ${WAIT_SEC}s..."
sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >"${LOG_OUT}" 2>&1 || true
cp /tmp/azadi-group.plist "${LOG_OUT}.plist" 2>/dev/null || true

python3 - "${LOG_OUT}" "${REPORT_OUT}" "${WAIT_SEC}" "${CONDUIT_MODE}" "${CMD[*]}" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
report_path = Path(sys.argv[2])
wait_sec = int(sys.argv[3])
conduit_mode = sys.argv[4]
launch_cmd = sys.argv[5]

logs = []
if Path("/tmp/azadi-group.plist").exists():
    logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def last_match(prefix, substr=None):
    for line in reversed(logs):
        if prefix not in line:
            continue
        if substr and substr not in line:
            continue
        return line
    return None

def extract_raw_protocol(line):
    if not line:
        return None
    m = re.search(r"raw=([^\s]+)", line)
    return m.group(1) if m else None

def classify_protocol(raw):
    if not raw:
        return "none"
    if raw.startswith("INPROXY-WEBRTC-"):
        return "conduit"
    if "FRONTED-MEEK-CDN" in raw:
        return "cdn_fallback"
    if "FRONTED-MEEK" in raw:
        return "meek_fallback"
    if raw.startswith("TLS-") or raw == "TLS-OSSH":
        return "tls_fallback"
    if raw in ("SSH", "OSSH") or raw.endswith("-OSSH"):
        return "ssh_fallback"
    return "other"

connected_lines = [
    l for l in logs
    if "PSIPHON_CONNECTED_PROTOCOL" in l or "CONDUIT_CONNECTED_PROTOCOL" in l
    or ("TUNNEL_CONNECTED" in l and "INPROXY-WEBRTC" in l)
]
last_connected = connected_lines[-1] if connected_lines else None
raw = extract_raw_protocol(last_connected)
if not raw:
    for line in reversed(logs):
        if "INPROXY-WEBRTC" in line and (
            "PSIPHON_CONNECTED_PROTOCOL" in line or "CONDUIT_CONNECTED_PROTOCOL" in line
        ):
            m = re.search(r"(INPROXY-WEBRTC-[A-Z0-9-]+)", line)
            if m:
                raw = m.group(1)
                last_connected = line
                break

proto_class = classify_protocol(raw)
shiro = last_match("SHIRO_COMPARE_CONDUIT_CONFIG")
uitest = last_match("UITEST_SETTINGS")
conduit_cfg = last_match("CONDUIT_CONFIG")
compartment = last_match("CONDUIT_COMPARTMENT_MODE")
tactics = last_match("CONDUIT_TACTICS_READY")
broker_src = last_match("CONDUIT_BROKER_SPEC_SOURCE")
remote_ready = last_match("REMOTE_SERVER_LIST_FETCH", "phase=downloaded")
tunnel_established = last_match("PSIPHON_TUNNEL_ESTABLISHED")
public_fallback = any("CONDUIT_PUBLIC_FALLBACK" in l for l in logs)
no_match_count = sum(1 for l in logs if "CONDUIT_NO_MATCH" in l or "COMMUNITY_NO_MATCH" in l)
retry_count = sum(1 for l in logs if "CONDUIT_RETRY" in l)
community_started = last_match("COMMUNITY_COMPARE_STARTED")
community_hash = last_match("COMMUNITY_COMPARTMENT_ID_HASH")
community_broker = last_match("COMMUNITY_BROKER_REACHED")
community_specs = last_match("COMMUNITY_BROKER_SPEC_COUNT")
community_ice = last_match("COMMUNITY_ICE_STARTED")
community_peer = last_match("COMMUNITY_PEER_MATCHED")
community_final = last_match("COMMUNITY_FINAL_RESULT")
community_config = last_match("COMMUNITY_CONFIG_COMPARE")

broker_reached = any(
    "In-proxy broker selected" in l or "selected broker" in l.lower()
    for l in logs
) or any("CONDUIT_STATUS" in l and "broker" in l.lower() for l in logs)

inproxy_dial = any("inproxy-dial:" in l.lower() for l in logs) or retry_count > 0
webrtc = any("ICE gathering" in l for l in logs) or any(
    "candidateserver" in l.lower() or "candidate" in l.lower() for l in logs
)

if proto_class == "conduit":
    final = "CONDUIT_CONNECTED"
elif proto_class in ("cdn_fallback", "meek_fallback", "tls_fallback", "ssh_fallback"):
    final = "CONDUIT_FALLBACK"
else:
    final = "CONDUIT_NOT_CONNECTED"

community_verdict = "n/a"
if conduit_mode in ("shirokhorshid", "auto"):
    if proto_class == "conduit" and not public_fallback:
        community_verdict = "COMMUNITY_CONNECTED"
    elif proto_class == "conduit" and public_fallback:
        community_verdict = "COMMUNITY_FALLBACK_TO_PUBLIC"
    elif no_match_count > 0:
        community_verdict = "COMMUNITY_NO_PEER_FOUND"
    elif final == "CONDUIT_NOT_CONNECTED":
        community_verdict = "COMMUNITY_TIMEOUT"

lines = [
    "=== Conduit full connect test report ===",
    f"command: {launch_cmd}",
    f"conduit_mode: {conduit_mode}",
    f"wait_seconds: {wait_sec}",
    f"log_file: {log_path}",
    f"plist_file: {log_path}.plist",
    "",
    f"uitest_settings: {uitest or 'missing'}",
    f"shiro_compare: {shiro or 'missing'}",
    f"conduit_config: {conduit_cfg or 'missing'}",
    f"conduit_compartment_mode: {compartment or 'missing'}",
    f"tunnel_established: {tunnel_established or 'no'}",
    f"public_fallback: {public_fallback}",
    "",
    f"connected_protocol_raw: {raw or 'none'}",
    f"connected_protocol_class: {proto_class}",
    f"last_connected_line: {last_connected or 'none'}",
    "",
    f"broker_reached: {broker_reached}",
    f"conduit_tactics_ready: {tactics or 'not_logged'}",
    f"conduit_broker_spec_source: {broker_src or 'not_logged'}",
    f"conduit_remote_list_ready: {remote_ready or 'not_logged'}",
    f"inproxy_dial_started: {inproxy_dial}",
    f"webrtc_candidates_seen: {webrtc}",
    f"conduit_no_match_events: {no_match_count}",
    f"conduit_retry_events: {retry_count}",
    "",
    f"community_compare_started: {community_started or 'no'}",
    f"community_compartment_hash: {community_hash or 'no'}",
    f"community_config_compare: {community_config or 'no'}",
    f"community_broker_reached: {community_broker or 'no'}",
    f"community_broker_spec_count: {community_specs or 'no'}",
    f"community_ice_started: {community_ice or 'no'}",
    f"community_peer_matched: {community_peer or 'no'}",
    f"community_final_log: {community_final or 'no'}",
    f"community_verdict: {community_verdict}",
    "",
    f"final_result: {final}",
]

if proto_class == "conduit":
    lines.append("verdict: Conduit success (INPROXY-WEBRTC-*)")
elif proto_class != "none":
    lines.append(f"verdict: Conduit fallback — connected via {raw}")
else:
    lines.append("verdict: No INPROXY-WEBRTC-* connect within wait window")

report = "\n".join(lines) + "\n"
report_path.write_text(report, encoding="utf-8")
print(report)
with log_path.open("a", encoding="utf-8") as f:
    f.write("\n\n--- conduit-full-connect-test report ---\n")
    f.write(report)

sys.exit(0 if final == "CONDUIT_CONNECTED" else 1)
PY

echo "Saved: ${LOG_OUT}"
echo "Saved: ${REPORT_OUT}"
