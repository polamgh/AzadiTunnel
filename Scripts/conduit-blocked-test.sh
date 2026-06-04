#!/usr/bin/env bash
# Expect Conduit connect to be blocked without distributor keys in psiphon-config.local.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${CONDUIT_BLOCKED_WAIT_SEC:-12}"

if [[ ! -d "${APP}" ]]; then
  echo "Build first."
  exit 1
fi

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1

export DEVICECTL_CHILD_UITEST_PROTOCOL=conduit
export DEVICECTL_CHILD_UITEST_BEAST_MODE=0
xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestSetProtocol conduit -UITestSetBeastMode 0 -UITestForceBootstrap -UITestAutoConnect \
  2>&1 | tail -1 || true

sleep "${WAIT_SEC}"
"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >/dev/null 2>&1 || true

python3 - <<'PY'
import plistlib
import sys

logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", [])

def has(sub):
    return any(sub in l for l in logs)

if not has("CONDUIT_BLOCKED") or not has("missing_distributor_keys"):
    print("FAIL: expected CONDUIT_BLOCKED missing_distributor_keys")
    for l in logs:
        if "CONDUIT" in l:
            print(l)
    sys.exit(1)

cfg = [l for l in logs if "CONDUIT_CONFIG" in l][-1] if any("CONDUIT_CONFIG" in l for l in logs) else ""
if cfg and "entry_sig_key=false" not in cfg:
    print("FAIL: expected entry_sig_key=false in CONDUIT_CONFIG, got:", cfg)
    sys.exit(1)

if has("inproxy-dial:"):
    print("FAIL: inproxy-dial should not start without distributor keys")
    sys.exit(1)

print("PASS: Conduit blocked without distributor keys")
PY
