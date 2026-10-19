import Foundation

enum SecureDNSMode: String, Codable, CaseIterable, Identifiable {
    /// Tunnel DNS uses Psiphon's native transparent DNS (no DoH interception).
    case off
    /// RFC 8484 DoH through the established Psiphon SOCKS proxy.
    case doh
    /// Decoded for migration of pre-DoH-only settings. Converted to ``doh`` on read.
    @available(*, deprecated, message: "DoT was replaced by RFC 8484 DoH")
    case dot

    var id: String { rawValue }

    static var allCases: [SecureDNSMode] { [.off, .doh] }
}

enum SecureDNSProvider: String, Codable, CaseIterable, Identifiable {
    case cloudflare
    case google
    case quad9
    case adguard
    case custom

    var id: String { rawValue }
}

/// Presets and resolution for RFC 8484 DoH inside the established Psiphon tunnel.
enum SecureDNSConfiguration {
    struct DoHEndpoint {
        let url: URL
        let host: String
        let port: UInt16
        let pathAndQuery: String
        let bootstrapIPs: [String]
    }

    static func isActive(_ settings: AppSettings) -> Bool {
        switch settings.secureDNSMode {
        case .doh, .dot:
            return true
        case .off:
            return false
        }
    }

    static func logStartupStatus(_ settings: AppSettings) {
        if isActive(settings) {
            SharedLogger.shared.log(
                .secureDnsEnabled,
                detail: "mode=doh provider=\(settings.secureDNSProvider.rawValue) transport=psiphon_socks"
            )
        } else {
            SharedLogger.shared.logRaw(
                "SECURE_DNS_DISABLED",
                detail: "mode=off dns=psiphon_transparent"
            )
        }
    }

    /// Returns the selected provider followed by independent HTTPS providers. The list is capped
    /// by ``SecureDNSFailoverPolicy`` at three attempts, but always contains at least two built-in
    /// endpoints when a custom endpoint is selected.
    static func dohEndpoints(for settings: AppSettings) -> [DoHEndpoint] {
        let providers: [SecureDNSProvider] = [
            settings.secureDNSProvider,
            .cloudflare,
            .google,
            .quad9,
            .adguard,
        ]
        var endpoints: [DoHEndpoint] = []
        var seen = Set<String>()

        for provider in providers {
            guard let endpoint = endpoint(for: provider, settings: settings) else { continue }
            let key = endpoint.url.absoluteString
            guard seen.insert(key).inserted else { continue }
            endpoints.append(endpoint)
        }
        return endpoints
    }

    private static func endpoint(
        for provider: SecureDNSProvider,
        settings: AppSettings
    ) -> DoHEndpoint? {
        let raw: String
        let bootstrapIPs: [String]
        switch provider {
        case .google:
            raw = "https://dns.google/dns-query"
            bootstrapIPs = ["8.8.8.8", "8.8.4.4"]
        case .cloudflare:
            raw = "https://cloudflare-dns.com/dns-query"
            bootstrapIPs = ["1.1.1.1", "1.0.0.1"]
        case .quad9:
            raw = "https://dns.quad9.net/dns-query"
            bootstrapIPs = ["9.9.9.9", "149.112.112.112"]
        case .adguard:
            raw = "https://dns.adguard-dns.com/dns-query"
            bootstrapIPs = ["94.140.14.14", "94.140.15.15"]
        case .custom:
            raw = settings.customDoHURL.trimmingCharacters(in: .whitespacesAndNewlines)
            bootstrapIPs = []
        }
        return makeEndpoint(raw: raw, bootstrapIPs: bootstrapIPs)
    }

    private static func makeEndpoint(raw: String, bootstrapIPs: [String]) -> DoHEndpoint? {
        guard !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              !host.contains(where: { $0.isWhitespace || $0 == "\r" || $0 == "\n" }) else {
            return nil
        }
        let portValue = url.port ?? 443
        guard (1...65_535).contains(portValue), let port = UInt16(exactly: portValue) else {
            return nil
        }
        let path = url.path.isEmpty ? "/dns-query" : url.path
        guard path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n") else { return nil }
        let pathAndQuery = path + (url.query.map { "?\($0)" } ?? "")
        guard !pathAndQuery.contains(where: { $0.isWhitespace || $0 == "\r" || $0 == "\n" }) else {
            return nil
        }
        return DoHEndpoint(
            url: url,
            host: host,
            port: port,
            pathAndQuery: pathAndQuery,
            bootstrapIPs: bootstrapIPs
        )
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
        case .doh, .dot: return "DoH"
        }
    }

    /// Standard A-record query for `example.com` (used by connectivity tests).
    static let exampleComWireQuery = Data([
        0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
        0x00, 0x01, 0x00, 0x01
    ])

    /// Virtual resolver shown to iOS. When Secure DNS is on, Swift intercepts
    /// UDP/53 to this address for DoH. When off, Psiphon's transparent DNS
    /// (`PacketTunnelTransparentDNSIPv4Address`) answers the same address.
    static func advertisedDnsServers(for settings: AppSettings) -> [String] {
        _ = settings
        return ["10.0.0.1"]
    }

}
