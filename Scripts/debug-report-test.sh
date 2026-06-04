#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-00008120-000170D03E10201E}"
APP="${ROOT}/DerivedDataForCI/Build/Products/Debug-iphoneos/AzadiTunnel.app"
BUNDLE="com.polamgh.ali.AzadiTunnel"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_OUT="${ROOT}/Tooling/test-logs/debug-report-${STAMP}.log"

mkdir -p "${ROOT}/Tooling/test-logs"

echo "=== debug-report-test.sh ==="
echo "Command: $0 ${DEVICE}"

xcodebuild -project "${ROOT}/AzadiTunnel.xcodeproj" -scheme AzadiTunnel \
  -destination "generic/platform=iOS,id=${DEVICE}" \
  -derivedDataPath DerivedDataForCI build 2>&1 | tee "${LOG_OUT}.build" | tail -5

xcrun devicectl device install app --device "${DEVICE}" "${APP}" 2>&1 | tee -a "${LOG_OUT}"

xcrun devicectl device process launch --device "${DEVICE}" --terminate-existing "${BUNDLE}" -- \
  -UITestMode -UITestExportDebugReport \
  2>&1 | tee -a "${LOG_OUT}" || true

sleep 12

for _ in 1 2 3; do
  if "${ROOT}/Scripts/pull-device-logs.sh" "${DEVICE}" >>"${LOG_OUT}" 2>&1; then
    break
  fi
  sleep 3
done

python3 - "${LOG_OUT}" <<'PY'
import plistlib, sys, re
from pathlib import Path

log_path = Path(sys.argv[1])
logs = plistlib.load(open("/tmp/azadi-group.plist", "rb")).get("shared_logs", []) if Path("/tmp/azadi-group.plist").exists() else []

def any_log(sub):
    return any(sub in l for l in logs)

required = ["DEBUG_REPORT_EXPORT_STARTED", "DEBUG_REPORT_SANITIZED", "DEBUG_REPORT_EXPORT_READY"]
missing = [r for r in required if not any_log(r)]
secret_hits = []
for line in logs:
    if re.search(r'(PrivateKey|Obfuscated.*Key|password=)[^\s]{20,}', line, re.I):
        secret_hits.append(line[:80])

print("--- verification ---")
for r in required:
    print("OK" if r not in missing else f"MISSING {r}")
if secret_hits:
    print(f"FAIL: possible secrets in logs ({len(secret_hits)} lines)")
    sys.exit(1)
if missing:
    print(f"FAIL: missing {missing}")
    sys.exit(1)
print("PASS: debug report export")
PY

echo "Log file: ${LOG_OUT}"
