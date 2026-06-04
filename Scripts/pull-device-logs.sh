#!/usr/bin/env bash
set -euo pipefail
DEVICE="${1:-}"
if [[ -z "${DEVICE}" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')"
fi
OUT="${2:-/tmp/azadi-group.plist}"
xcrun devicectl device copy from --device "${DEVICE}" \
  --domain-type appGroupDataContainer \
  --domain-identifier group.com.polamgh.ali.AzadiTunnel \
  --source Library/Preferences/group.com.polamgh.ali.AzadiTunnel.plist \
  --destination "${OUT}"
python3 - <<PY
import plistlib, sys
path = "${OUT}"
with open(path, "rb") as f:
    logs = plistlib.load(f).get("shared_logs", [])
print("\n".join(logs[-40:]))
print("--- last_internet_test_ok ---", plistlib.load(open(path,"rb")).get("last_internet_test_ok"))
PY
