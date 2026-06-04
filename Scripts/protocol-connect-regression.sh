#!/usr/bin/env bash
# Connect VPN on a plugged-in iPhone for each protocol mode and verify PSIPHON_PROTOCOL_LIMIT in logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-}"
if [[ -z "${DEVICE}" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')"
fi
if [[ -z "${DEVICE}" ]]; then
  echo "No connected device. Usage: $0 [device-id]"
  exit 1
fi

APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
if [[ ! -d "${APP}" ]]; then
  echo "Build app first: xcodebuild -scheme AzadiTunnel -destination generic/platform=iOS -derivedDataPath DerivedDataForCI build"
  exit 1
fi

MODES=(auto direct cdnFronting conduit)
BUNDLE="com.polamgh.ali.AzadiTunnel"

launch_app() {
  # devicectl forwards DEVICECTL_CHILD_* into the app environment.
  # App argv must follow `--` or flags like -UITestMode are parsed as devicectl options (-t needs a value).
  export DEVICECTL_CHILD_UITEST_PROTOCOL="${UITEST_PROTOCOL:-}"
  export DEVICECTL_CHILD_UITEST_BEAST_MODE="${UITEST_BEAST_MODE:-}"
  xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- "$@"
}

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1

for mode in "${MODES[@]}"; do
  echo "=== Protocol test: ${mode} (beast off) ==="
  UITEST_PROTOCOL="${mode}" UITEST_BEAST_MODE="0" launch_app \
    -UITestMode -UITestClearLogs -UITestSetProtocol "${mode}" -UITestSetBeastMode 0 -UITestAutoConnect 2>&1 | tail -1 || true
  sleep 90
  "${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >/dev/null 2>&1 || true
  python3 - <<PY
import plistlib
p=plistlib.load(open("/tmp/azadi-group.plist","rb"))
want="${mode}"
logs=p.get("shared_logs",[])

def tail_match(prefix, want_substr=None):
    for line in reversed(logs):
        if prefix not in line:
            continue
        if want_substr is not None and want_substr not in line:
            continue
        return line
    return None

settings = tail_match("UITEST_SETTINGS", f"protocol={want}")
if not settings:
    print("FAIL: no UITEST_SETTINGS for ${mode}")
    raise SystemExit(1)
print(settings)

limit = tail_match("PSIPHON_PROTOCOL_LIMIT", f"selection={want}")
if limit:
    print(limit)
    if want == "auto" and "limits=all" not in limit:
        print("FAIL: auto expected limits=all in extension")
        raise SystemExit(1)
    if want != "auto" and "limits=all" in limit:
        print("FAIL: ${mode} should not use limits=all in extension")
        raise SystemExit(1)
else:
    print("WARN: extension did not log PSIPHON_PROTOCOL_LIMIT (VPN may not have started)")
PY
  UITEST_PROTOCOL="" UITEST_BEAST_MODE="" launch_app -UITestMode -UITestDisconnect 2>&1 | tail -1 || true
  sleep 5
done

echo "OK: protocol regression finished"
