# AzadiTunnel

Open-source iOS VPN client (GPLv3) using [psiphon-tunnel-core](https://github.com/shirokhorshid/psiphon-tunnel-core). Connect flow matches [Shiro Khorshid / Psiphon iOS samples](https://github.com/shirokhorshid/psiphon-tunnel-core): bundled `psiphon-config.json` + `psiphon-embedded-server-entries.txt`, copied to App Group on first launch. Tap **Connect** — no JSON import required.

## Setup

1. Open `AzadiTunnel.xcodeproj` in Xcode.
2. Enable App Group `group.com.polamgh.ali.AzadiTunnel` and Packet Tunnel entitlements (app + extension).
3. `bash Tooling/psiphon/build-ios-xcframework.sh` — link `Vendor/PsiphonTunnelCore.xcframework` to **AzadiTunnelPacketTunnel** only (not the main app).
4. Put real Psiphon values in bundled resources — see [docs/BUNDLED_PSIPHON_CONFIG.md](docs/BUNDLED_PSIPHON_CONFIG.md). Use gitignored `*.local.json` / `*.local.txt` overrides on your Mac.

Optional: Settings → Advanced → import custom JSON.

## Build

```bash
xcodebuild build -project AzadiTunnel.xcodeproj -scheme AzadiTunnel -destination 'generic/platform=iOS'
```

## Device regression

```bash
Scripts/run-real-device-regression.sh
```

See [TESTING.md](TESTING.md), [LEGAL_NOTES.md](LEGAL_NOTES.md), [docs/PSIPHON_TUNNEL_CORE_RESEARCH.md](docs/PSIPHON_TUNNEL_CORE_RESEARCH.md).
