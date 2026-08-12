#!/usr/bin/env bash
# Extract Psiphon bundled config + embedded server entries from the public Shiro Khorshid APK.
# Git repos only ship .stub files; distributor values are embedded in release builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLED="${ROOT}/AzadiTunnel/Resources/Bundled"
CACHE="${ROOT}/Tooling/psiphon/build/shiro-apk"
RELEASE_TAG="${SHIRO_APK_RELEASE:-v2026.05.24-a3b91cf}"
APK_NAME="${SHIRO_APK_NAME:-ShirOKhorshid-2026.05.24.apk}"
APK_URL="https://github.com/shirokhorshid/shirokhorshid-android/releases/download/${RELEASE_TAG}/${APK_NAME}"

mkdir -p "$CACHE" "$BUNDLED"
APK_PATH="${CACHE}/${APK_NAME}"

if [[ ! -f "$APK_PATH" ]]; then
  echo "Downloading ${APK_URL} ..."
  curl -fsSL -o "$APK_PATH" "$APK_URL"
fi

export APK_PATH BUNDLED ROOT="${ROOT}"
python3 <<'PY'
import base64
import json
import os
import re
import zipfile
from pathlib import Path

apk = Path(os.environ["APK_PATH"])
bundled = Path(os.environ["BUNDLED"])
dex = zipfile.ZipFile(apk).read("classes.dex")

propagation_candidates = []
sponsor_candidates = []
for token in (b"07D1ACD69B3AC7A2", b"EE0B7486ACAE75AA"):
    if token in dex:
        (propagation_candidates if token.startswith(b"07") else sponsor_candidates).append(
            token.decode()
        )

# Fallback: any 16-char hex near PROPAGATION_CHANNEL_ID / SPONSOR_ID string table markers
hex16 = sorted(set(m.decode() for m in re.findall(rb"[0-9A-F]{16}", dex)))
if not propagation_candidates:
    propagation_candidates = [h for h in hex16 if h.startswith("07D1")]
if not sponsor_candidates:
    sponsor_candidates = [h for h in hex16 if h.startswith("EE0B")]

if not propagation_candidates or not sponsor_candidates:
    raise SystemExit(
        "Could not find PropagationChannelId / SponsorId in APK dex. "
        "Update extract-shiro-bundled-from-apk.sh or set SHIRO_APK_* env vars."
    )

propagation_id = propagation_candidates[0]
sponsor_id = sponsor_candidates[0]

hex_entries = re.findall(rb"3020302030203020[0-9a-fA-F]{400,}", dex)
seen: set[bytes] = set()
lines: list[str] = []
for raw_hex in hex_entries:
    if raw_hex in seen:
        continue
    seen.add(raw_hex)
    # Psiphon expects hex-encoded lines (see tunnel-core README server-entry.dat).
    hex_line = raw_hex.decode("ascii")
    if hex_line.startswith("3020302030203020"):
        lines.append(hex_line)

if not lines:
    raise SystemExit("No embedded server entries found in APK dex.")

compartment_id = ""
# Prefer known Shiro build marker near CONDUIT / compartment strings in dex.
known_marker = b"DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU"
if known_marker in dex:
    compartment_id = known_marker.decode("ascii")
else:
    for raw in re.findall(rb"[A-Za-z0-9+/]{43}=?", dex):
        try:
            padded = raw if raw.endswith(b"=") else raw + b"=="
            if len(base64.b64decode(padded)) != 32:
                continue
            text = raw.decode("ascii")
            if not text[0].isalnum():
                continue
            compartment_id = text.rstrip("=")
            break
        except Exception:
            pass

config = {
    "ClientVersion": "1",
    "PropagationChannelId": propagation_id,
    "SponsorId": sponsor_id,
}
if compartment_id:
    config["ConduitPersonalCompartmentID"] = compartment_id

config_path = bundled / "psiphon-config.json"
entries_path = bundled / "psiphon-embedded-server-entries.txt"
local_config_path = bundled / "psiphon-config.local.json"
remote_urls_path = Path(os.environ["ROOT"]) / "Tooling/psiphon/remote-server-list-urls.json"
config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
entries_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

