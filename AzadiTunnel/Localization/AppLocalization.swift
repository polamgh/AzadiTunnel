import Foundation
import Combine
import SwiftUI

/// In-app strings for English / Persian (Settings → Language).
@MainActor
final class AppLanguageController: ObservableObject {
    static let shared = AppLanguageController()

    @Published private(set) var revision = 0

    var effectiveLanguage: AppSettings.AppLanguage {
        let pref = SharedSettingsStore.shared.appSettings.preferredLanguage
        if pref == .system {
            let code: String
            if #available(iOS 16, *) {
                code = Locale.current.language.languageCode?.identifier ?? "en"
            } else {
                code = Locale.current.languageCode ?? "en"
            }
            return code == "fa" ? .persian : .english
        }
        return pref
    }

    var locale: Locale {
        switch effectiveLanguage {
        case .persian: return Locale(identifier: "fa")
        case .english: return Locale(identifier: "en")
        case .system: return Locale.current
        }
    }

    var layoutDirection: LayoutDirection {
        effectiveLanguage == .persian ? .rightToLeft : .leftToRight
    }

    func reload() {
        revision &+= 1
    }

    func text(_ key: L10nKey) -> String {
        let base = effectiveLanguage == .persian ? Self.fa : Self.en
        let extra = effectiveLanguage == .persian ? Self.extraFa : Self.extraEn
        return extra[key] ?? base[key] ?? Self.en[key] ?? key.rawValue
    }

    enum LayoutDirection {
        case leftToRight
        case rightToLeft
    }

    enum L10nKey: String, CaseIterable {
        case appSubtitle
        case tabVPN
        case tabStats
        case tabLogs
        case tabSettings
        case status
        case connected
        case connecting
        case disconnecting
        case disconnected
        case failed
        case setupRequired
        case traffic
        case download
        case upload
        case totalDownload
        case totalUpload
        case trafficFootnote
        case region
        case regionAny
        case publicIP
        case settingsTitle
        case language
        case languageSystem
        case languageEnglish
        case languagePersian
        case session
        case downloadSpeed
        case statisticsTitle
        case logsTitle
        case beforeConnect
        case understand
        case connectedProtocol
        case conduitProgress
        case conduitProgressHint
        case leakTestTitle
        case leakTestStatus
        case leakTestDNS
        case leakTestIPv6
        case qualityReportTitle
        case qualityLatency
        case qualityHTTPS204
        case qualityTransport
        case qualityCDNEdge
        case qualityCDNSNI
        case fallbackTitle
        case fallbackCurrent
        case fallbackLastFailed
        case fallbackReason
        case fallbackSuccess
        case aboutNavTitle
        case aboutMission
        case aboutPrivacyTitle
        case aboutPrivacyBody
        case aboutContentTitle
        case aboutContentBody
        case aboutOpenSourceTitle
        case aboutOpenSourceBody
        case aboutVersionTitle
        case aboutVersionLabel
        case aboutBuildLabel
        case aboutSupportTitle
        case aboutSupportPlaceholder
        case aboutScreenTitle
        case aboutDeveloperLabel
        case aboutDeveloperValue
        case aboutAppVersionLabel
        case aboutCoreVersionLabel
        case aboutCoreVersionValue
        case aboutRateUs
        case aboutWebsite
        case aboutPsiphonGitHub
        case aboutCompanyWebsite
        case aboutX
        case aboutContactUs
        case aboutTerms
        case aboutCopyright
        case aboutResponsibleUse
        case aboutOpenSourceAck
        case legalOpenSourceTitle
        case privacyNoticeTitle
        case beforeYouConnectTitle
        case disclaimerIntro
        case disclaimerResponsibleUseTitle
        case disclaimerResponsibleUse
        case disclaimerNoGuaranteeTitle
        case disclaimerNoGuarantee
        case disclaimerPrivacyDiagnosticsTitle
        case disclaimerPrivacyDiagnostics
        case disclaimerNoIllegalContentTitle
        case disclaimerNoIllegalContent
        case disclaimerThirdPartyNetworksTitle
        case disclaimerThirdPartyNetworks
        case iUnderstandAndAgree
        case cancel
        case viewFullLicenseNotices
        case legalAppLicenseSection
        case legalOpenSourceComponentsSection
        case legalGplWarningSection
        case legalGplWarningBody
        case legalLicenseUnavailable
        case legalLicenseLabel
        case privacyNoticeBody
        case privacyNoticeNoSecrets
        case privacyNoticeReviewExport
        case privacyNoticeStoreKit
        case supportButton
        case splashTagline
        case diagnosticsSection
        case vpnPing
        case copy
        case copiedToClipboard
        case testPass
        case testFail
        case configSetupBanner
        case onboardingNavTitle
        case onboardingWelcomeTitle
        case onboardingWelcomeBody
        case onboardingPrivacyTitle
        case onboardingPrivacyBody
        case onboardingTransportTitle
        case onboardingTransportBody
        case onboardingFallbackTitle
        case onboardingFallbackBody
        case onboardingSupportTitle
        case onboardingSupportBody
        case onboardingContinue
        case onboardingGetStarted
        case onboardingSkip
        case protocolAuto
        case protocolDirect
        case protocolCDN
        case protocolConduit
        case conduitModeAuto
        case conduitModeCommunity
        case conduitModePublic
        case settingsConnection
        case settingsConfigSource
        case settingsBundled
        case settingsCustom
        case settingsServerEntries
        case settingsRegion
        case settingsEgressRegion
        case settingsRegionHint
        case settingsTransport
        case settingsProtocol
        case settingsBeastMode
        case settingsConduitMode
        case settingsBlockCensored
        case settingsConduitTimeout
        case settingsCDNFronting
        case settingsCDNExpert
        case settingsCDNBuiltinScan
        case settingsCDNEdgeIPs
        case settingsCDNSNI
        case settingsCDNEdgesSummary
        case settingsProxy
        case settingsProxyEnable
        case settingsProxyHost
        case settingsProxyPort
        case settingsProxySystem
        case settingsBehavior
        case settingsSmartFallback
        case settingsAutoReconnect
        case settingsConnectOnLaunch
        case settingsVPNOnDemand
        case settingsVPNOnDemandMode
        case settingsVPNOnDemandHelp
        case onDemandAlways
        case onDemandWiFi
        case onDemandCellular
        case settingsAdvanced
        case settingsAdvancedHint
        case settingsRetryBundled
        case settingsRetryBundledFailed
        case settingsBundledInstallSuccess
        case settingsConfigImportSuccess
        case settingsConfigImportFailed
        case settingsDebugReportReady
        case settingsImportConfig
        case settingsExportDebug
        case settingsLegal
        case settingsDisclaimer
        case settingsGPL
        case settingsNotices
        case settingsPrivacy
        case settingsAbout
        case settingsSupport
        case settingsLogs
        case helpBeastAuto
        case helpAuto
        case helpConduitBlocked
        case helpConduit
        case helpCDN
        case helpDirect
        case errorNoConfig
        case errorNoConfigSub
        case errorConduitBlocked
        case errorConduitBlockedSub
        case errorVPNPermission
        case errorVPNPermissionSub
        case errorOtherVpnBlocking
        case errorOtherVpnBlockingSub
        case openIOSSettings
        case errorPsiphonFailed
        case errorPsiphonFailedSub
        case errorInternetTest
        case errorInternetTestSub
        case changeRegion
        case copyLogLine
        case copyAllLogs
        case refreshLogs
        case logsCopiedTitle
        case supportIntro
        case supportLoading
        case supportUnavailable
        case supportRestore
        case supportStatus
        case supportTipsSection
        case supportSubscriptionsSection
        case supportTipSmall
        case supportTipMedium
        case supportTipLarge
        case supportMonthly
        case supportYearly
        case supportStateNotPurchased
        case supportStatePurchased
        case supportStateSubscribed
        case supportStateExpired
        case supportStateUnknown
        case supportSubscriptionDisclaimer
        case supportManageSubscriptions
        case supportFreeBadge
        case shareProxyRowTitle
        case shareProxyRowSubtitle
        case shareProxyNavTitle
        case shareProxyEnableTitle
        case shareProxyEnableDescription
        case shareProxyTrustedNetworkWarning
        case shareProxyStatusSection
        case shareProxyStatusRunning
        case shareProxyStatusStopped
        case shareProxyStatusVpnDisconnected
        case shareProxyStatusNoWifi
        case shareProxyStatusPortInUse
        case shareProxyStatusFailed
        case shareProxyWifiIP
        case shareProxyNoWifiIP
        case shareProxyNoWifiHint
        case shareProxyAddressSection
        case shareProxyHttpAddressTitle
        case shareProxySocksAddressTitle
        case shareProxyAddressUnavailable
        case shareProxyPortsSection
        case shareProxyHttpPort
        case shareProxySocksPort
        case shareProxySavePorts
        case shareProxyPortsSaved
        case shareProxyPortOutOfRange
        case shareProxyPortsMustDiffer
        case shareProxyPortHint
        case shareProxyAuthSection
        case shareProxyAuthToggle
        case shareProxyUsername
        case shareProxyPassword
        case shareProxyNoAuthWarning
        case shareProxySecuritySection
        case shareProxySecurityWarning
        case shareProxyInstructionsSection
        case shareProxyHowToiPhone
        case shareProxyHowToAndroid
        case shareProxyHowToWindows
        case shareProxyHowToAndroidTV
        case shareProxyInstructionsiPhone
        case shareProxyInstructionsAndroid
        case shareProxyInstructionsWindows
        case shareProxyInstructionsAndroidTV
        case shareProxySocksNoteTitle
        case shareProxySocksNoteBody
    }

    private static var extraEn: [L10nKey: String] = [:]
    private static var extraFa: [L10nKey: String] = [:]

    static func registerExtraTranslations(en: [L10nKey: String], fa: [L10nKey: String]) {
        extraEn = en
        extraFa = fa
        shared.reload()
    }

    private static let en: [L10nKey: String] = [
        .appSubtitle: "Secure tunnel for all apps on this device",
        .tabVPN: "VPN",
        .tabStats: "Stats",
        .tabLogs: "Logs",
        .tabSettings: "Settings",
        .status: "Status",
        .connected: "Connected",
        .connecting: "Connecting…",
        .disconnecting: "Disconnecting…",
        .disconnected: "Disconnected",
        .failed: "Failed",
        .setupRequired: "Setup required",
        .traffic: "Traffic",
        .download: "Download",
        .upload: "Upload",
        .totalDownload: "Total download",
        .totalUpload: "Total upload",
        .trafficFootnote: "Totals include all apps while VPN is on and persist across reconnects.",
        .region: "Region",
        .regionAny: "Any (best)",
        .publicIP: "Public IP",
        .settingsTitle: "Settings",
        .language: "Language",
        .languageSystem: "System",
        .languageEnglish: "English",
        .languagePersian: "فارسی",
        .session: "Session",
        .downloadSpeed: "Download speed",
        .statisticsTitle: "Statistics",
        .logsTitle: "Logs",
        .beforeConnect: "Before you connect",
        .understand: "I understand",
        .connectedProtocol: "Protocol",
        .conduitProgress: "Conduit",
        .conduitProgressHint: "Live relay attempts during connect",
        .leakTestTitle: "Leak test",
        .leakTestStatus: "Result",
        .leakTestDNS: "DNS",
        .leakTestIPv6: "IPv6",
        .qualityReportTitle: "Connection quality",
        .qualityLatency: "Latency",
        .qualityHTTPS204: "HTTPS 204",
        .qualityTransport: "Transport",
        .qualityCDNEdge: "CDN edge",
        .qualityCDNSNI: "CDN SNI",
        .fallbackTitle: "Fallback chain",
        .fallbackCurrent: "Current step",
        .fallbackLastFailed: "Last failed",
        .fallbackReason: "Reason",
        .fallbackSuccess: "Succeeded",
        .aboutNavTitle: "About AzadiTunnel",
        .aboutMission: "AzadiTunnel is built to help users access a more open and reliable internet through privacy-focused tunneling technology.",
        .aboutPrivacyTitle: "Privacy-first",
        .aboutPrivacyBody: "We design the app to minimize data collection. Connection diagnostics stay on your device unless you export a debug report.",
        .aboutContentTitle: "Content & servers",
        .aboutContentBody: "AzadiTunnel does not ship illegal content or preset paid servers. You connect using your own or bundled Psiphon configuration.",
        .aboutOpenSourceTitle: "Open source",
        .aboutOpenSourceBody: "Core tunneling uses open-source Psiphon components. See THIRD_PARTY_NOTICES.md in the project repository.",
        .aboutVersionTitle: "Version",
        .aboutVersionLabel: "Version",
        .aboutBuildLabel: "Build",
        .aboutSupportTitle: "Support",
        .aboutSupportPlaceholder: "For help, use the in-app Logs and Export Debug Report from Settings. Support purchases are optional under Support AzadiTunnel."
    ]

    private static let fa: [L10nKey: String] = [
        .appSubtitle: "تونل امن برای همهٔ اپ‌ها روی این دستگاه",
        .tabVPN: "VPN",
        .tabStats: "آمار",
        .tabLogs: "گزارش",
        .tabSettings: "تنظیمات",
        .status: "وضعیت",
        .connected: "متصل",
        .connecting: "در حال اتصال…",
        .disconnecting: "در حال قطع…",
        .disconnected: "قطع",
        .failed: "خطا",
        .setupRequired: "نیاز به راه‌اندازی",
        .traffic: "ترافیک",
        .download: "دانلود",
        .upload: "آپلود",
        .totalDownload: "مجموع دانلود",
        .totalUpload: "مجموع آپلود",
        .trafficFootnote: "شامل ترافیک همهٔ اپ‌ها هنگام VPN است و بعد از قطع/وصل حفظ می‌شود.",
        .region: "منطقه",
        .regionAny: "خودکار (بهترین)",
        .publicIP: "IP عمومی",
        .settingsTitle: "تنظیمات",
        .language: "زبان",
        .languageSystem: "سیستم",
        .languageEnglish: "English",
        .languagePersian: "فارسی",
        .session: "نشست",
        .downloadSpeed: "سرعت دانلود",
        .statisticsTitle: "آمار",
        .logsTitle: "گزارش",
        .beforeConnect: "قبل از اتصال",
        .understand: "متوجه شدم",
        .connectedProtocol: "پروتکل",
        .conduitProgress: "کندویت",
        .conduitProgressHint: "تلاش‌های زنده هنگام اتصال",
        .leakTestTitle: "آزمون نشت",
        .leakTestStatus: "نتیجه",
        .leakTestDNS: "DNS",
        .leakTestIPv6: "IPv6",
        .qualityReportTitle: "کیفیت اتصال",
        .qualityLatency: "تأخیر",
        .qualityHTTPS204: "HTTPS 204",
        .qualityTransport: "حمل‌ونقل",
        .qualityCDNEdge: "IP لبه CDN",
        .qualityCDNSNI: "SNI مربوط به CDN",
        .fallbackTitle: "زنجیرهٔ جایگزین",
        .fallbackCurrent: "مرحلهٔ فعلی",
        .fallbackLastFailed: "آخرین خطا",
        .fallbackReason: "دلیل",
        .fallbackSuccess: "موفق",
        .aboutNavTitle: "دربارهٔ AzadiTunnel",
        .aboutMission: "AzadiTunnel برای دسترسی به اینترنت بازتر و پایدارتر با فناوری تونل متمرکز بر حریم خصوصی ساخته شده است.",
        .aboutPrivacyTitle: "حریم خصوصی",
        .aboutPrivacyBody: "جمع‌آوری داده را کمینه می‌کنیم. تشخیص اتصال روی دستگاه شما می‌ماند مگر گزارش اشکال‌زدایی را صادر کنید.",
        .aboutContentTitle: "محتوا و سرورها",
        .aboutContentBody: "AzadiTunnel محتوای غیرقانونی یا سرور پولی از پیش تنظیم‌شده ندارد. با پیکربندی Psiphon خودتان یا بستهٔ داخلی وصل می‌شوید.",
        .aboutOpenSourceTitle: "متن‌باز",
        .aboutOpenSourceBody: "هستهٔ تونل از اجزای متن‌باز Psiphon استفاده می‌کند. THIRD_PARTY_NOTICES.md را در مخزن ببینید.",
        .aboutVersionTitle: "نسخه",
        .aboutVersionLabel: "نسخه",
        .aboutBuildLabel: "بیلد",
        .aboutSupportTitle: "پشتیبانی",
        .aboutSupportPlaceholder: "از گزارش‌ها و «صادرات گزارش اشکال‌زدایی» در تنظیمات کمک بگیرید. خرید پشتیبانی اختیاری است."
    ]
}

enum L10n {
    @MainActor
    static func t(_ key: AppLanguageController.L10nKey) -> String {
        AppLanguageController.shared.text(key)
    }
}
