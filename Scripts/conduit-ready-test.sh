#!/usr/bin/env bash
# Expect Conduit distributor readiness when psiphon-config.local.json includes ServerEntrySignaturePublicKey.
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
LOCAL="${ROOT}/AzadiTunnel/Resources/Bundled/psiphon-config.local.json"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${CONDUIT_READY_WAIT_SEC:-18}"

if [[ ! -f "${LOCAL}" ]] || ! grep -q ServerEntrySignaturePublicKey "${LOCAL}"; then
  echo "FAIL: missing ${LOCAL} with ServerEntrySignaturePublicKey"
  exit 1
fi

if [[ ! -d "${APP}" ]]; then
  echo "Building for device ${DEVICE}..."
  xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
    -destination "generic/platform=iOS,id=${DEVICE}" \
    -derivedDataPath DerivedDataForCI build 2>&1 | tail -5
fi

if ! python3 -c "import json,sys; d=json.load(open('${APP}/psiphon-config.local.json')); sys.exit(0 if d.get('ServerEntrySignaturePublicKey','').strip() else 1)"; then
  echo "FAIL: built app bundle missing ServerEntrySignaturePublicKey in psiphon-config.local.json"
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

cfg_lines = [l for l in logs if len(l.split()) > 1 and l.split()[1] == "CONDUIT_CONFIG"]
if not cfg_lines:
    print("FAIL: no CONDUIT_CONFIG in logs")
    sys.exit(1)

cfg = cfg_lines[-1]
if "entry_sig_key=true" not in cfg or "remote_list=true" not in cfg:
    print("FAIL: expected entry_sig_key=true remote_list=true, got:", cfg.split("CONDUIT_CONFIG", 1)[-1].strip())
    sys.exit(1)

# Stale App Group config can log CONDUIT_BLOCKED once before UITestForceBootstrap reinstalls bundled+local merge.
last_ready_idx = max(i for i, l in enumerate(logs) if "CONDUIT_CONFIG" in l and "entry_sig_key=true" in l)
if any("CONDUIT_BLOCKED" in l and "missing_distributor_keys" in l for l in logs[last_ready_idx:]):
    print("FAIL: CONDUIT_BLOCKED after distributor keys became ready")
    for l in logs[last_ready_idx:]:
        if "CONDUIT" in l:
            print(l)
    sys.exit(1)

if has("PSIPHON_CONFIG_MERGE_FAILED"):
    print("FAIL: config merge failed")
    sys.exit(1)

print("PASS: Conduit distributor keys present (entry_sig_key=true, remote_list=true)")
PY
