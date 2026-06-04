# App Store & Open Source Readiness

## GPLv3

- `LICENSE` (GPLv3) is included at repository root.
- `LEGAL_NOTES.md` and `THIRD_PARTY_NOTICES.md` describe obligations and attributions.

## Source availability

Publish matching source for each distributed build (app + extension + build scripts). Include instructions to reproduce `Vendor/PsiphonTunnelCore.xcframework`.

## No private hardcoded servers

- Production config is user-imported only.
- `Tests/Fixtures/local-*.json` is gitignored.

## Privacy policy (draft)

AzadiTunnel imports Psiphon configuration you provide. Operational logs stay on-device in the App Group unless you export them. The tunnel may connect to servers defined in your config. See Psiphon project privacy practices for tunnel-core telemetry fields you enable in JSON config.

## App Store review notes (draft)

See **`Docs/APP_REVIEW_NOTES.md`** for the full App Review Notes draft to paste into App Store Connect.

See **`Docs/APP_STORE_CONNECT_IAP.md`** for manual In-App Purchase setup steps and suggested CAD price tiers.

## Version alignment

- App and extension use `MARKETING_VERSION` 1.0 and `CURRENT_PROJECT_VERSION` 1 in Xcode targets (keep in sync when releasing).

## Real device test

Run `Scripts/run-real-device-regression.sh` before release; do not ship without a passing log on the target device.
