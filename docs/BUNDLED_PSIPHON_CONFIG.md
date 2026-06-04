# Bundled Psiphon config (Shiro Khorshid / Psiphon iOS pattern)

Reference: [psiphon-tunnel-core iOS samples](https://github.com/shirokhorshid/psiphon-tunnel-core/tree/master/MobileLibrary/iOS/SampleApps/TunneledWebRequest)

## Resources in app bundle

| File | Role |
|------|------|
| `AzadiTunnel/Resources/Bundled/psiphon-config.json` | Sponsor/propagation/remote list JSON (`getPsiphonConfig`) |
| `AzadiTunnel/Resources/Bundled/psiphon-embedded-server-entries.txt` | Bootstrap server entries (`getEmbeddedServerEntries`) |

Optional overrides (gitignored for real devices):

- `psiphon-config.local.json` — merged **on top of** `psiphon-config.json` at bootstrap (distributor keys)
- `psiphon-embedded-server-entries.local.txt`
- `psiphon-embedded-server-entries.remote-supplement.txt` — optional lines fetched from `RemoteServerListURLs` (see below)

Copy `psiphon-config.local.json.example` → `psiphon-config.local.json` and fill from Shiro CI secrets (never commit).

### Remote server list (Shiro parity)

Shiro always passes `RemoteServerListURLs` + signature keys in tunnel config; tunnel-core **downloads on first connect** into the datastore (parallel with establishment). AzadiTunnel logs `REMOTE_SERVER_LIST_CONFIG` at bootstrap and `REMOTE_SERVER_LIST_FETCH phase=downloaded` when the signed list is stored.

To **pre-merge** fetched entry lines into the bundled bootstrap file (offline, before install):

```bash
./Tooling/psiphon/apply-remote-server-list-json.sh   # sets URLs in local.json
PSIPHON_FETCH_REMOTE_ENTRIES=1 ./Tooling/psiphon/apply-remote-server-list-json.sh   # also writes remote-supplement.txt (needs Go + tunnel-core checkout)
# or: ./Tooling/psiphon/fetch-remote-server-entries.sh
```

Then rebuild and **Settings → Advanced → Retry bundled install**.

## First launch

`PsiphonBootstrap` copies bundle resources into the App Group (`psiphon-config.json`, `psiphon-embedded-server-entries.txt`). The packet tunnel extension reads from App Group only — never from Swift string literals.

## Server entries

Each **server entry** fully describes one Psiphon server (see tunnel-core README). After connect, the client may discover more entries remotely.

## Shiro Khorshid values (not in git)

Public repos (`shirokhorshid-android`, `psiphon-tunnel-core`) only contain `.stub` files.
Live `PropagationChannelId`, `SponsorId`, and embedded server entries ship inside the
release APK. Regenerate bundled iOS resources:

```bash
./Tooling/psiphon/extract-shiro-bundled-from-apk.sh
```

Then rebuild the app. Do not put secrets in `.swift` files.

## Distributor setup (required for Conduit)

Public Shiro APKs and this repo’s bundled `psiphon-config.json` only ship
`PropagationChannelId`, `SponsorId`, and `ConduitPersonalCompartmentID`. They do **not**
include Psiphon distributor secrets (`ServerEntrySignaturePublicKey`, remote list URLs, etc.).
Those are injected when [shirokhorshid-android](https://github.com/shirokhorshid/shirokhorshid-android)
is built (Gradle `generateEmbeddedValues` / GitHub Actions secrets).

**Conduit / in-proxy dials fail without `ServerEntrySignaturePublicKey`** (`entry_sig_key=false` in logs).

### Option A — same env vars as Shiro CI

```bash
export PSIPHON_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY='…'
# optional but recommended:
export PSIPHON_SERVER_ENTRY_EXCHANGE_OBFUSCATION_KEY='…'
export PSIPHON_REMOTE_SERVER_LIST_URLS_JSON='["https://…"]'
export PSIPHON_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY='…'

./Tooling/psiphon/merge-shiro-distributor-keys.sh
```

This writes `AzadiTunnel/Resources/Bundled/psiphon-config.local.json` (gitignored). Rebuild, reinstall, or Settings → Advanced → Retry bundled install.

### Option B — from a local Shiro `EmbeddedValues.java`

After building Shiro Android with secrets:

```bash
./Tooling/psiphon/extract-keys-from-embedded-values-java.sh \
  /path/to/shiro-android/app/src/main/java/com/psiphon3/psiphonlibrary/EmbeddedValues.java
```

See `psiphon-config.local.json.example` for the JSON shape.

To refresh entries/compartment from a newer Shiro release APK only (no keys), set `SHIRO_APK_RELEASE` / `SHIRO_APK_NAME` and re-run `extract-shiro-bundled-from-apk.sh`.
