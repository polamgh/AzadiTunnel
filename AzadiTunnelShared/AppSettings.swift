import Foundation

/// User-facing settings (Android parity). Persisted in App Group; logged on change without secrets.
struct AppSettings: Codable, Equatable {
    var egressRegion: String = ""
    var upstreamProxyEnabled: Bool = false
    var upstreamProxyHost: String = ""
    var upstreamProxyPort: Int = 8080
    var upstreamProxyUseSystem: Bool = false
    var upstreamProxyUsername: String = ""
    var upstreamProxyPassword: String = ""
    var protocolSelection: ProtocolSelection = .auto
    /// Shiro `conduitModePreference`: auto / shirokhorshid / public (default public for fast Conduit connect).
    var conduitMode: ConduitMode = .publicOnly
    /// After auto-mode timeout, Shiro omits personal compartment (public conduits only).
    var conduitFallbackToPublic: Bool = false
    /// Shiro `conduitTimeoutPreference` default (seconds) before auto → public fallback.
    var conduitTimeoutSeconds: Int = 180
    /// Shiro `rejectCensoredCountryProxiesPreference` — block IR/CN/RU/etc. conduit peers.
    var rejectCensoredCountryProxies: Bool = true
    /// Shiro `cdnFrontingCustomIpListPreference` — extra edge IPs/CIDRs for scan + overrides.
    var cdnFrontingCustomIpList: String = ""
    /// Shiro `cdnFrontingCustomSniPreference` — extra SNI hostnames for scan + edge overrides.
    var cdnFrontingCustomSni: String = ""
    /// Shiro always sets `FrontedMeekCDNScanUseBuiltInSpec` true; toggle disables built-in scan spec.
    var cdnFrontingUseBuiltInScan: Bool = true
    var beastModeEnabled: Bool = true
    /// When enabled (and not Conduit), connect tries fallback chains: Auto → CDN then Direct; CDN mode → CDN, Auto+Beast, Direct.
    var smartFallbackChainEnabled: Bool = true
    var fallbackTimeoutCDN: TimeInterval = 120
    var fallbackTimeoutAutoBeast: TimeInterval = 120
    var fallbackTimeoutDirect: TimeInterval = 120
    var disableTimeouts: Bool = false
    var autoReconnect: Bool = true
    var connectOnLaunch: Bool = false
    /// iOS VPN On Demand — applied to NETunnelProviderManager (not only Settings app).
    var vpnOnDemandEnabled: Bool = false
    var vpnOnDemandMode: VPNOnDemandMode = .always
    var preferredLanguage: AppLanguage = .system
    var hasAcceptedVPNDisclosure: Bool = false
    /// First-connection legal disclaimer (persisted in App Group settings JSON).
    var hasAcceptedConnectionDisclaimer: Bool = false
    var hasCompletedOnboarding: Bool = false
    /// First-launch language picker completed (English or Persian chosen explicitly).
    var hasChosenLanguage: Bool = false

    /// When true, Psiphon runs without full-tunnel routing; only local HTTP/SOCKS listeners relay traffic.
    var proxyOnlyModeEnabled: Bool = false

    /// Share this iPhone's tunneled proxy with other devices on the same Wi-Fi.
    var shareProxyOnLocalNetworkEnabled: Bool = false
    /// LAN HTTP proxy listener port (1024…65535).
    var lanHttpProxyPort: Int = 8087
    /// LAN SOCKS5 proxy listener port (1024…65535).
    var lanSocksProxyPort: Int = 1088
    /// Reserved for future username/password challenge on LAN proxy.
    var lanProxyAuthEnabled: Bool = false
    var lanProxyUsername: String = ""
    var lanProxyPassword: String = ""

    /// When true, Iranian IPv4 ranges (and custom/domain bypass entries) are added to the tunnel's
    /// `excludedRoutes` so they leave through the device's normal interface instead of the VPN.
    var bypassIranIPsEnabled: Bool = false
    /// User-supplied IPs / CIDRs (newline or comma separated), e.g. `1.2.3.4` or `1.2.3.0/24`.
    var bypassCustomRoutes: String = ""
    /// User-supplied hostnames (newline or comma separated) resolved to /32 excluded routes.
    var bypassDomains: String = ""
    /// EXPERIMENTAL. When true, the in-tunnel system HTTP proxy is dropped while bypass routes are
    /// active so excludedRoutes are honored for proxy-using apps too. Off by default because it can
    /// break general internet / public-IP checks in this architecture (system proxy carries them).
    var bypassStrictModeEnabled: Bool = false

    enum ConduitMode: String, Codable, CaseIterable, Identifiable {
        case auto
        case shiroCommunity = "shirokhorshid"
        case publicOnly = "public"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto (community then public)"
            case .shiroCommunity: return "Community"
            case .publicOnly: return "Public"
            }
        }
    }

    enum ProtocolSelection: String, Codable, CaseIterable, Identifiable {
        case auto
        case direct
        case cdnFronting
        case conduit

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .direct: return "Direct"
            case .cdnFronting: return "CDN fronting"
            case .conduit: return "Conduit"
            }
        }
    }

    enum VPNOnDemandMode: String, Codable, CaseIterable, Identifiable {
        case always
        case wifi
        case cellular

        var id: String { rawValue }
    }

    enum AppLanguage: String, Codable, CaseIterable, Identifiable {
        case system
        case english = "en"
        case persian = "fa"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .english: return "English"
            case .persian: return "فارسی"
            }
        }
    }

    /// Fresh factory defaults while keeping onboarding, disclaimer, and language choice.
    static func factoryDefaults(preserving from: AppSettings) -> AppSettings {
        var fresh = AppSettings()
        fresh.hasAcceptedConnectionDisclaimer = from.hasAcceptedConnectionDisclaimer
        fresh.hasAcceptedVPNDisclosure = from.hasAcceptedVPNDisclosure
        fresh.hasCompletedOnboarding = from.hasCompletedOnboarding
        fresh.hasChosenLanguage = from.hasChosenLanguage
        fresh.preferredLanguage = from.preferredLanguage
        return fresh
    }
}
