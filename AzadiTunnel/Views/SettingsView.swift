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

    var body: some View {
        ZStack {
            NavigationView {
            Form {
                connectionSection
                regionSection
                protocolSection
                if settings.protocolSelection == .cdnFronting {
                    cdnFrontingSection
                }
                proxySection
                proxyOnlySection
                shareProxySection
                bypassSection
                secureDnsSection
                behaviorSection
                advancedSection
                logsSection
                legalSection

                if let importError {
                    Section {
                        Text(importError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t(.settingsTitle))
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
        Section(L10n.t(.settingsConnection)) {
            HStack {
                Text(L10n.t(.settingsConfigSource))
                Spacer()
                Text(usesBundled ? L10n.t(.settingsBundled) : L10n.t(.settingsCustom))
                    .foregroundStyle(.secondary)
            }
            if entryLineCount > 0 {
                Text("\(L10n.t(.settingsServerEntries)): \(entryLineCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var regionSection: some View {
        Section(L10n.t(.settingsRegion)) {
            Picker(L10n.t(.settingsEgressRegion), selection: $settings.egressRegion) {
                Text(L10n.t(.regionAny)).tag("")
                ForEach(PsiphonRegionList.all, id: \.self) { code in
                    Text(RegionDisplayNames.pickerLabel(for: code)).tag(code)
                }
            }
            .onChange(of: settings.egressRegion) { _ in
                persist("egress_region")
            }
            Text(L10n.t(.settingsRegionHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var protocolSection: some View {
        Section(L10n.t(.settingsTransport)) {
            Picker(L10n.t(.settingsProtocol), selection: $settings.protocolSelection) {
                ForEach(AppSettings.ProtocolSelection.allCases) { p in
                    Text(SettingsLabels.protocolName(p)).tag(p)
                        .disabled(p == .conduit && !conduitConnectAllowed)
                }
            }
            .onChange(of: settings.protocolSelection) { newValue in
                if newValue == .conduit, !conduitConnectAllowed {
                    settings.protocolSelection = .auto
                    importError = PsiphonDistributorKeys.conduitBlockedStatusLine
                }
                persist("protocol_selection")
            }
            if !conduitConnectAllowed {
                Text(PsiphonDistributorKeys.conduitBlockedStatusLine)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle(L10n.t(.settingsBeastMode), isOn: $settings.beastModeEnabled)
                .accessibilityIdentifier("beastModeToggle")
                .onChange(of: settings.beastModeEnabled) { _ in persist("beast_mode") }
            if settings.protocolSelection == .conduit {
                Picker(L10n.t(.settingsConduitMode), selection: $settings.conduitMode) {
                    ForEach(AppSettings.ConduitMode.allCases) { mode in
                        Text(SettingsLabels.conduitModeName(mode)).tag(mode)
                    }
                }
                .onChange(of: settings.conduitMode) { _ in
                    settings.conduitFallbackToPublic = false
                    persist("conduit_mode")
                }
                Toggle(L10n.t(.settingsBlockCensored), isOn: $settings.rejectCensoredCountryProxies)
                    .onChange(of: settings.rejectCensoredCountryProxies) { _ in persist("conduit_reject_countries") }
                Picker(L10n.t(.settingsConduitTimeout), selection: $settings.conduitTimeoutSeconds) {
                    Text("2 min").tag(120)
                    Text("3 min").tag(180)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                .onChange(of: settings.conduitTimeoutSeconds) { _ in persist("conduit_timeout") }
            }
            Text(protocolHelpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
        Section(L10n.t(.settingsCDNFronting)) {
            Text(L10n.t(.settingsCDNExpert))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle(L10n.t(.settingsCDNBuiltinScan), isOn: $settings.cdnFrontingUseBuiltInScan)
                .onChange(of: settings.cdnFrontingUseBuiltInScan) { _ in persist("cdn_builtin_scan") }
            TextField(L10n.t(.settingsCDNEdgeIPs), text: $settings.cdnFrontingCustomIpList)
                .lineLimit(8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: settings.cdnFrontingCustomIpList) { _ in persist("cdn_custom_ips") }
            TextField(L10n.t(.settingsCDNSNI), text: $settings.cdnFrontingCustomSni)
                .lineLimit(6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: settings.cdnFrontingCustomSni) { _ in persist("cdn_custom_sni") }
            Text(cdnFrontingSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var proxySection: some View {
        Section(L10n.t(.settingsProxy)) {
            Toggle(L10n.t(.settingsProxyEnable), isOn: $settings.upstreamProxyEnabled)
                .onChange(of: settings.upstreamProxyEnabled) { _ in persist("upstream_proxy_enabled") }
            if settings.upstreamProxyEnabled {
                TextField(L10n.t(.settingsProxyHost), text: $settings.upstreamProxyHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.upstreamProxyHost) { _ in persist("upstream_proxy_host") }
                Stepper("\(L10n.t(.settingsProxyPort)): \(settings.upstreamProxyPort)", value: $settings.upstreamProxyPort, in: 1...65535)
                    .onChange(of: settings.upstreamProxyPort) { _ in persist("upstream_proxy_port") }
                Toggle(L10n.t(.settingsProxySystem), isOn: $settings.upstreamProxyUseSystem)
                    .onChange(of: settings.upstreamProxyUseSystem) { _ in persist("upstream_proxy_system") }
                SecureField("Username (optional)", text: $settings.upstreamProxyUsername)
                SecureField("Password (optional)", text: $settings.upstreamProxyPassword)
            }
        }
    }

    private var proxyOnlySection: some View {
        Section {
            Toggle(L10n.t(.proxyOnlyEnableTitle), isOn: Binding(
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
            ))
            .accessibilityIdentifier("proxyOnlySettingsToggle")
            Text(L10n.t(.proxyOnlyEnableDescription))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.proxyOnlyWarningShort))
                .font(.footnote)
                .foregroundStyle(.orange)
            NavigationLink {
                ProxyOnlySettingsView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(.proxyOnlyRowTitle))
                    Text(L10n.t(.proxyOnlyConfiguredAppsHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityIdentifier("proxyOnlySettingsLink")
        }
    }

    private func reconnectIfConnected() async {
        guard VPNController.shared.status == .connected || VPNController.shared.status == .connecting else { return }
        await VPNController.shared.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await VPNController.shared.connect()
    }

    private var shareProxySection: some View {
        Section {
            NavigationLink {
                ShareProxyView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(.shareProxyRowTitle))
                    Text(L10n.t(.shareProxyRowSubtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("shareProxyRow")
        }
    }

    private var bypassSection: some View {
        Section {
            NavigationLink {
                BypassIranView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(.bypassRowTitle))
                    Text(L10n.t(.bypassRowSubtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("bypassIranRow")
        }
    }

    private var transportSection: some View {
        Section("Advanced transport") {
            Toggle("Disable timeouts", isOn: $settings.disableTimeouts)
                .onChange(of: settings.disableTimeouts) { _ in persist("disable_timeouts") }
        }
    }

    private var secureDnsSection: some View {
        Section {
            NavigationLink {
                SecureDNSSettingsView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(.secureDnsRowTitle))
                    Text(L10n.t(.secureDnsRowSubtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("secureDnsRow")
        }
    }

    private var behaviorSection: some View {
        Section(L10n.t(.settingsBehavior)) {
            Toggle(L10n.t(.settingsSmartFallback), isOn: $settings.smartFallbackChainEnabled)
                .onChange(of: settings.smartFallbackChainEnabled) { _ in persist("smart_fallback_chain") }
            Toggle(L10n.t(.settingsAutoReconnect), isOn: $settings.autoReconnect)
                .onChange(of: settings.autoReconnect) { _ in persist("auto_reconnect") }
            Toggle(L10n.t(.settingsConnectOnLaunch), isOn: $settings.connectOnLaunch)
                .onChange(of: settings.connectOnLaunch) { _ in persist("connect_on_launch") }
            Toggle(L10n.t(.settingsVPNOnDemand), isOn: $settings.vpnOnDemandEnabled)
                .accessibilityIdentifier("vpnOnDemandToggle")
                .onChange(of: settings.vpnOnDemandEnabled) { _ in
                    persist("vpn_on_demand_enabled")
                    Task { await VPNController.shared.applyOnDemandFromAppSettings() }
                }
            if settings.vpnOnDemandEnabled {
                Picker(L10n.t(.settingsVPNOnDemandMode), selection: $settings.vpnOnDemandMode) {
                    Text(L10n.t(.onDemandAlways)).tag(AppSettings.VPNOnDemandMode.always)
                    Text(L10n.t(.onDemandWiFi)).tag(AppSettings.VPNOnDemandMode.wifi)
                    Text(L10n.t(.onDemandCellular)).tag(AppSettings.VPNOnDemandMode.cellular)
                }
                .onChange(of: settings.vpnOnDemandMode) { _ in
                    persist("vpn_on_demand_mode")
                    Task { await VPNController.shared.applyOnDemandFromAppSettings() }
                }
                Text(L10n.t(.settingsVPNOnDemandHelp))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker(L10n.t(.language), selection: $settings.preferredLanguage) {
                Text(L10n.t(.languageSystem)).tag(AppSettings.AppLanguage.system)
                Text(L10n.t(.languageEnglish)).tag(AppSettings.AppLanguage.english)
                Text(L10n.t(.languagePersian)).tag(AppSettings.AppLanguage.persian)
            }
            .onChange(of: settings.preferredLanguage) { _ in
                persist("language")
                AppLanguageController.shared.reload()
            }
        }
    }

    private var advancedSection: some View {
        Section(L10n.t(.settingsAdvanced)) {
            Text(L10n.t(.settingsAdvancedHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(L10n.t(.settingsRetryBundled)) {
                let ok = PsiphonBootstrap.installBundledConfigIfNeeded(force: true)
                importError = ok ? nil : L10n.t(.settingsRetryBundledFailed)
                refresh()
                presentToast(ok ? L10n.t(.settingsBundledInstallSuccess) : L10n.t(.settingsRetryBundledFailed))
            }
            .accessibilityIdentifier("retry_bundled_install_button")
            Button(L10n.t(.settingsImportConfig)) {
                SharedLogger.shared.log(.configImportOpened)
                showImporter = true
            }
            .accessibilityIdentifier("import_config_button")
            Button(L10n.t(.settingsExportDebug)) {
                DebugReportExporter.presentShareSheet(from: nil)
                presentToast(L10n.t(.settingsDebugReportReady))
            }
            .accessibilityIdentifier("export_debug_report_button")
            Button(L10n.t(.settingsResetDefaults), role: .destructive) {
                showResetDefaultsConfirm = true
            }
            .accessibilityIdentifier("reset_settings_defaults_button")
        }
    }

    private var logsSection: some View {
        Section(L10n.t(.settingsLogs)) {
            NavigationLink {
                LogsView()
            } label: {
                Text(L10n.t(.logsTitle))
            }
            .accessibilityIdentifier("logsSettingsLink")
        }
    }

    private var legalSection: some View {
        Section(L10n.t(.settingsLegal)) {
            NavigationLink {
                LegalOpenSourceView()
            } label: {
                Text(L10n.t(.legalOpenSourceTitle))
                    .accessibilityIdentifier("legalOpenSourceLink")
            }
            NavigationLink {
                PrivacyNoticeView()
            } label: {
                Text(L10n.t(.privacyNoticeTitle))
                    .accessibilityIdentifier("privacyNoticeLink")
            }
            NavigationLink(L10n.t(.settingsAbout)) { AboutView() }
            NavigationLink {
                SupportAzadiTunnelView()
            } label: {
                Text(L10n.t(.settingsSupport))
                    .accessibilityIdentifier("supportAzadiTunnelLink")
            }
        }
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
    static let all = ["US", "CA", "GB", "DE", "FR", "NL", "CH", "SE", "JP", "SG", "AU", "IR", "AE", "IN", "BR", "ZA"]
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