# Distributor keys embedded in release APK dex (Shiro EmbeddedValues parity).
known_entry_sig = b"sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA="
entry_sig = known_entry_sig.decode() if known_entry_sig in dex else ""
if not entry_sig:
    for raw in re.findall(rb"[A-Za-z0-9+/]{43}=", dex):
        text = raw.decode()
        if text.startswith("sHu") or text.startswith("MIIC"):
            entry_sig = text
            break

remote_list_sig = ""
for candidate in (
    b"szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
    b"HBkdgxkioPJ47j8nXxydXPBKXcnCruQ4ICEmrsECAQM=",
):
    if candidate in dex:
        remote_list_sig = candidate.decode()
        break

exchange_key = ""
for candidate in (b"HBkdgxkioPJ47j8nXxydXPBKXcnCruQ4ICEmrsECAQM=",):
    if candidate in dex and candidate.decode() != remote_list_sig:
        exchange_key = candidate.decode()

s3_roots = [
    "https://s3.amazonaws.com/psiphon/web/yttm-zeis-pjjd/",
    "https://s3.amazonaws.com/psiphon/web/h861-azv0-6p98/",
    "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/",
]
remote_urls = []
for root in s3_roots:
    for suffix in ("server_list_compressed", "server_list"):
        url = root + suffix
        remote_urls.append(
            {
                "URL": base64.b64encode(url.encode()).decode(),
                "OnlyAfterAttempts": 0,
                "SkipVerify": False,
            }
        )
obf_roots = []
for root in s3_roots:
    url = root + "osl"
    obf_roots.append(
        {
            "URL": base64.b64encode(url.encode()).decode(),
            "OnlyAfterAttempts": 0,
            "SkipVerify": False,
        }
    )

local_config = {"ClientVersion": "453"}
if entry_sig:
    local_config["ServerEntrySignaturePublicKey"] = entry_sig
if exchange_key:
    local_config["ExchangeObfuscationKey"] = exchange_key
if remote_urls:
    local_config["RemoteServerListURLs"] = remote_urls
if remote_list_sig:
    local_config["RemoteServerListSignaturePublicKey"] = remote_list_sig
if obf_roots:
    local_config["ObfuscatedServerListRootURLs"] = obf_roots

if local_config.get("ServerEntrySignaturePublicKey"):
    local_config_path.write_text(json.dumps(local_config, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {local_config_path}")
    print(f"  ServerEntrySignaturePublicKey={'yes' if entry_sig else 'no'}")
    print(f"  RemoteServerListURLs={len(remote_urls)}")
    print(f"  RemoteServerListSignaturePublicKey={'yes' if remote_list_sig else 'no'}")
else:
    print("WARN: Could not extract ServerEntrySignaturePublicKey — run merge-shiro-distributor-keys.sh with CI secrets")

remote_urls_path.parent.mkdir(parents=True, exist_ok=True)
remote_urls_path.write_text(json.dumps(remote_urls, indent=2) + "\n", encoding="utf-8")
print(f"Wrote {remote_urls_path} ({len(remote_urls)} URLs)")

print(f"Wrote {config_path}")
print(f"  PropagationChannelId={propagation_id}")
print(f"  SponsorId={sponsor_id}")
if compartment_id:
    print(f"  ConduitPersonalCompartmentID={compartment_id}")
print(f"Wrote {entries_path} ({len(lines)} entries, {entries_path.stat().st_size} bytes)")

geo_name = "assets/GeoLite2-Country.mmdb"
with zipfile.ZipFile(apk) as zf:
    if geo_name in zf.namelist():
        geo_dest = bundled / "GeoLite2-Country.mmdb"
        geo_dest.write_bytes(zf.read(geo_name))
        print(f"Wrote {geo_dest} ({geo_dest.stat().st_size} bytes)")
    else:
        print("WARN: GeoLite2-Country.mmdb not found in APK — Conduit GeoIP disabled until present")
PY

echo "Done. Rebuild AzadiTunnel and tap Connect (or Settings → Retry bundled install)."
