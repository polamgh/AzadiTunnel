import SwiftUI

@main
struct AzadiTunnelApp: App {
    private static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestMode")
    }

    @State private var showLanguagePicker = !isUITest && !SharedSettingsStore.shared.appSettings.hasChosenLanguage
    @State private var showSplash = !isUITest && SharedSettingsStore.shared.appSettings.hasChosenLanguage
    @State private var showOnboarding = false

    init() {
        AppLocalizationUI.register()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestMode") {
            if args.contains("-UITestClearLogs") {
                SharedLogger.shared.clear()
            }
            SharedSettingsStore.shared.isUITestMode = true
            SharedSettingsStore.shared.vpnStatus = .disconnected
            SharedSettingsStore.shared.psiphonTunnelEstablished = false
            var settings = SharedSettingsStore.shared.appSettings
            settings.hasAcceptedVPNDisclosure = true
            settings.hasAcceptedConnectionDisclaimer = true
            settings.hasCompletedOnboarding = true
            settings.hasChosenLanguage = true
            settings.preferredLanguage = .english
            if args.contains("-UITestResetDisclaimer") {
                settings.hasAcceptedVPNDisclosure = false
                settings.hasAcceptedConnectionDisclaimer = false
            }
            let protoRaw = Self.uiTestArgValue(args, flag: "-UITestSetProtocol")
                ?? ProcessInfo.processInfo.environment["UITEST_PROTOCOL"]
            if let protoRaw,
               let selection = AppSettings.ProtocolSelection(rawValue: protoRaw) {
                settings.protocolSelection = selection
            }
            let beastRaw = Self.uiTestArgValue(args, flag: "-UITestSetBeastMode")
                ?? ProcessInfo.processInfo.environment["UITEST_BEAST_MODE"]
            if let beastRaw {
                settings.beastModeEnabled = beastRaw == "1"
            }
            let conduitModeRaw = Self.uiTestArgValue(args, flag: "-UITestSetConduitMode")
                ?? ProcessInfo.processInfo.environment["UITEST_CONDUIT_MODE"]
            if let conduitModeRaw,
               let mode = AppSettings.ConduitMode(rawValue: conduitModeRaw) {
                settings.conduitMode = mode
                if mode != .auto {
                    settings.conduitFallbackToPublic = false
                }
            }
            if args.contains("-UITestDisableSmartFallback") {
                settings.smartFallbackChainEnabled = false
            }
            let proxyOnlyRaw = Self.uiTestArgValue(args, flag: "-UITestSetProxyOnlyMode")
                ?? ProcessInfo.processInfo.environment["UITEST_PROXY_ONLY_MODE"]
            if let proxyOnlyRaw {
                settings.proxyOnlyModeEnabled = proxyOnlyRaw == "1" || proxyOnlyRaw.lowercased() == "true"
            }
            if args.contains("-UITestEnableSmartFallback") {
                settings.smartFallbackChainEnabled = true
            }
            if args.contains("-UITestShortFallback") {
                settings.fallbackTimeoutCDN = 8
                settings.fallbackTimeoutAutoBeast = 8
                settings.fallbackTimeoutDirect = 120
            }
            let secureDnsModeRaw = Self.uiTestArgValue(args, flag: "-UITestSetSecureDNSMode")
            if let secureDnsModeRaw,
               let mode = SecureDNSMode(rawValue: secureDnsModeRaw) {
                settings.secureDNSMode = mode
            }
            let secureDnsProviderRaw = Self.uiTestArgValue(args, flag: "-UITestSetSecureDNSProvider")
            if let secureDnsProviderRaw,
               let provider = SecureDNSProvider(rawValue: secureDnsProviderRaw) {
                settings.secureDNSProvider = provider
            }
            let secureDnsBlockRaw = Self.uiTestArgValue(args, flag: "-UITestSetSecureDNSBlockCleartext")
                ?? ProcessInfo.processInfo.environment["UITEST_SECURE_DNS_BLOCK_CLEARTEXT"]
            if let secureDnsBlockRaw {
                settings.blockCleartextDNS = secureDnsBlockRaw == "1" || secureDnsBlockRaw.lowercased() == "true"
            }
            let secureDnsCustomDoH = Self.uiTestArgValue(args, flag: "-UITestSetSecureDNSCustomDoHURL")
                ?? ProcessInfo.processInfo.environment["UITEST_SECURE_DNS_CUSTOM_DOH_URL"]
            if let secureDnsCustomDoH {
                settings.customDoHURL = secureDnsCustomDoH
            }
            if args.contains("-UITestAutoConnect") || args.contains("-UITestForceBootstrap") {
                settings.conduitFallbackToPublic = false
            }
            SharedSettingsStore.shared.updateAppSettings(settings, logKey: "uitest_boot")
            let limits = PsiphonConfigComposer.parseLimitProtocols(
                from: SharedSettingsStore.shared.psiphonConfigJSON ?? ""
            )
            SharedLogger.shared.logRaw(
                "UITEST_SETTINGS",
                detail: "protocol=\(settings.protocolSelection.rawValue) beast=\(settings.beastModeEnabled) proxy_only=\(settings.proxyOnlyModeEnabled) secure_dns=\(settings.secureDNSMode.rawValue) provider=\(settings.secureDNSProvider.rawValue) block_cleartext=\(settings.blockCleartextDNS) limits=\(limits)"
            )
        }
        let forceBootstrap = args.contains("-UITestAutoConnect") || args.contains("-UITestForceBootstrap")
        _ = PsiphonBootstrap.installBundledConfigIfNeeded(force: forceBootstrap)
        SharedLogger.shared.log(.appBoot)
        if args.contains("-UITestExportDebugReport") {
            _ = DebugReportExporter.buildReport()
        }
        Task { @MainActor in
            AppLanguageController.shared.reload()
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if showSplash {
                    SplashView {
                        showSplash = false
                        showOnboarding = !SharedSettingsStore.shared.appSettings.hasCompletedOnboarding
                            && !ProcessInfo.processInfo.arguments.contains("-UITestMode")
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .fullScreenCover(isPresented: $showLanguagePicker) {
                LanguageSelectionView {
                    showLanguagePicker = false
                    if !Self.isUITest {
                        showSplash = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView { showOnboarding = false }
            }
        }
    }

    private static func uiTestArgValue(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: i)
        guard next < args.endIndex else { return nil }
        return args[next]
    }
}
