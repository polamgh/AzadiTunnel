import Foundation

enum SecureDNSMode: String, Codable, CaseIterable, Identifiable {
    case off
    case doh
    case dot

    var id: String { rawValue }
}

enum SecureDNSProvider: String, Codable, CaseIterable, Identifiable {
    case cloudflare
    case google
    case quad9
    case adguard
    case custom

    var id: String { rawValue }
}

/// Presets and resolution for optional Secure DNS (DoH / DoT).
enum SecureDNSConfiguration {
    struct DoHEndpoint {
        let url: URL
        let host: String
        let port: UInt16
        let pathAndQuery: String
        let bootstrapIPs: [String]
    }

    static func isActive(_ settings: AppSettings) -> Bool {
        settings.secureDNSMode != .off
    }

    static func logStartupStatus(_ settings: AppSettings) {
        switch settings.secureDNSMode {
        case .off:
            SharedLogger.shared.log(.secureDnsDisabled)
        case .doh, .dot:
            SharedLogger.shared.log(
                .secureDnsEnabled,
                detail: "mode=\(settings.secureDNSMode.rawValue) provider=\(settings.secureDNSProvider.rawValue) block_cleartext=\(settings.blockCleartextDNS)"
            )
        }
    }

    static func dohURL(for settings: AppSettings) -> URL? {
        dohEndpoint(for: settings)?.url
    }

    static func dohEndpoint(for settings: AppSettings) -> DoHEndpoint? {
        guard settings.secureDNSMode == .doh else { return nil }
        let raw: String
        let bootstrapIPs: [String]
        switch settings.secureDNSProvider {
        case .google:
            raw = "https://dns.google/dns-query"
            bootstrapIPs = ["8.8.8.8", "8.8.4.4"]
        case .cloudflare:
            raw = "https://cloudflare-dns.com/dns-query"
            bootstrapIPs = ["1.1.1.1", "1.0.0.1"]
        case .quad9:
            raw = "https://dns.quad9.net/dns-query"
            bootstrapIPs = ["9.9.9.9"]
        case .adguard:
            raw = "https://dns.adguard-dns.com/dns-query"
            bootstrapIPs = ["94.140.14.14", "94.140.15.15"]
        case .custom:
            raw = settings.customDoHURL.trimmingCharacters(in: .whitespacesAndNewlines)
            bootstrapIPs = []
        }
        guard !raw.isEmpty else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty else { return nil }
        let port = url.port.map { UInt16($0) } ?? 443
        let path = url.path.isEmpty ? "/dns-query" : url.path
        let pathAndQuery = path + (url.query.map { "?\($0)" } ?? "")
        return DoHEndpoint(
            url: url,
            host: host,
            port: port,
            pathAndQuery: pathAndQuery,
            bootstrapIPs: bootstrapIPs
        )
    }

    static func dotEndpoint(for settings: AppSettings) -> (host: String, port: UInt16)? {
        guard settings.secureDNSMode == .dot else { return nil }
        let host: String
        switch settings.secureDNSProvider {
        case .google:
            host = "dns.google"
        case .cloudflare:
            host = "cloudflare-dns.com"
        case .quad9:
            host = "dns.quad9.net"
        case .adguard:
            host = "dns.adguard-dns.com"
        case .custom:
            host = settings.customDoTHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !host.isEmpty else { return nil }
        return (host, 853)
    }

    static func providerDisplayName(_ provider: SecureDNSProvider) -> String {
        switch provider {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .adguard: return "AdGuard"
        case .custom: return "Custom"
        }
    }

    static func modeDisplayName(_ mode: SecureDNSMode) -> String {
        switch mode {
        case .off: return "Off"
        case .doh: return "DoH"
        case .dot: return "DoT"
        }
    }

    /// Standard A-record query for `example.com` (used by connectivity tests).
    static let exampleComWireQuery = Data([
        0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
        0x00, 0x01, 0x00, 0x01
    ])

    /// Virtual resolver shown to iOS. UDP/53 is always intercepted in the tunnel forwarder.
    static func advertisedDnsServers(for settings: AppSettings) -> [String] {
        _ = settings
        return ["10.0.0.1"]
    }

    /// Fixed loopback port for the Secure DNS system HTTP proxy (CONNECT → Psiphon SOCKS + DoH dial plan).
    static let systemHTTPProxyPort = 19_087

    /// When true, iOS system HTTP/HTTPS proxy targets our loopback bridge.
    ///
    /// The bridge resolves proxy-aware `CONNECT host:443` names through Secure DNS before dialing
    /// Psiphon. It falls back quickly when cleartext fallback is allowed, so DoH failures do not
    /// take down normal browsing.
    static func usesSystemHTTPProxyBridge(for settings: AppSettings) -> Bool {
        settings.secureDNSMode == .doh
    }

    /// Port advertised in `NEProxySettings` for the active system HTTP proxy.
    static func systemHTTPProxyPort(
        for settings: AppSettings,
        psiphonHttpPort: Int,
        bridgeActive: Bool
    ) -> Int {
        if usesSystemHTTPProxyBridge(for: settings), bridgeActive {
            return systemHTTPProxyPort
        }
        return psiphonHttpPort
    }
}
