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
            if args.contains("-UITestEnableSmartFallback") {
                settings.smartFallbackChainEnabled = true
            }
            if args.contains("-UITestShortFallback") {
                settings.fallbackTimeoutCDN = 8
                settings.fallbackTimeoutAutoBeast = 8
                settings.fallbackTimeoutDirect = 120
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
                detail: "protocol=\(settings.protocolSelection.rawValue) beast=\(settings.beastModeEnabled) limits=\(limits)"
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
