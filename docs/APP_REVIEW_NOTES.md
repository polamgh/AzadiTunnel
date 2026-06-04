# App Review Notes — AzadiTunnel

Use this text when submitting to App Store Connect (Review Notes field) or TestFlight external testing.

## App summary

AzadiTunnel is a privacy-focused tunneling app for iOS. Users import their own Psiphon-compatible configuration (JSON). The app runs a Packet Tunnel network extension to route device traffic through the configured tunnel.

## In-app purchases (optional support only)

- In-app purchases are **optional support purchases** (one-time tips and optional supporter subscriptions).
- **Core VPN / tunnel functionality remains fully available without any purchase.**
- Purchases do **not** unlock, guarantee, or improve speed, availability, anonymity, or access to any specific service.
- No preset paid servers or premium server tiers are sold in this build.
- Product IDs:
  - `azaditunnel.tip.small` (consumable tip)
  - `azaditunnel.tip.medium` (consumable tip)
  - `azaditunnel.tip.large` (consumable tip)
  - `azaditunnel.support.monthly` (auto-renewable subscription)
  - `azaditunnel.support.yearly` (auto-renewable subscription)

## Network Extension

- Entitlement: `packet-tunnel-provider`
- The extension starts only when the user taps Connect and has accepted the in-app connection disclaimer.
- Users supply their own tunnel configuration; the app does not ship production server credentials.

## Legal and user responsibility

- Before the first connection, users must accept a disclaimer covering lawful use, service terms, and that the app does not guarantee circumvention or anonymity.
- Legal & Open Source and Privacy Notice screens are available in Settings → About.
- GPLv3 applies to portions of the project; third-party notices are bundled in-app.
- **Users are responsible for complying with applicable laws and the terms of services they access.**

## Privacy

- Diagnostics and logs stay on-device unless the user exports a debug report.
- Debug export redacts secrets (keys, tokens, raw configs with credentials).
- Privacy manifest: `PrivacyInfo.xcprivacy` (UserDefaults API reason CA92.1).

## Test instructions

No special reviewer login is required.

1. Launch the app and complete onboarding (or skip if already completed).
2. Open **Settings → About → Legal & Open Source** to verify license notices load.
3. Open **Settings → About → Support AzadiTunnel** to view optional IAP products (requires products configured in App Store Connect for sandbox/production; local StoreKit testing works in Xcode with `Configuration.storekit`).
4. To test tunnel connect without a custom config: the bundled bootstrap config may be used in development builds; for review, import a valid Psiphon JSON via Settings if needed.
5. Tap **Connect** on the VPN tab; accept the connection disclaimer on first use.
6. Verify VPN permission prompt appears once; allow VPN configuration.
7. **Restore Purchases** on the Support screen should complete without blocking VPN.

## Support contact

- Developer: Debugsy Inc.
- Email: alighanavati@debugsy.com
- Website: https://debugsy.com

## Notes for VPN / circumvention category

- Explain that users bring their own configuration and the app is a client/runtime for user-supplied Psiphon settings.
- Source availability for GPLv3 components should be linked in the App Store description or support URL.
