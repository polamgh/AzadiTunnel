# Shir o Khorshid Android → AzadiTunnel iOS — Feature Audit

**Audit date:** 2026-06-03  
**Android reference:** [shirokhorshid/shirokhorshid-android](https://github.com/shirokhorshid/shirokhorshid-android) (`master`)  
**Tunnel core reference:** [shirokhorshid/psiphon-tunnel-core](https://github.com/shirokhorshid/psiphon-tunnel-core)  
**iOS app:** AzadiTunnel (SwiftUI + `NetworkExtension` packet tunnel)  
**Package:** `com.shirokhorshid.vpn` (fork of Psiphon Android)

This document satisfies **Phase 1** of the AzadiTunnel parity plan. Each feature lists Android location, behavior, proposed iOS design, priority, and Network Extension feasibility.

**Priority legend**

| Priority | Meaning |
|----------|---------|
| **P0** | Required for credible “tap Connect” VPN product |
| **P1** | Expected parity for power users / Shiro UX |
| **P2** | Nice-to-have, fork-specific, or platform-limited |

**NE feasibility**

| Label | Meaning |
|-------|---------|
| **Yes** | Implementable in app and/or `PacketTunnelProvider` |
| **Partial** | Some behavior only in host app, or iOS APIs differ |
| **No** | Not available on iOS consumer VPN APIs |

---

## Methodology

Inspected: `AndroidManifest.xml`, all `res/xml/*_preferences.xml`, `app/src/main/java/com/psiphon3/**`, `com/psiphon3/psiphonlibrary/**`, `EmbeddedValues.java.stub`, `app/build.gradle` / CI `generateEmbeddedValues`, release APK embedded values (see `Tooling/psiphon/extract-shiro-bundled-from-apk.sh`).

**Preference XML inventory**

| File | Purpose |
|------|---------|
| `app/src/main/res/xml/settings_preferences_screen.xml` | Settings tab hub |
| `app/src/main/res/xml/vpn_options_preferences.xml` | Split tunnel, Always-on VPN link |
| `app/src/main/res/xml/proxy_options_preferences.xml` | Upstream HTTP proxy |
| `app/src/main/res/xml/more_options_preferences.xml` | Language, notifications, advanced, CDN, conduit, LAN proxy, about |
| `app/src/main/res/xml/apduservice.xml` | NFC HCE (Psiphon Bump) |
| `app/src/main/res/xml/provider_paths.xml` | APK upgrade `FileProvider` |

---

## Psiphon-specific: config, sponsor, server entries

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Embedded client config** | `app/build.gradle` → `generateEmbeddedValues`; CI `.github/workflows/build.yml` | Build injects `EmbeddedValues.java` from secrets/env | Bundled `psiphon-config.json` + `PsiphonBootstrap` → App Group | **P0** | **Yes** |
| **Propagation channel ID** | `EmbeddedValues.PROPAGATION_CHANNEL_ID` (build-time, not user-editable) | Distribution channel for server lists / OSL | Field in bundled JSON (e.g. from release APK extract script) | **P0** | **Yes** |
| **Sponsor ID** | `EmbeddedValues.SPONSOR_ID`; `EmbeddedValues.initialize()` persists for Play vs sideload | Sponsor attribution on Psiphon network | `SponsorId` in JSON; optional App Group override | **P0** | **Yes** |
| **Embedded server entries** | `PSIPHON_EMBEDDED_SERVER_LIST` / `_FILE` → `EMBEDDED_SERVER_LIST[]` | Bootstrap server entry lines for first connect | `psiphon-embedded-server-entries.txt` → App Group; never log lines | **P0** | **Yes** |
| **Remote server list URLs** | `REMOTE_SERVER_LIST_URLS_JSON` in `EmbeddedValues` | Download/update server list when not fully embedded | Optional keys in advanced-import JSON only | **P1** | **Yes** (Psiphon core) |
| **Obfuscated server list roots** | `OBFUSCATED_SERVER_LIST_ROOT_URLS_JSON` | Obfuscated list discovery | Same as advanced JSON | **P1** | **Yes** |
| **List/signature public keys** | `REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY`, `SERVER_ENTRY_SIGNATURE_PUBLIC_KEY`, etc. | Verify downloaded lists/entries | Bundled or advanced import; never log keys | **P0** (if remote list used) | **Yes** |
| **Upgrade URLs / APK signature** | `UPGRADE_URLS_JSON`, `UPGRADE_SIGNATURE_PUBLIC_KEY` | Sideload APK update pipeline | App Store / TestFlight only | **P2** | **No** |
| **Feedback encryption / upload URLs** | `FEEDBACK_ENCRYPTION_PUBLIC_KEY`, `FEEDBACK_DIAGNOSTIC_INFO_UPLOAD_URLS_JSON` | `FeedbackWorker` diagnostic upload | Optional WKWebView + attach redacted logs | **P2** | **Partial** (app network) |
| **Conduit compartment ID** | `PSIPHON_CONDUIT_COMPARTMENT_ID` in CI | In-proxy compartment scoping | Psiphon JSON field if fork build enables in-proxy | **P1** | **Yes** |
| **Additional parameters** | `ADDITIONAL_PARAMETERS` string | Opaque extra Psiphon config | Merge into JSON blob in Advanced | **P1** | **Yes** |
| **Data root** | Psiphon library internal storage under app VPN process | Tunnel state, caches, downloads | App Group `psiphon-data/` (extension sandbox + shared container) | **P0** | **Yes** |
| **Ignore non-embedded entries** | `IGNORE_NON_EMBEDDED_SERVER_ENTRIES` | Restrict to embedded list only | Advanced toggle → config flag | **P2** | **Yes** |

**Git vs release:** Public git only ships `EmbeddedValues.java.stub` with empty IDs. Live values are in **release APK**; AzadiTunnel uses `Tooling/psiphon/extract-shiro-bundled-from-apk.sh`.

---

## Main shell & connect (Home)

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Four-tab shell** | `MainActivity.java`, `PageAdapter` → `HomeTabFragment`, `StatisticsTabFragment`, `OptionsTabFragment`, `LogsTabFragment` | Home / Stats / Settings / Logs | TabView: VPN, **Statistics** (missing), Settings, Logs | **P0** tabs: VPN+Logs; **P1**: Stats | **Yes** (UI) |
| **Connect / disconnect** | `MainActivity` toggle, `TunnelServiceInteractor`, `TunnelVpnService` | Primary VPN control; connecting / waiting for network | `DashboardView` + `VPNController` + `NETunnelProviderManager` | **P0** | **Yes** |
| **Connection status text** | `HomeTabFragment.updateStatusUI`, `TunnelState` | Human-readable state | `statusLabel` + enum: disconnected / connecting / connected / disconnecting / failed | **P0** | **Yes** |
| **Status illustration** | `HomeTabFragment` assets (lion/sun) | Visual mood for state | Phase 4: animated hero / gradient status ring | **P1** | **Yes** (UI) |
| **Duration timer** | `StatisticsTabFragment` / `DataTransferStats` (also home-adjacent) | Time since connect | `durationLabel` on home; timer from shared store | **P0** | **Partial** (extension writes timestamps) |
| **Public IP** | Psiphon notices / stats pipeline | Shows egress IP when known | `publicIPLabel`; IPC from extension notices | **P1** | **Partial** |
| **Live up/down speed** | `DataTransferStats.java` | Real-time throughput | `downloadSpeedLabel`, `uploadSpeedLabel` | **P0** | **Partial** |
| **Total up/down bytes** | `DataTransferStats` | Session totals | Home counters + Statistics tab | **P0** | **Partial** |
| **Last log line on home** | `HomeTabFragment` `lastlogline` | One-line diagnostic preview | Subtitle under status on dashboard | **P2** | **Yes** |
| **Open in browser** | `MainActivity.configureOpenBrowserButton()` | Opens sponsor/home URL when connected | Optional link; respect “no Psiphon branding” | **P2** | **Partial** |
| **Clear status logs** | `MainActivity.configureClearLogsButton()` → `LoggingContentProvider` | Clears status log slice | Logs tab Clear (exists) | **P1** | **Yes** |
| **Toolbar version** | `R.menu/activity_main.xml`, `CLIENT_VERSION` | Build version in action bar | About + dashboard footer `CFBundleShortVersionString` | **P1** | **Yes** |
| **VPN data collection disclosure** | `MainActivity.vpnServiceDataCollectionDisclosureCompletable()` | First-run consent before VPN | Onboarding sheet before first `connect` | **P1** | **N/A** |
| **Deep link → settings** | Manifest `shirokhorshid://settings`; code checks `psiphon` scheme (likely bug) | Jump to VPN/proxy/more settings | `onOpenURL` → Settings sections | **P2** | **N/A** |

**AzadiTunnel today:** VPN tab with power button, status, config banner, errors. Missing: duration, speeds, totals, public IP, region, polished UI.

---

## Region / egress

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Region list** | `RegionListPreference.java`, `settings_preferences_screen.xml` key `egressRegionPreference` | Pick Psiphon egress region or “Any”; restarts tunnel on change | Settings picker → update Psiphon JSON `EgressRegion`; restart tunnel | **P0** | **Yes** |
| **Region not available** | `INTENT_ACTION_SELECTED_REGION_NOT_AVAILABLE` | Notify user to pick another region | Alert + reset region in settings | **P1** | **Yes** |

---

## Split tunnel / per-app VPN

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Tunnel all apps** | `vpn_options_preferences.xml` `preferenceIncludeAllAppsInVpn` | Full-device VPN (default) | Default `NEPacketTunnelProvider` route all | **P1** | **Yes** |
| **Include only selected apps** | `preferenceIncludeAppsInVpn`, `InstalledAppsMultiSelectListPreference.java`, `VpnAppsUtils.java` | Whitelist packages | **Not supported on iOS** — no public API to enumerate/install pick apps for consumer VPN like Android | **P2** | **Partial** / document limitation |
| **Exclude selected apps** | `preferenceExcludeAppsFromVpn` | Blacklist packages | Same limitation; `NEVPNManager` has no per-app exclude list like Android | **P2** | **Partial** |
| **App picker UI** | `InstalledAppsRecyclerViewAdapter.java` | Lists installed apps | Show “Not available on iOS” + link to Apple VPN docs | **P2** | **No** (enumeration) |
| **Default exclusions footer** | Footer in `vpn_options_preferences.xml` | Explains system app exclusions | Static help text | **P2** | **N/A** |
| **Open system Always-on VPN** | `preferenceNavigateToVPNSetting`, manifest `SUPPORTS_ALWAYS_ON` | Deep link to Android VPN settings | Settings copy + explain **On Demand** / iOS Settings → VPN | **P1** | **Partial** |

**iOS note:** Per-app VPN on iOS is `NEAppProxyProvider` / MDM / managed profiles — not equivalent to Shiro’s install-time picker for sideload APK users.

---

## Upstream proxy

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Enable upstream proxy** | `proxy_options_preferences.xml`, `UpstreamProxySettings.java` | HTTP proxy before Psiphon | Settings → Connection → toggle + host/port | **P1** | **Yes** (Psiphon config) |
| **Use system proxy** | `useSystemProxySettingsPreference` | Device proxy settings | Toggle if core supports; else manual only | **P1** | **Partial** |
| **Custom host/port** | `useCustomProxySettingsHost/Port` | Manual proxy | Validated text fields | **P1** | **Yes** |
| **Proxy authentication** | user/pass/domain preferences | Authenticated upstream | Keychain + inject into config (log “proxy auth changed”, not secrets) | **P1** | **Yes** |
| **Upstream proxy errors** | `TunnelManager` notifications/dialogs | User alerted to fix proxy | Error banner + `PSIPHON_CONNECT_FAILED` | **P1** | **Yes** |

---

## Transport, CDN fronting, conduit (fork-specific)

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Protocol selection** | `more_options_preferences.xml` `protocolSelectionPreference` (auto/direct/cdn_fronting/conduit) | Limits tunnel protocols at connect | Advanced list → merge into Psiphon parameters | **P1** | **Yes** |
| **Beast mode** | `beastModePreference` (default on) | Aggressive multi-protocol attempts | Advanced toggle | **P1** | **Yes** |
| **CDN custom IPs** | `cdnFrontingCustomIpListPreference` | User edge IPs | Multiline editor in Advanced | **P2** | **Yes** |
| **CDN custom SNI** | `cdnFrontingCustomSniPreference` | Custom SNIs | Multiline editor | **P2** | **Yes** |
| **Conduit mode** | `conduitModePreference` (auto / shirokhorshid / public) | Fork in-proxy path | Same three modes if xcframework built with in-proxy | **P1** | **Yes** |
| **Conduit timeout** | `conduitTimeoutPreference` (120–600 s) | Auto-mode fallback timing | Picker when mode = auto | **P2** | **Yes** |
| **Reject censored-country conduits** | `rejectCensoredCountryProxiesPreference` | Blocks certain conduit peers | Advanced toggle | **P2** | **Yes** |
| **Disable timeouts** | `disableTimeoutsPreference` | Longer connection attempts | Advanced toggle | **P2** | **Yes** |

---

## DNS

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **User DNS settings UI** | *None* in preferences | DNS inside `VpnManager` / tun2socks / Psiphon stack | Optional `NEDNSSettings` in `PacketTunnelProvider.makeNetworkSettings` | **P2** | **Partial** — no Android UI to mirror |

---

## LAN proxy sharing

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Share proxy on LAN** | `shareProxyOnNetworkPreference` | Exposes local SOCKS/HTTP on LAN | Read-only local proxy host/port when connected | **P2** | **Partial** (iOS sandbox / background limits) |
| **SOCKS/HTTP ports & credentials** | EditText prefs in `more_options_preferences.xml` | Configure shared proxy | Advanced or display-only from extension IPC | **P2** | **Partial** |
| **Home LAN info section** | `HomeTabFragment` `lanProxyInfoSection` | Shows addresses when sharing | Dashboard section when enabled | **P2** | **Partial** |

---

## Logs & diagnostics

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Logs tab** | `LogsTabFragment`, `LoggingContentProvider`, `MainActivityViewModel` logs flow | Live scrolling diagnostic log | `LogsView` — live, copy all, clear | **P0** | **Yes** |
| **Log DB maintenance** | `LogsMaintenanceWorker.java` | Prunes old logs | Optional App Group rotation | **P2** | **Yes** |
| **Feedback WebView** | `FeedbackActivity`, `FeedbackWorker.java` | In-app feedback form + upload | Settings → Feedback (WKWebView) or mailto + redacted export | **P2** | **Partial** |
| **Crash service** | `PsiphonCrashService.java` | Native crash → notification | MetricKit / crash log export in Advanced (DEBUG) | **P2** | **Partial** |
| **Developer menu** | No dedicated UI; `PsiphonConstants.DEBUG` compile-time | Hidden dev features | `#if DEBUG` Advanced: log level, UI test flag | **P2** | **Yes** |
| **Config import (user)** | Not primary path on Android (embedded at build) | N/A for normal users | Advanced only: JSON import (AzadiTunnel already) | **P1** | **Yes** |

**Logging rules (both platforms):** Do not log secrets, full config, sponsor IDs in clear, or server entry lines.

---

## Statistics

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Statistics tab** | `StatisticsTabFragment`, `DataTransferStats.java` | Elapsed time, totals, throughput charts | New `StatisticsView` with Swift Charts | **P1** | **Partial** (needs byte counters from NE) |
| **Charts (4 series)** | Layout in statistics tab | Visual throughput history | `Charts` framework sparklines | **P1** | **Partial** |

---

## Notifications & background

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Foreground VPN notification** | `TunnelManager` channel `psiphon_notification_channel` | Persistent connected/connecting | `UNUserNotificationCenter` or Live Activity | **P1** | **Partial** |
| **Sound / vibrate prefs** | Notification category in `more_options_preferences.xml` | Notification behavior | iOS system notification settings | **P2** | **N/A** |
| **Stealth notifications** | `DisguiseManager` + `stealthNotifications` | Disguised notification content | Optional discreet notification text | **P2** | **Partial** |
| **“Open app to finish connecting”** | String `notification_text_open_psiphon_to_finish_connecting` | Android foreground requirement | Usually N/A on iOS NE; alert if extension fails | **P2** | **Partial** |
| **VPN revoked** | `INTENT_ACTION_VPN_REVOKED` | Another VPN took over | Observe `NEVPNStatus` + banner | **P1** | **Yes** |
| **MalAware unsafe traffic** | `unsafeTrafficAlertsPreference` | Server-driven malware alerts | Optional notifications from extension messages | **P2** | **Partial** |
| **Upgrade notification** | `UpgradeChecker`, `UpgradeManager` | APK ready | App Store update only | **P2** | **No** |
| **Boot completed receiver** | `PsiphonUpdateReceiver`, manifest | Restart behaviors | iOS: On Demand VPN rules only | **P2** | **Partial** |
| **Auto-connect in-app toggle** | *None* (Always-on is system setting) | OS-level always-on VPN | Document Connect On Demand; optional “connect on launch” in app | **P1** | **Partial** |
| **Auto-reconnect** | TunnelManager reconnect logic | Reconnect after network drop | Extension + app observe path; restart tunnel | **P1** | **Yes** |

---

## Localization

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **In-app language** | `LocaleManager.java`, `R.array.languages`, `values-fa`, `layout-fa` | فارسی + English override | `Localizable.xcstrings` + `fa` locale; optional in-app language (iOS per-app language) | **P1** | **N/A** |
| **RTL layout** | `supportsRtl`, FA resources | RTL for Persian | SwiftUI layout direction + Arabic/Persian testing | **P1** | **N/A** |
| **Transifex pipeline** | `i18n/`, `transifex_pull.py` | Translator workflow | Xcode export for translators | **P2** | **N/A** |

---

## Disguise, NFC, permissions

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Launcher disguises** | `LauncherCalculator`… aliases, `DisguiseManager.java` | Alternate icon/name in launcher | Alternate app icons (limited); no multi-launcher aliases | **P2** | **No** / partial icons |
| **Psiphon Bump (NFC)** | `PsiphonHostApduService`, `PsiphonBumpNfcReaderActivity`, `apduservice.xml` | NFC config share | Omit on iOS | **P2** | **No** |
| **Notification permission rationale** | `NotificationPermissionRationaleActivity` | Explains POST_NOTIFICATIONS | Standard iOS permission alert | **P1** | **N/A** |
| **Location permission rationale** | `LocationPermissionRationaleActivity` | Coarse location for city/ISP stats | Optional coarse location + disclosure; or IP-only | **P2** | **No** in NE |

---

## About, license, disclaimer

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **About Shir o Khorshid** | `preferenceAboutShirOKhorshid`, `unofficial_disclaimer_*` strings | GPL / unofficial disclaimer dialog | Settings → About → **Disclaimer** (required text below) | **P0** | **N/A** |
| **GPL / open source** | License in repo + about dialog | GPL-3.0 obligations | `LICENSE` + in-app GPL screen + `THIRD_PARTY_NOTICES.md` | **P0** | **N/A** |
| **Not affiliated with Psiphon Inc.** | Disclaimer strings | Legal separation | Prominent disclaimer (see Phase 8) | **P0** | **N/A** |
| **Official Psiphon link** | Dialog neutral button `official_psiphon_link` | Points to psiphon.ca | Link in Legal, not as app branding | **P1** | **N/A** |
| **MalAware about** | `preferenceAboutMalAware` | Opens MalAware URL | Advanced link | **P2** | **N/A** |
| **Privacy / data collection** | VPN disclosure + FAQ URLs from `EmbeddedValues` | Explains collection | Privacy screen in Settings | **P1** | **N/A** |
| **Source availability** | GPL distribution | Source offer | About → GitHub source URL | **P0** | **N/A** |

**Required disclaimer (Phase 8):**

> This app is not developed, endorsed, sponsored, or affiliated with Psiphon Inc.

**Branding:** App name **AzadiTunnel** only — do not use Psiphon logo/name as product branding.

---

## Advanced / misc settings (`more_options_preferences.xml`)

| Feature | Android location | What it does | iOS equivalent | Priority | NE feasible |
|---------|------------------|--------------|----------------|----------|-------------|
| **Auto-open homepage** | `autoOpenHomepagePreference` | Opens sponsor URL when connected | Advanced toggle | **P2** | **Partial** |
| **Download upgrades Wi‑Fi only** | `downloadWifiOnlyPreference` | `UpgradeChecker` behavior | N/A (App Store) | **P2** | **No** |
| **Export/import settings** | *Not found* as user feature | — | Advanced export App Group settings JSON (no secrets) | **P2** | **Yes** |

---

## AzadiTunnel current state vs audit (snapshot)

| Area | Status |
|------|--------|
| Connect/disconnect | Implemented (`DashboardView`, `VPNController`) |
| Bundled Psiphon config + 1248 server entries | Implemented via APK extract script |
| Logs (live, copy, clear) | Implemented (`LogsView`) |
| Settings / Advanced import / retry bundled | Partial (`SettingsView`) |
| GPL `LICENSE`, `LEGAL_NOTES.md` | Present |
| Region selection | **Missing** (P0) |
| Traffic counters / duration / public IP | **Missing** (P0/P1) |
| Statistics tab | **Missing** (P1) |
| Upstream proxy / transport / conduit | **Missing** (P1) |
| Split tunnel per-app | **Not feasible** — document only |
| Beautiful modern UI | **Missing** — Phase 4 goal |
| Real device UI test + `generate_204` | Partial (`AzadiTunnelUITests`) |
| Unified log event names (`PSIPHON_CONNECTED`, etc.) | Partial — align with Phase 2 list |

---

## Android parity checklist (for Phases 4–5)

Use this as the implementation backlog. Mark `[x]` in repo when done.

### P0

- [ ] Home: connect/disconnect with accessibility `connectButton`
- [ ] Home: status states + `statusLabel`
- [ ] Home: duration `durationLabel`
- [ ] Home: download/upload speed labels
- [ ] Home: total download/upload counters
- [ ] Region / egress selector (reconnect on change)
- [ ] Bundled config bootstrap (no import required)
- [ ] Logs tab: live, copy, clear
- [ ] Error banners: no config, VPN denied, Psiphon failed, internet test failed
- [ ] About: GPL + disclaimer + third-party notices
- [ ] No secrets in logs or Swift source

### P1

- [ ] Statistics tab (charts + totals)
- [ ] Public IP when available `publicIPLabel`
- [ ] Upstream proxy settings
- [ ] Protocol selection + beast mode
- [ ] Conduit mode (if supported by xcframework build)
- [ ] VPN revoked / region unavailable handling
- [ ] Notifications or Live Activity for VPN status
- [ ] Auto-reconnect behavior
- [ ] Persian + English localization
- [ ] Link to iOS VPN / On Demand settings (Always-on equivalent)
- [ ] First-run data collection disclosure

### P2

- [ ] CDN custom IP/SNI
- [ ] Conduit timeout / reject censored conduits
- [ ] LAN proxy sharing UI
- [ ] Launcher disguises → alternate icons only
- [ ] NFC Bump — skip
- [ ] MalAware alerts
- [ ] Feedback WebView
- [ ] Deep links to settings sections

### Not supported on iOS (show disabled + explanation)

- Per-app include/exclude VPN (`InstalledAppsMultiSelectListPreference`)
- APK sideload upgrade (`UpgradeChecker`)
- NFC Psiphon Bump
- Android Always-on VPN toggle (replace with On Demand guidance)
- `QUERY_ALL_PACKAGES` app enumeration

---

## Phase mapping (project plan)

| Phase | Scope | This audit |
|-------|--------|------------|
| **1** | Android feature audit | **This file** — stop here |
| **2** | Core architecture, unified logs, xcodebuild | See `docs/PSIPHON_TUNNEL_CORE_RESEARCH.md`, existing NE code |
| **3** | Bundled config / migration | `PsiphonBootstrap`, `extract-shiro-bundled-from-apk.sh` |
| **4** | Main UI parity + **beautiful SwiftUI** (user request) | P0 home + tabs + banners + identifiers |
| **5** | Feasible settings from checklist P1 | No fake toggles |
| **6** | Real device UI tests (`00008120-000170D03E10201E`) | `AzadiTunnelUITests` |
| **7** | Build/test discipline | `TESTING.md` |
| **8** | GPL / disclaimer / App Store readiness | Expand Legal screens |

---

## Key Android classes (quick reference)

| Class | Role |
|-------|------|
| `MainActivity` | Tabs, connect, disclosures, deep links |
| `TunnelVpnService` / `TunnelManager` | VPN + Psiphon core lifecycle |
| `EmbeddedValues` | Build-time Psiphon constants |
| `RegionListPreference` | Egress region UI |
| `UpstreamProxySettings` | Upstream proxy persistence |
| `VpnAppsUtils` | Split tunnel package lists |
| `DataTransferStats` | Bytes/speed/duration |
| `DisguiseManager` | Disguise + stealth notifications |
| `LocaleManager` | Language override |
| `UpgradeChecker` / `UpgradeManager` | APK updates |

---

*End of Phase 1 audit. Proceed to Phase 2 only after review.*
