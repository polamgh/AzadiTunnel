# Legal Notes — AzadiTunnel

**Disclaimer:** This app is not developed, endorsed, sponsored, or affiliated with Psiphon Inc.

AzadiTunnel is an open-source VPN client intended to be **GPLv3-compatible** because it links against [psiphon-tunnel-core](https://github.com/shirokhorshid/psiphon-tunnel-core) (GNU General Public License v3).

## What GPLv3 means for this app

- **Copyleft:** If you distribute AzadiTunnel binaries (App Store, TestFlight, direct IPA), recipients generally have the right to obtain the **complete corresponding source** for the version they received, including your app-specific changes and build scripts needed to reproduce the binary.
- **Same license family:** Application code that is combined with GPLv3 tunnel-core in-process (app + Network Extension loading the same framework) should remain under terms **compatible with GPLv3**. Do not add proprietary libraries that forbid source redistribution if they are linked into the same binary without a separate legal review.
- **No hiding secrets in source:** User-supplied Psiphon JSON may contain credentials or server entries; those belong in user storage (App Group), not in the public repository. The **source code** of the app itself must still be published; only user data stays private.

## Source code publishing requirement

When you distribute AzadiTunnel:

1. Publish source (e.g. GitHub) matching each released build tag.
2. Include `LICENSE`, `THIRD_PARTY_NOTICES.md`, and instructions to rebuild `Vendor/PsiphonTunnelCore.xcframework` via `Tooling/psiphon/build-ios-xcframework.sh`.
3. Retain copyright and license notices in shipped binaries where required.

## App Store risks

- **GPL compliance:** Apple’s distribution is still distribution under GPLv3; provide a clear **source offer** (link in app metadata / support page).
- **Network Extension:** Requires Apple approval for Personal VPN / Packet Tunnel entitlements; justify circumvention/privacy use in review notes.
- **Export / sanctions:** VPN apps may face regional restrictions; you are responsible for compliance with applicable law.
- **OCSP / system leaks:** Psiphon’s iOS documentation warns that some TLS revocation checks may bypass app proxy settings (see `docs/PSIPHON_TUNNEL_CORE_RESEARCH.md`).

## Third-party notice requirements

- Ship or display `THIRD_PARTY_NOTICES.md` (in-app Settings → Legal, and in repository).
- Credit Psiphon Inc. / psiphon-tunnel-core and other vendored components as notices are filled in.

## What must not be hidden or kept private

- AzadiTunnel application and extension **source code** (for distributed builds).
- Build scripts and pinned tunnel-core revision.
- GPLv3 license text and modification notices.

**May remain private (user data):**

- Imported Psiphon configuration JSON (`Tests/Fixtures/local-*.json` is gitignored for developer machines).
- Operational logs that could contain sensitive paths (never log raw config secrets).

## No proprietary tunnel core

Do not substitute a closed-source tunnel implementation in the same linked binary without resolving GPLv3 combination issues. AzadiTunnel’s design uses user-imported config only—no hardcoded private servers in source.
