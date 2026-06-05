# Xcode Cloud — AzadiTunnel

This repo includes `ci_scripts/` so Xcode Cloud can build **PsiphonTunnelCore** and run the full UI test suite.

## Prerequisites (one-time in Apple Developer)

1. Open **AzadiTunnel.xcodeproj** in Xcode on your Mac.
2. **Product → Xcode Cloud → Create Workflow** (or App Store Connect → Xcode Cloud).
3. Connect the GitHub repo: `polamgh/AzadiTunnel`, branch `main`.
4. Enable **Xcode Cloud** for team `4QF88W2GKT` and grant access to the repository.
5. In the workflow, set **Environment → macOS** and **Xcode** to the same major version you use locally.

## Recommended workflows

### 1. Build + Analyze (every push)

| Setting | Value |
|---------|--------|
| Start condition | Push to `main`, Pull Requests |
| Action | **Build** or **Analyze** |
| Scheme | `AzadiTunnel` |
| Platform | iOS |

Runs `ci_post_clone.sh` (Go + Psiphon framework) then builds the app and packet-tunnel extension.

### 2. Simulator — app smoke tests (every push)

| Setting | Value |
|---------|--------|
| Action | **Test** |
| Scheme | `AzadiTunnelUITests` |
| Destination | **iPhone 15** (or latest) **Simulator** |
| Test plan configuration | **Simulator App Smoke** |

Runs bootstrap, legal/disclaimer, StoreKit local products. VPN connect tests are **skipped** on Simulator (Network Extension limitation).

### 3. Device — full VPN regression (release / nightly)

| Setting | Value |
|---------|--------|
| Action | **Test** |
| Scheme | `AzadiTunnelUITests` |
| Destination | **Connected device** (register iPhone in Xcode Cloud → Devices) |
| Test plan configuration | **Device Full Regression** |

Runs all UI tests including `testHomeConnectRealInternetAndTraffic` and `testAllFeaturesAfterVPNConnect`.

**Device checklist:** unlocked, Developer Mode, **Settings → Developer → Enable UI Automation**, VPN profile already allowed once.

## CI scripts

| Script | When | Purpose |
|--------|------|---------|
| `ci_scripts/ci_post_clone.sh` | After git clone | Install Go **1.26.3** (must match tunnel-core build script), `verify-protocol-parity.py`, build `Vendor/PsiphonTunnelCore.xcframework` |
| `ci_scripts/ci_pre_xcodebuild.sh` | Before `xcodebuild` | Verify framework + bundled Psiphon resources |

Scripts must be **committed to git** with the executable bit (`git update-index --chmod=+x ci_scripts/*.sh`). Xcode Cloud only runs scripts that exist in the cloned repository beside `AzadiTunnel.xcodeproj`.

`Vendor/PsiphonTunnelCore.xcframework` is **gitignored** (~200 MB). CI must build it on every Archive/Test workflow; do not rely on a local-only `Vendor/` folder.

## Test plan

`AzadiTunnel.xcodeproj/xcshareddata/xctestplans/AzadiTunnel.xctestplan` documents two configurations (**Simulator App Smoke** / **Device Full Regression**). The shared schemes pass `-UITestMode` and `XCTUIApplicationLaunchDefaultTimeout=120` via the scheme Test action.

On **Simulator**, VPN connect tests auto-**skip** (`XCTSkip`). On a **connected device**, all tests run including real tunnel connect.

## Secrets

Do **not** add `psiphon-config.local.json`, certificates, or API keys as Xcode Cloud environment variables unless you intend to run **device VPN** tests in the cloud. Public bundled stubs are enough for build + Simulator smoke.

## Local parity

```bash
bash ci_scripts/ci_post_clone.sh
bash ci_scripts/ci_pre_xcodebuild.sh
xcodebuild test \
  -project AzadiTunnel.xcodeproj \
  -scheme AzadiTunnelUITests \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
  -parallel-testing-enabled NO
```

Full device regression: [TESTING.md](../TESTING.md) and `Scripts/run-real-device-regression.sh`.
