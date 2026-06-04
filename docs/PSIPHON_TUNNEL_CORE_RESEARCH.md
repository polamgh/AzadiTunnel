# Psiphon Tunnel Core — Research Notes (AzadiTunnel)

**Repository:** https://github.com/shirokhorshid/psiphon-tunnel-core  
**Pinned reference (shallow clone):** `1123a61926ac3a69bfab4e09d31e4638ec91a1bc` (tag `2026.05.24`)

## Language & toolchain

| Component | Details |
|-----------|---------|
| Core | Go 1.26+ (`go.mod` / build script requires **Go 1.26.3**) |
| Mobile bindings | `gomobile bind` (vendored under `MobileLibrary/go-mobile`) |
| iOS umbrella | Objective-C framework **PsiphonTunnel** (Xcode project under `MobileLibrary/iOS/PsiphonTunnel/`) |
| App integration | Swift/Obj-C; sample apps use bridging headers |

Build uses **GOPATH mode** (`GO111MODULE=off`), symlinks repo into `GOPATH/src/github.com/Psiphon-Labs/psiphon-tunnel-core`.

## Build system

- **iOS framework:** `MobileLibrary/iOS/build-psiphon-framework.sh`
  - Produces `PsiphonTunnel.xcframework` (device `arm64`, simulator `x86_64`/`arm64`, Mac Catalyst optional).
  - Steps: `gomobile bind` → `Psi.xcframework` → Xcode build `PsiphonTunnel.framework` per platform → `xcodebuild -create-xcframework`.
- **Requirements:** Xcode 11+, CocoaPods 1.10+ (samples only), Bitcode **off**, `STRIP_BITCODE_FROM_COPIED_FILES=NO`.
- AzadiTunnel wraps output as `Vendor/PsiphonTunnelCore.xcframework` via `Tooling/psiphon/build-ios-xcframework.sh`.

## iOS support

- Official iOS library path: `MobileLibrary/iOS/`
- Documentation: `MobileLibrary/iOS/USAGE.md`, `MobileLibrary/iOS/README.md`
- API header: `MobileLibrary/iOS/PsiphonTunnel/PsiphonTunnel/PsiphonTunnel.h`
- Sample apps: `TunneledWebView`, `TunneledWebRequest` (local SOCKS/HTTP proxy, not full system VPN in samples)

**Packet tunnel on iOS:** Psiphon mobile library exposes **local port-forward proxies** (SOCKS + HTTP). System-wide VPN is implemented by the host app using **Network Extension** + forwarding `NEPacketTunnelFlow` to the local proxy (e.g. tun2socks for SOCKS). Tunnel-core also has Go `tun` package (`GetPacketTunnelMTU`) for packet mode in other platforms.

## Config format

JSON object returned by app delegate `getPsiphonConfig`. Minimum fields (from stubs/docs):

```json
{
  "ClientVersion": "1",
  "PropagationChannelId": "...",
  "SponsorId": "...",
  "RemoteServerListSignaturePublicKey": "...",
  "RemoteServerListURLs": ["https://..."]
}
```

Optional / server-supplied (do not set unless needed): `TargetServerEntry`, `DataStoreDirectory`, timeouts, `UpstreamProxyUrl`, etc.  
**Do not set** `LocalHttpProxyPort` / `LocalSocksProxyPort` in client config (library assigns ports).

See `psiphon/config.go` and `PsiphonTunnel.h` delegate documentation.

## Proxies exposed

| Type | When | API |
|------|------|-----|
| **SOCKS5** | After tunnel connects | `onListeningSocksProxyPort`, `getLocalSocksProxyPort` |
| **HTTP/HTTPS proxy** | After tunnel connects | `onListeningHttpProxyPort`, `getLocalHttpProxyPort` |

Default example ports in README: SOCKS **1080**, HTTP **8080** (dynamic if not fixed).

Routing modes in core (README): **port forward** (localhost proxies) and **packet tunnel** (TUN). iOS embedding uses port-forward + host VPN extension.

## Start / stop API (iOS)

Objective-C `PsiphonTunnel`:

- `+newPsiphonTunnel:(id<TunneledAppDelegate>)` — singleton; stops existing instance if recreated
- `-start:(BOOL)ifNeeded` — begin connection; callbacks: `onConnecting`, `onConnected`, `onListeningSocksProxyPort`, etc.
- `-stop` — tear down tunnel
- `-getConnectionState` — `PsiphonConnectionState` enum
- Go layer (`MobileLibrary/psi/psi.go`): `Start()`, `Stop()` for bind layer

Swift wrapper in AzadiTunnel: `PsiphonTunnelAdapter` bridges to this API when framework is present.

## License obligations

- **License:** GNU General Public License **v3** (`LICENSE` in repo).
- Combining Psiphon tunnel-core with AzadiTunnel creates a **GPLv3-covered combined work** if linked in-process (framework in app + extension).
- **Requirements (summary):**
  - Provide corresponding source for the app (including your changes) to users who receive the binary.
  - License AzadiTunnel under GPLv3-compatible terms; document third-party components.
  - GPLv3 anti-tivoization / patent / no additional restrictions on users’ rights.
- **App Store:** Allowed under GPLv3, but you must honor source-offer requirements; Apple’s terms and export rules still apply; VPN apps need Network Extension entitlements and review justification.
- **Do not** ship proprietary closed-source core linked with GPLv3 tunnel-core without a separate legal analysis (generally **not** compatible for in-process linking).

## AzadiTunnel integration plan

1. User imports JSON config (no embedded private servers).
2. Packet Tunnel extension loads config from App Group, starts Psiphon, waits for SOCKS port.
3. `tun2socks` (or documented HTTP CONNECT path) forwards `packetFlow` to `127.0.0.1:<socksPort>`.
4. UI tests on device with `Tests/Fixtures/local-psiphon-config.json` (gitignored).

## AzadiTunnel build notes (Xcode 26)

Upstream `NetworkInterface.m` may fail with `netinet6/in6.h` private header errors. `Tooling/psiphon/build-ios-xcframework.sh` applies a small patch (`netinet/in.h`) before building.
