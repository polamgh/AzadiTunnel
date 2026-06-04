#!/usr/bin/env bash
# Auto + Beast ON connect test (Shiro parity). Expect tunnel up within ~45s on a live device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
WAIT_SEC="${BEAST_AUTO_WAIT_SEC:-45}"

if [[ ! -d "${APP}" ]]; then
  echo "Build first: xcodebuild -scheme AzadiTunnel -destination generic/platform=iOS -derivedDataPath DerivedDataForCI build"
  exit 1
fi

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tail -1

export DEVICECTL_CHILD_UITEST_PROTOCOL=auto
export DEVICECTL_CHILD_UITEST_BEAST_MODE=1
xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestClearLogs -UITestDisableSmartFallback -UITestSetProtocol auto -UITestSetBeastMode 1 \
  -UITestForceBootstrap -UITestAutoConnect \
  2>&1 | tail -1 || true

echo "Waiting ${WAIT_SEC}s for Auto+Beast connect..."
sleep "${WAIT_SEC}"

"${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >/dev/null 2>&1 || true

python3 - <<PY
import plistlib
import sys

p = plistlib.load(open("/tmp/azadi-group.plist", "rb"))
logs = p.get("shared_logs", [])

def last(prefix):
    for line in reversed(logs):
        if prefix in line:
            return line
    return None

settings = last("UITEST_SETTINGS")
shiro = last("PSIPHON_SHIRO_CONFIG")
limit = last("PSIPHON_PROTOCOL_LIMIT")
connected = last("PSIPHON_CONNECTED_PROTOCOL") or last("TUNNEL_CONNECTED")
established = last("PSIPHON_TUNNEL_ESTABLISHED") or last("PSIPHON_TUNNEL_ESTABLISHED")
verify_fail = sum(1 for l in logs if "VerifySignature" in l and "missing public key" in l)

for line in (settings, shiro, limit, established, connected):
    if line:
        print(line)

if verify_fail:
    print(f"WARN: VerifySignature missing public key x{verify_fail}")

if not settings or "protocol=auto" not in settings or "beast=1" not in settings.replace("beast=true", "beast=1"):
    print("FAIL: expected UITEST_SETTINGS protocol=auto beast=1")
    sys.exit(1)

if shiro:
    if "aggressive=false" in shiro or "beast=false" in shiro:
        print("FAIL: PSIPHON_SHIRO_CONFIG missing beast/aggressive flags")
        sys.exit(1)
    if "meek_overrides=0" in shiro:
        print("FAIL: expected FrontedMeek dial overrides")
        sys.exit(1)

if limit and "limits=all" not in limit:
    print("FAIL: auto+beast expected limits=all")
    sys.exit(1)

if not (established or connected):
    print("FAIL: tunnel did not establish within wait window")
    sys.exit(1)

print("OK: Auto+Beast connect test passed")
PY
