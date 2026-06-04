#!/usr/bin/env bash
# Write gitignored psiphon-config.local.json from Shiro Android build env vars (CI secrets).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/AzadiTunnel/Resources/Bundled/psiphon-config.local.json"

entry_key="${PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY:-}"
exchange_key="${PSIPHON_SERVER_ENTRY_EXCHANGE_OBFUSCATION_KEY:-}"
client_version="${PSIPHON_CLIENT_VERSION:-453}"
remote_urls="${PSIPHON_REMOTE_SERVER_LIST_URLS_JSON:-[]}"
remote_sig="${PSIPHON_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY:-}"
obf_roots="${PSIPHON_OBFUSCATED_SERVER_LIST_ROOT_URLS_JSON:-[]}"

if [[ -z "$entry_key" ]]; then
  echo "PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY is required (same as Shiro Gradle / GitHub Actions secret)." >&2
  exit 1
fi

python3 - "$OUT" "$entry_key" "$exchange_key" "$client_version" "$remote_urls" "$remote_sig" "$obf_roots" <<'PY'
import json, sys
out, entry, exchange, client_version, remote_urls, remote_sig, obf = sys.argv[1:8]
remote_urls = json.loads(remote_urls)
obf = json.loads(obf)
doc = {"ServerEntrySignaturePublicKey": entry}
if client_version:
    doc["ClientVersion"] = client_version
if exchange:
    doc["ExchangeObfuscationKey"] = exchange
if remote_urls:
    doc["RemoteServerListURLs"] = remote_urls
if remote_sig:
    doc["RemoteServerListSignaturePublicKey"] = remote_sig
if obf:
    doc["ObfuscatedServerListRootURLs"] = obf
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print("Wrote", out)
PY

echo "Rebuild AzadiTunnel, then Settings → Advanced → Retry bundled install (or reinstall)."
