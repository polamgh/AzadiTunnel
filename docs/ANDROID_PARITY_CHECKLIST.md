# Android parity checklist (AzadiTunnel)

Tracked against [SHIRO_KHORSHID_FEATURE_AUDIT.md](SHIRO_KHORSHID_FEATURE_AUDIT.md).

## P0

- [x] Home connect/disconnect (`connectButton`)
- [x] Status label + duration
- [x] Download/upload speed + total counters
- [x] Bundled config bootstrap (no import required)
- [x] Logs: live, copy, clear
- [x] Error banners (no config, Psiphon failed, internet test)
- [x] Disclaimer + GPL + privacy screens
- [ ] Region reconnect on change (settings persist; reconnect on next connect — manual)

## P1

- [x] Statistics tab with chart
- [x] Public IP fetch when connected
- [x] Upstream proxy settings (persist + compose into JSON)
- [x] Protocol + beast mode + disable timeouts (Shiro protocol names: `PsiphonProtocolSets.swift`, `Scripts/verify-protocol-parity.py`)
- [x] Auto-reconnect + connect on launch toggles
- [x] Language picker (stored; UI localization partial)
- [x] Link to iOS Settings for VPN / On Demand
- [x] VPN disclosure before first connect

## P2 / not on iOS

- [ ] Per-app split tunnel (documented as unsupported)
- [ ] NFC Bump, APK upgrade, launcher disguises
