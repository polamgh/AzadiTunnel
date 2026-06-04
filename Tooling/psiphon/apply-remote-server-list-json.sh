#!/usr/bin/env bash
# Merge PSIPHON_REMOTE_SERVER_LIST_URLS_JSON (+ optional signature key) into gitignored psiphon-config.local.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/AzadiTunnel/Resources/Bundled/psiphon-config.local.json"
URLS_JSON="${PSIPHON_REMOTE_SERVER_LIST_URLS_JSON:-}"
SIG_KEY="${PSIPHON_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY:-}"

if [[ -z "$URLS_JSON" ]]; then
  if [[ -f "${ROOT}/Tooling/psiphon/remote-server-list-urls.json" ]]; then
    URLS_JSON="$(cat "${ROOT}/Tooling/psiphon/remote-server-list-urls.json")"
  else
    echo "Set PSIPHON_REMOTE_SERVER_LIST_URLS_JSON or add Tooling/psiphon/remote-server-list-urls.json" >&2
    exit 1
  fi
fi

if [[ -z "$SIG_KEY" && -f /tmp/shiro-apk/ShirOKhorshid.apk ]]; then
  SIG_KEY="$(python3 - <<'PY'
import re, zipfile
dex = zipfile.ZipFile("/tmp/shiro-apk/ShirOKhorshid.apk").read("classes.dex")
keys = sorted(set(m.group().decode() for m in re.finditer(rb"MIIC[A-Za-z0-9+/]{100,800}={0,2}", dex)))
print(keys[0] if keys else "")
PY
)"
fi

python3 - "$OUT" "$URLS_JSON" "$SIG_KEY" <<'PY'
import json, sys, base64

out_path, urls_json, sig_key = sys.argv[1:4]
urls = json.loads(urls_json)
if not isinstance(urls, list) or not urls:
    raise SystemExit("RemoteServerListURLs must be a non-empty JSON array")

has_zero = False
for i, item in enumerate(urls):
    if isinstance(item, str):
        raise SystemExit(f"entry {i}: use TransferURL objects with base64 URL field, not plain strings")
    url_b64 = item.get("URL", "")
    try:
        decoded = base64.b64decode(url_b64, validate=True).decode("utf-8")
    except Exception as e:
        raise SystemExit(f"entry {i}: invalid base64 URL: {e}")
    if not decoded.startswith("https://"):
        raise SystemExit(f"entry {i}: decoded URL must be https:// got {decoded[:40]!r}")
    if item.get("OnlyAfterAttempts", 0) == 0:
        has_zero = True

if not has_zero:
    raise SystemExit("At least one URL must have OnlyAfterAttempts=0 (Psiphon requirement)")

doc = {}
if out_path and __import__("pathlib").Path(out_path).is_file():
    doc = json.loads(open(out_path, encoding="utf-8").read())

if not doc.get("ServerEntrySignaturePublicKey", "").strip():
    raise SystemExit(
        "psiphon-config.local.json needs ServerEntrySignaturePublicKey first "
        "(copy psiphon-config.local.json.example or merge-shiro-distributor-keys.sh)"
    )

doc["RemoteServerListURLs"] = urls
if sig_key.strip():
    doc["RemoteServerListSignaturePublicKey"] = sig_key.strip()
elif not doc.get("RemoteServerListSignaturePublicKey", "").strip():
    print(
        "WARN: RemoteServerListSignaturePublicKey missing — tunnel-core rejects RemoteServerListURLs without it",
        file=sys.stderr,
    )

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(f"Wrote {out_path} ({len(urls)} remote list URLs)")
PY

if [[ "${PSIPHON_FETCH_REMOTE_ENTRIES:-0}" == "1" ]]; then
  "$(dirname "$0")/fetch-remote-server-entries.sh"
fi

echo "Rebuild, reinstall, or Settings → Advanced → Retry bundled install."
echo "Optional: PSIPHON_FETCH_REMOTE_ENTRIES=1 ./Tooling/psiphon/apply-remote-server-list-json.sh to merge remote lines into bundled supplement."
