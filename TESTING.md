# Testing — AzadiTunnel

## Phase 7 discipline

Every change should record:

1. What changed  
2. Matching Android feature (see `docs/SHIRO_KHORSHID_FEATURE_AUDIT.md`)  
3. Files touched  
4. `xcodebuild build` result  
5. Real-device UI test result (`platform=iOS,id=00008120-000170D03E10201E`)

Do not report “done” unless build succeeds, UI test passes, and `generate_204` returns HTTP 204 through the tunnel.

## Build

```bash
xcodebuild build \
  -project AzadiTunnel.xcodeproj \
  -scheme AzadiTunnel \
  -destination 'generic/platform=iOS'
```

## Protocol parity (Shiro Khorshid)

Static check (protocol names vs Android APK):

```bash
python3 Scripts/verify-protocol-parity.py
```

On a connected iPhone, exercise Auto / Direct / CDN / Conduit (Beast off) and verify `UITEST_SETTINGS` / `PSIPHON_PROTOCOL_LIMIT` in logs:

```bash
chmod +x Scripts/protocol-connect-regression.sh
Scripts/protocol-connect-regression.sh [device-id]
```

`devicectl` launch must pass app flags after `--` (otherwise `-UITestMode` is parsed as a devicectl option).

Manual test: Settings → Transport → pick **Direct**, **CDN fronting**, or **Conduit**, turn **Beast mode off**, Disconnect → Connect. In Logs search `PSIPHON_PROTOCOL_LIMIT` and `PSIPHON_TUNNEL_PROTOCOL`.

**Conduit** (Shiro parity): uses all 11 `INPROXY-WEBRTC-*` protocols plus `InproxyClientPersonalCompartmentID` from bundled Shiro APK (`ConduitPersonalCompartmentID` in `psiphon-config.json`). Optional **Conduit mode** picker when Transport = Conduit (auto / Shiro community / public). Conduit can take **3+ minutes** to find an in-proxy peer; check logs for `CONDUIT_CONFIG`, `PSIPHON_INPROXY`, `PSIPHON_CONNECTED_PROTOCOL`. If community pairing fails, try **Public** conduit mode.

## Real device regression (Ali’s iPhone)

```bash
Scripts/run-real-device-regression.sh
```

Equivalent:

```bash
xcodebuild test \
  -project AzadiTunnel.xcodeproj \
  -scheme AzadiTunnelUITests \
  -destination 'platform=iOS,id=00008120-000170D03E10201E'
```

## Bundled Psiphon data

Regenerate from Shiro Khorshid release APK (git stubs are empty):

```bash
./Tooling/psiphon/extract-shiro-bundled-from-apk.sh
```

Optional gitignored overrides: `psiphon-config.local.json`, `psiphon-embedded-server-entries.local.txt`.

**Conduit** requires distributor keys in `psiphon-config.local.json` (`ServerEntrySignaturePublicKey`); see `docs/BUNDLED_PSIPHON_CONFIG.md` and `./Tooling/psiphon/merge-shiro-distributor-keys.sh`.

## UI test prerequisites

1. Bundled config installed (script above or `.local` files).  
2. `Vendor/PsiphonTunnelCore.xcframework` is **linked** by **AzadiTunnelPacketTunnel** and **embedded** in the main **AzadiTunnel** app only (not inside the `.appex` — App Store rejects `PlugIns/*.appex/Frameworks`).  
3. Device unlocked, **Developer Mode** on, **Settings → Developer → Enable UI Automation** on (required after iOS updates/reboot).  
4. USB connection recommended; unlock screen before `xcodebuild test`.  
5. VPN permission allowed; accept VPN disclosure sheet on first connect in test.

Use the regression wrapper (build-for-testing + patched xctestrun + test-without-building):

```bash
Scripts/run-real-device-regression.sh 00008120-000170D03E10201E
```

## Accessibility identifiers

| ID | Screen |
|----|--------|
| `connectButton` | Home |
| `statusLabel` | Home |
| `durationLabel` | Home |
| `downloadSpeedLabel` / `uploadSpeedLabel` | Home |
| `totalDownloadLabel` / `totalUploadLabel` | Home |
| `publicIPLabel` | Home |
| `logsTab` / `settingsTab` | Tab bar |

## What the UI test does

`AzadiTunnelConnectRegressionTests`:

1. Launch app  
2. Tap **Connect** (accept VPN + disclosure if shown)  
3. Wait for **Connected**  
4. Assert shared traffic counters increase  
5. `GET https://www.google.com/generate_204` → **204**  
6. Disconnect  

## Troubleshooting

- **Exit 74 (IDE disconnection):** Schemes use PosixSpawn (no LLDB) for Test action; run `Scripts/run-real-device-regression.sh` with device unlocked.  
- **dyld PsiphonTunnel in main app:** Psiphon framework must be extension-only.  
- **CONFIG_VALIDATE_FAILED:** Re-run APK extract script and Retry bundled install.
