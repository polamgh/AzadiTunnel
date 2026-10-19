import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var lang = AppLanguageController.shared
    @State private var showImporter = false
    @State private var importError: String?
    @State private var settings = SharedSettingsStore.shared.appSettings
    @State private var usesBundled = true
    @State private var entryLineCount = 0
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastHideTask: Task<Void, Never>?
    @State private var showResetDefaultsConfirm = false
    @State private var showRegionPicker = false

    var body: some View {
        ZStack {
            NavigationView {
            Form {
                Section {
                    SettingsHeroCard(
                        protocolName: SettingsLabels.protocolName(settings.protocolSelection),
                        regionName: settings.egressRegion.isEmpty
                            ? L10n.t(.regionAny)
                            : RegionDisplayNames.pickerLabel(for: settings.egressRegion, locale: lang.locale)
                    )
                }
                .listRowBackground(SettingsRowBackground())
                connectionSection
                regionSection
                protocolSection
                if settings.protocolSelection == .cdnFronting {
                    cdnFrontingSection
                }
                proxySection
                proxyOnlySection
                networkToolsSection
                behaviorSection
                advancedSection
                logsSection
                legalSection

                if let importError {
                    Section {
                        Text(importError)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .navigationTitle(L10n.t(.settingsTitle))
            .settingsScrollBackgroundHidden()
            .background(SettingsSurface())
            .tint(AppTheme.iranGreenBright)
            .id(lang.revision)
            .accessibilityIdentifier("settingsScreen")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onAppear { refresh() }
            .sheet(isPresented: $showRegionPicker) {
                RegionPickerSheet(selectedCode: settings.egressRegion) { code in
                    settings.egressRegion = code
                    SharedSettingsStore.shared.egressRegionUnavailable = false
                    persist("egress_region")
                }
            }
            }
            .navigationViewStyle(StackNavigationViewStyle())

            if showToast {
                VStack {
                    Spacer()
                    AppToastBanner(message: toastMessage)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: showToast)
        .alert(L10n.t(.settingsResetDefaultsConfirmTitle), isPresented: $showResetDefaultsConfirm) {
            Button(L10n.t(.settingsResetDefaults), role: .destructive) {
                resetSettingsToDefaults()
            }
            Button(L10n.t(.cancel), role: .cancel) {}
        } message: {
            Text(L10n.t(.settingsResetDefaultsConfirmMessage))
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                SettingsRowLabel(icon: "doc.badge.gearshape", tint: .gray, title: L10n.t(.settingsConfigSource))
                Spacer()
                Text(usesBundled ? L10n.t(.settingsBundled) : L10n.t(.settingsCustom))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.t(.settingsConfigSource)))
            .accessibilityValue(Text(usesBundled ? L10n.t(.settingsBundled) : L10n.t(.settingsCustom)))
            if entryLineCount > 0 {
                HStack {
                    SettingsRowLabel(icon: "server.rack", tint: .teal, title: L10n.t(.settingsServerEntries))
                    Spacer()
                    Text("\(entryLineCount)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsConnection), icon: "bolt.horizontal.fill")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var regionSection: some View {
        Section {
            Button {
                showRegionPicker = true
            } label: {
                HStack {
                    SettingsRowLabel(icon: "globe.europe.africa.fill", tint: .blue, title: L10n.t(.settingsEgressRegion))
                    Spacer()
                    Text(settings.egressRegion.isEmpty
                         ? L10n.t(.regionAny)
                         : RegionDisplayNames.pickerLabel(for: settings.egressRegion, locale: lang.locale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(L10n.t(.settingsRegionHint)))
            SettingsFootnote(text: L10n.t(.settingsRegionHint))
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsRegion), icon: "mappin.and.ellipse")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var protocolSection: some View {
        Section {
            Picker(selection: $settings.protocolSelection) {
                ForEach(AppSettings.ProtocolSelection.allCases) { p in
                    Text(SettingsLabels.protocolName(p)).tag(p)
                        .disabled(p == .conduit && !conduitConnectAllowed)
                }
            } label: {
                SettingsRowLabel(icon: "arrow.triangle.branch", tint: AppTheme.iranGreen, title: L10n.t(.settingsProtocol))
            }
            .onChange(of: settings.protocolSelection) { newValue in
                if newValue == .conduit, !conduitConnectAllowed {
                    settings.protocolSelection = .auto
                    importError = PsiphonDistributorKeys.conduitBlockedStatusLine
                }
                persist("protocol_selection")
            }
            .accessibilityHint(Text(protocolHelpText))
            if !conduitConnectAllowed {
                SettingsFootnote(text: PsiphonDistributorKeys.conduitBlockedStatusLine, tint: .orange)
            }
            Toggle(isOn: $settings.beastModeEnabled) {
                SettingsRowLabel(icon: "bolt.fill", tint: .orange, title: L10n.t(.settingsBeastMode))
            }
                .accessibilityIdentifier("beastModeToggle")
                .onChange(of: settings.beastModeEnabled) { _ in persist("beast_mode") }
            if settings.protocolSelection == .conduit {
                Picker(selection: $settings.conduitMode) {
                    ForEach(AppSettings.ConduitMode.allCases) { mode in
                        Text(SettingsLabels.conduitModeName(mode)).tag(mode)
                    }
                } label: {
                    SettingsRowLabel(icon: "point.3.connected.trianglepath.dotted", tint: .purple, title: L10n.t(.settingsConduitMode))
                }
                .onChange(of: settings.conduitMode) { _ in
                    settings.conduitFallbackToPublic = false
                    persist("conduit_mode")
                }
                Toggle(isOn: $settings.rejectCensoredCountryProxies) {
                    SettingsRowLabel(icon: "hand.raised.fill", tint: .red, title: L10n.t(.settingsBlockCensored))
                }
                    .onChange(of: settings.rejectCensoredCountryProxies) { _ in persist("conduit_reject_countries") }
                Picker(selection: $settings.conduitTimeoutSeconds) {
                    Text("2 min").tag(120)
                    Text("3 min").tag(180)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                } label: {
                    SettingsRowLabel(icon: "timer", tint: .teal, title: L10n.t(.settingsConduitTimeout))
                }
                .onChange(of: settings.conduitTimeoutSeconds) { _ in persist("conduit_timeout") }
            }
            SettingsFootnote(text: protocolHelpText)
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsTransport), icon: "point.topleft.down.curvedto.point.bottomright.up")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var conduitConnectAllowed: Bool {
        SharedSettingsStore.shared.conduitConnectAllowed
    }

    private var cdnFrontingSummary: String {
        let ipCount = PsiphonShiroCDNFrontingConfig.parseIPList(settings.cdnFrontingCustomIpList).count
        let sniCount = PsiphonShiroCDNFrontingConfig.parseSNIList(settings.cdnFrontingCustomSni).count
        return "\(L10n.t(.settingsCDNEdgesSummary)): \(PsiphonShiroCDNFrontingConfig.builtInEdgeIPs.count). \(L10n.t(.settingsCustom)): \(ipCount) IP, \(sniCount) SNI."
    }

    private var protocolHelpText: String {
        if settings.beastModeEnabled && settings.protocolSelection == .auto {
            return L10n.t(.helpBeastAuto)
        }
        if settings.protocolSelection == .auto {
            return L10n.t(.helpAuto)
        }
        if settings.protocolSelection == .conduit {
            if !conduitConnectAllowed {
                return L10n.t(.helpConduitBlocked)
            }
            return L10n.t(.helpConduit)
        }
        if settings.protocolSelection == .cdnFronting {
            return L10n.t(.helpCDN)
        }
        return L10n.t(.helpDirect)
    }

    private var cdnFrontingSection: some View {
        Section {
            SettingsFootnote(text: L10n.t(.settingsCDNExpert))
            Toggle(isOn: $settings.cdnFrontingUseBuiltInScan) {
                SettingsRowLabel(icon: "dot.radiowaves.left.and.right", tint: .indigo, title: L10n.t(.settingsCDNBuiltinScan))
            }
                .onChange(of: settings.cdnFrontingUseBuiltInScan) { _ in persist("cdn_builtin_scan") }
            TextField(L10n.t(.settingsCDNEdgeIPs), text: $settings.cdnFrontingCustomIpList)
                .lineLimit(8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(L10n.t(.settingsCDNEdgeIPs)))
                .onChange(of: settings.cdnFrontingCustomIpList) { _ in persist("cdn_custom_ips") }
            TextField(L10n.t(.settingsCDNSNI), text: $settings.cdnFrontingCustomSni)
                .lineLimit(6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(L10n.t(.settingsCDNSNI)))
                .onChange(of: settings.cdnFrontingCustomSni) { _ in persist("cdn_custom_sni") }
            Text(cdnFrontingSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsCDNFronting), icon: "cloud.fill")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var proxySection: some View {
        Section {
            Toggle(isOn: $settings.upstreamProxyEnabled) {
                SettingsRowLabel(icon: "network", tint: .blue, title: L10n.t(.settingsProxyEnable))
            }
                .onChange(of: settings.upstreamProxyEnabled) { _ in persist("upstream_proxy_enabled") }
            if settings.upstreamProxyEnabled {
                TextField(L10n.t(.settingsProxyHost), text: $settings.upstreamProxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(L10n.t(.settingsProxyHost)))
                    .onChange(of: settings.upstreamProxyHost) { _ in persist("upstream_proxy_host") }
                Stepper("\(L10n.t(.settingsProxyPort)): \(settings.upstreamProxyPort)", value: $settings.upstreamProxyPort, in: 1...65535)
                    .onChange(of: settings.upstreamProxyPort) { _ in persist("upstream_proxy_port") }
                Toggle(isOn: $settings.upstreamProxyUseSystem) {
                    SettingsRowLabel(icon: "gearshape.2.fill", tint: .gray, title: L10n.t(.settingsProxySystem))
                }
                    .onChange(of: settings.upstreamProxyUseSystem) { _ in persist("upstream_proxy_system") }
                SecureField(L10n.t(.settingsProxyUsername), text: $settings.upstreamProxyUsername)
                    .accessibilityLabel(Text(L10n.t(.settingsProxyUsername)))
                SecureField(L10n.t(.settingsProxyPassword), text: $settings.upstreamProxyPassword)
                    .accessibilityLabel(Text(L10n.t(.settingsProxyPassword)))
            }
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsProxy), icon: "arrow.left.arrow.right")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var proxyOnlySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.proxyOnlyModeEnabled },
                set: { newValue in
                    settings.proxyOnlyModeEnabled = newValue
                    persist("proxy_only_mode")
                    SharedLogger.shared.log(newValue ? .proxyOnlyModeEnabled : .proxyOnlyModeDisabled)
                    if newValue {
                        SharedLogger.shared.log(.proxyOnlyWarningNotFullVPN)
                    }
                    Task { await reconnectIfConnected() }
                }
            )) {
                SettingsRowLabel(icon: "arrow.left.arrow.right.circle.fill", tint: .orange, title: L10n.t(.proxyOnlyEnableTitle))
            }
            .accessibilityIdentifier("proxyOnlySettingsToggle")
            SettingsFootnote(text: L10n.t(.proxyOnlyEnableDescription))
            SettingsFootnote(text: L10n.t(.proxyOnlyWarningShort), tint: .orange)
            NavigationLink {
                ProxyOnlySettingsView()
            } label: {
                SettingsRowLabel(
                    icon: "apps.iphone",
                    tint: .orange,
                    title: L10n.t(.proxyOnlyRowTitle),
                    subtitle: L10n.t(.proxyOnlyConfiguredAppsHint)
                )
            }
            .accessibilityIdentifier("proxyOnlySettingsLink")
        } header: {
            SettingsSectionHeader(title: L10n.t(.proxyOnlyEnableTitle), icon: "rectangle.connected.to.line.below")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private func reconnectIfConnected() async {
        guard VPNController.shared.status == .connected || VPNController.shared.status == .connecting else { return }
        await VPNController.shared.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await VPNController.shared.connect()
    }



    private var networkToolsSection: some View {
        Section {
            NavigationLink {
                ShareProxyView()
            } label: {
                SettingsRowLabel(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: AppTheme.iranGreen,
                    title: L10n.t(.shareProxyRowTitle),
                    subtitle: L10n.t(.shareProxyRowSubtitle)
                )
            }
            .accessibilityIdentifier("shareProxyRow")
            NavigationLink {
                BypassIranView()
            } label: {
                SettingsRowLabel(
                    icon: "arrow.triangle.turn.up.right.diamond.fill",
                    tint: .teal,
                    title: L10n.t(.bypassRowTitle),
                    subtitle: L10n.t(.bypassRowSubtitle)
                )
            }
            .accessibilityIdentifier("bypassIranRow")
            NavigationLink {
                SecureDNSSettingsView()
            } label: {
                SettingsRowLabel(
                    icon: "lock.shield.fill",
                    tint: .indigo,
                    title: L10n.t(.secureDnsRowTitle),
                    subtitle: L10n.t(.secureDnsRowSubtitle)
                )
            }
            .accessibilityIdentifier("secureDnsRow")
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsNetworkTools), icon: "network.badge.shield.half.filled")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var transportSection: some View {
        Section("Advanced transport") {
            Toggle("Disable timeouts", isOn: $settings.disableTimeouts)
                .onChange(of: settings.disableTimeouts) { _ in persist("disable_timeouts") }
        }
    }


    private var behaviorSection: some View {
        Section {
            Toggle(isOn: $settings.smartFallbackChainEnabled) {
                SettingsRowLabel(icon: "arrow.triangle.2.circlepath", tint: AppTheme.iranGreen, title: L10n.t(.settingsSmartFallback))
            }
                .onChange(of: settings.smartFallbackChainEnabled) { _ in persist("smart_fallback_chain") }
            Toggle(isOn: $settings.autoRetryOnNoInternet) {
                SettingsRowLabel(icon: "arrow.clockwise", tint: .blue, title: L10n.t(.settingsAutoRetryNoInternet))
            }
                .onChange(of: settings.autoRetryOnNoInternet) { _ in persist("auto_retry_no_internet") }
            SettingsFootnote(text: L10n.t(.settingsAutoRetryNoInternetHelp))
            Toggle(isOn: $settings.autoReconnect) {
                SettingsRowLabel(icon: "link", tint: .teal, title: L10n.t(.settingsAutoReconnect))
            }
                .onChange(of: settings.autoReconnect) { _ in persist("auto_reconnect") }
            Toggle(isOn: $settings.connectOnLaunch) {
                SettingsRowLabel(icon: "power", tint: AppTheme.iranRed, title: L10n.t(.settingsConnectOnLaunch))
            }
                .onChange(of: settings.connectOnLaunch) { _ in persist("connect_on_launch") }
            Toggle(isOn: $settings.vpnOnDemandEnabled) {
                SettingsRowLabel(icon: "bolt.horizontal.circle.fill", tint: .purple, title: L10n.t(.settingsVPNOnDemand))
            }
                .accessibilityIdentifier("vpnOnDemandToggle")
                .onChange(of: settings.vpnOnDemandEnabled) { _ in
                    persist("vpn_on_demand_enabled")
                    Task { await VPNController.shared.applyOnDemandFromAppSettings() }
                }
            if settings.vpnOnDemandEnabled {
                Picker(selection: $settings.vpnOnDemandMode) {
                    Text(L10n.t(.onDemandAlways)).tag(AppSettings.VPNOnDemandMode.always)
                    Text(L10n.t(.onDemandWiFi)).tag(AppSettings.VPNOnDemandMode.wifi)
                    Text(L10n.t(.onDemandCellular)).tag(AppSettings.VPNOnDemandMode.cellular)
                } label: {
                    SettingsRowLabel(icon: "wifi", tint: .blue, title: L10n.t(.settingsVPNOnDemandMode))
                }
                .onChange(of: settings.vpnOnDemandMode) { _ in
                    persist("vpn_on_demand_mode")
                    Task { await VPNController.shared.applyOnDemandFromAppSettings() }
                }
                SettingsFootnote(text: L10n.t(.settingsVPNOnDemandHelp))
            }
            Picker(selection: $settings.preferredLanguage) {
                Text(L10n.t(.languageSystem)).tag(AppSettings.AppLanguage.system)
                Text(L10n.t(.languageEnglish)).tag(AppSettings.AppLanguage.english)
                Text(L10n.t(.languagePersian)).tag(AppSettings.AppLanguage.persian)
            } label: {
                SettingsRowLabel(icon: "character.bubble.fill", tint: .pink, title: L10n.t(.language))
            }
            .onChange(of: settings.preferredLanguage) { _ in
                persist("language")
                AppLanguageController.shared.reload()
            }
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsBehavior), icon: "slider.horizontal.3")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var advancedSection: some View {
        Section {
            SettingsFootnote(text: L10n.t(.settingsAdvancedHint))
            Button {
                let ok = PsiphonBootstrap.installBundledConfigIfNeeded(force: true)
                importError = ok ? nil : L10n.t(.settingsRetryBundledFailed)
                refresh()
                presentToast(ok ? L10n.t(.settingsBundledInstallSuccess) : L10n.t(.settingsRetryBundledFailed))
            } label: {
                SettingsRowLabel(icon: "arrow.down.circle.fill", tint: .blue, title: L10n.t(.settingsRetryBundled))
            }
            .accessibilityIdentifier("retry_bundled_install_button")
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
            Button {
                SharedLogger.shared.log(.configImportOpened)
                showImporter = true
            } label: {
                SettingsRowLabel(icon: "square.and.arrow.down.fill", tint: .indigo, title: L10n.t(.settingsImportConfig))
            }
            .accessibilityIdentifier("import_config_button")
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
            Button {
                DebugReportExporter.presentShareSheet(from: nil)
                presentToast(L10n.t(.settingsDebugReportReady))
            } label: {
                SettingsRowLabel(icon: "ladybug.fill", tint: .orange, title: L10n.t(.settingsExportDebug))
            }
            .accessibilityIdentifier("export_debug_report_button")
            Button(role: .destructive) {
                showResetDefaultsConfirm = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "arrow.counterclockwise", tint: AppTheme.iranRed)
                    Text(L10n.t(.settingsResetDefaults))
                        .foregroundStyle(AppTheme.iranRed)
                }
            }
            .accessibilityIdentifier("reset_settings_defaults_button")
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsAdvanced), icon: "wrench.and.screwdriver.fill")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var logsSection: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                SettingsRowLabel(icon: "list.bullet.rectangle.fill", tint: .gray, title: L10n.t(.logsTitle))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("logsSettingsLink")
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsLogs), icon: "doc.text.magnifyingglass")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private var legalSection: some View {
        Section {
            NavigationLink {
                LegalOpenSourceView()
            } label: {
                SettingsRowLabel(icon: "chevron.left.forwardslash.chevron.right", tint: .gray, title: L10n.t(.legalOpenSourceTitle))
            }
            .accessibilityIdentifier("legalOpenSourceLink")
            NavigationLink {
                PrivacyNoticeView()
            } label: {
                SettingsRowLabel(icon: "hand.raised.fill", tint: .blue, title: L10n.t(.privacyNoticeTitle))
            }
            .accessibilityIdentifier("privacyNoticeLink")
            NavigationLink {
                AboutView()
            } label: {
                SettingsRowLabel(icon: "info.circle.fill", tint: .teal, title: L10n.t(.settingsAbout))
            }
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
            NavigationLink {
                SupportAzadiTunnelView()
            } label: {
                SettingsRowLabel(icon: "heart.fill", tint: AppTheme.iranRed, title: L10n.t(.settingsSupport))
            }
            .accessibilityIdentifier("supportAzadiTunnelLink")
        } header: {
            SettingsSectionHeader(title: L10n.t(.settingsLegal), icon: "checkmark.seal.fill")
        }
        .listRowBackground(SettingsRowBackground())
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
    }

    private func refresh() {
        settings = SharedSettingsStore.shared.appSettings
        usesBundled = SharedSettingsStore.shared.usesBundledConfig
        entryLineCount = SharedSettingsStore.shared.psiphonServerEntriesLineCount
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try ConfigImporter.importFrom(url: url)
                refresh()
                presentToast(L10n.t(.settingsConfigImportSuccess))
            } catch {
                importError = error.localizedDescription
                presentToast(L10n.t(.settingsConfigImportFailed))
            }
        case .failure(let error):
            importError = error.localizedDescription
            presentToast(L10n.t(.settingsConfigImportFailed))
        }
    }

    private func resetSettingsToDefaults() {
        SharedSettingsStore.shared.resetAppSettingsToDefaults()
        refresh()
        AppLanguageController.shared.reload()
        Task {
            await VPNController.shared.applyOnDemandFromAppSettings()
            await reconnectIfConnected()
        }
        presentToast(L10n.t(.settingsResetDefaultsDone))
    }

    private func presentToast(_ message: String) {
        toastHideTask?.cancel()
        toastMessage = message
        showToast = true
        toastHideTask = Task {
            try? await TaskSleep.seconds(2)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showToast = false
            }
        }
    }
}

enum PsiphonRegionList {
    static var all: [String] { PsiphonEgressRegionStore.knownRegions() }
}

enum SettingsLabels {
    static func protocolName(_ p: AppSettings.ProtocolSelection) -> String {
        switch p {
        case .auto: return L10n.t(.protocolAuto)
        case .direct: return L10n.t(.protocolDirect)
        case .cdnFronting: return L10n.t(.protocolCDN)
        case .conduit: return L10n.t(.protocolConduit)
        }
    }

    static func conduitModeName(_ mode: AppSettings.ConduitMode) -> String {
        switch mode {
        case .auto: return L10n.t(.conduitModeAuto)
        case .shiroCommunity: return L10n.t(.conduitModeCommunity)
        case .publicOnly: return L10n.t(.conduitModePublic)
        }
    }
}
