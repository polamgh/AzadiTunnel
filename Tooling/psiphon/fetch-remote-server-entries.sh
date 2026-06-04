#!/usr/bin/env bash
# Download + verify remote server list (tunnel-core) and write gitignored supplement for bootstrap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLED="${ROOT}/AzadiTunnel/Resources/Bundled"
CONFIG_BASE="${BUNDLED}/psiphon-config.json"
CONFIG_LOCAL="${BUNDLED}/psiphon-config.local.json"
EMBEDDED="${BUNDLED}/psiphon-embedded-server-entries.txt"
OUT="${BUNDLED}/psiphon-embedded-server-entries.remote-supplement.txt"
TOOL_DIR="${ROOT}/Tooling/psiphon/fetch-remote-entries"
TMP_CONFIG="$(mktemp)"
TMP_DATA="$(mktemp -d)"
trap 'rm -f "$TMP_CONFIG"; rm -rf "$TMP_DATA"' EXIT

if [[ ! -f "$CONFIG_LOCAL" ]]; then
  echo "Missing $CONFIG_LOCAL — run apply-remote-server-list-json.sh and set distributor keys first." >&2
  exit 1
fi

python3 - "$CONFIG_BASE" "$CONFIG_LOCAL" "$TMP_CONFIG" <<'PY'
import json, sys
base_path, local_path, out_path = sys.argv[1:4]
base = json.load(open(base_path, encoding="utf-8")) if __import__("pathlib").Path(base_path).is_file() else {}
local = json.load(open(local_path, encoding="utf-8"))
merged = {**base, **local}
if not merged.get("RemoteServerListURLs"):
    raise SystemExit("RemoteServerListURLs missing in local config")
if not merged.get("RemoteServerListSignaturePublicKey", "").strip():
    raise SystemExit("RemoteServerListSignaturePublicKey missing")
if not merged.get("ServerEntrySignaturePublicKey", "").strip():
    raise SystemExit("ServerEntrySignaturePublicKey missing")
json.dump(merged, open(out_path, "w", encoding="utf-8"))
PY

echo "Fetching remote server list into supplement (may take ~30s)..."
(
  cd "$TOOL_DIR"
  go run . -config "$TMP_CONFIG" -data-dir "$TMP_DATA" -out "$OUT" -embedded "$EMBEDDED"
)

echo "Done. Rebuild app or Settings → Advanced → Retry bundled install."
echo "Supplement: $OUT"
