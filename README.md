# AzadiTunnel

Open-source iOS VPN client licensed under **GNU GPLv3**. It uses **[psiphon-tunnel-core](https://github.com/shirokhorshid/psiphon-tunnel-core)** (also GPLv3) for the packet-tunnel VPN stack.

AzadiTunnel is **not** developed, endorsed, or affiliated with Psiphon Inc. Psiphon® is a registered trademark of Psiphon Inc.

Connect flow follows [Shiro Khorshid / Psiphon iOS samples](https://github.com/shirokhorshid/psiphon-tunnel-core): bundled `psiphon-config.json` + `psiphon-embedded-server-entries.txt`, copied to the App Group on first launch. Tap **Connect** — no JSON import required.

## License (GPLv3) and source code

| Document | Purpose |
|----------|---------|
| [LICENSE](LICENSE) | Full GNU General Public License v3 text |
| [COPYRIGHT.md](COPYRIGHT.md) | Copyright and source-offer summary |
| [LEGAL_NOTES.md](LEGAL_NOTES.md) | Distribution, App Store, and compliance notes |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Psiphon, tunnel-core, tun2socks, Apple SDKs |

**Corresponding source** for distributed binaries:

1. This repository: `https://github.com/polamgh/AzadiTunnel` (tag or commit matching the build you ship).
2. **psiphon-tunnel-core** at the pinned revision in [`Tooling/psiphon/PSIPHON_PINNED_COMMIT`](Tooling/psiphon/PSIPHON_PINNED_COMMIT) — build the iOS framework with [`Tooling/psiphon/build-ios-xcframework.sh`](Tooling/psiphon/build-ios-xcframework.sh) and link `Vendor/PsiphonTunnelCore.xcframework` to the packet-tunnel target only.

**Private credentials** (distributor keys, remote server list signatures, local overrides) are **not** in this public tree. Use gitignored `*.local.json` / `*.local.txt` on your machine — see [docs/BUNDLED_PSIPHON_CONFIG.md](docs/BUNDLED_PSIPHON_CONFIG.md).

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
