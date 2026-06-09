import Foundation

/// A saved "best connection" found by the Find Best Connection scan: a protocol + egress region
/// that reached the minimum usable speed. Persisted separately from the user's manual selection so
/// the existing manual connection system is never modified.
struct BestConnectionRecord: Equatable {
    let protocolSelection: AppSettings.ProtocolSelection
    /// Egress region code (e.g. "DE"); empty means "Any".
    let region: String
    /// Measured usable download speed in Mbps at save time.
    let mbps: Double
    let updatedAt: Date?
}

/// One working connection discovered by the scan: a full combination of server options
/// (protocol + country + beast mode + Secure DNS mode/provider). Persisted as a JSON list so the
/// dashboard can show every passing combination, not just the single best.
struct FoundConnection: Codable, Equatable, Identifiable {
    let protocolRaw: String
    /// Egress region code (e.g. "DE"); empty means "Any".
    let region: String
    /// Psiphon "Beast mode" (broad protocol set) on/off.
    let beastMode: Bool
    /// Secure DNS mode raw value (`off` / `doh` / `dot`).
    let dnsModeRaw: String
    /// Secure DNS provider raw value (`cloudflare` / `google` / …).
    let dnsProviderRaw: String
    /// Measured usable download speed in Mbps.
    let mbps: Double

    // Distinct per full option combination so different combos are separate list entries.
    var id: String { "\(protocolRaw)|\(region)|b\(beastMode ? 1 : 0)|\(dnsModeRaw)|\(dnsProviderRaw)" }
    var protocolSelection: AppSettings.ProtocolSelection? { AppSettings.ProtocolSelection(rawValue: protocolRaw) }
    var dnsMode: SecureDNSMode { SecureDNSMode(rawValue: dnsModeRaw) ?? .off }
    var dnsProvider: SecureDNSProvider { SecureDNSProvider(rawValue: dnsProviderRaw) ?? .cloudflare }

    init(
        protocolSelection: AppSettings.ProtocolSelection,
        region: String,
        beastMode: Bool,
        dnsMode: SecureDNSMode,
        dnsProvider: SecureDNSProvider,
        mbps: Double
    ) {
        self.protocolRaw = protocolSelection.rawValue
        self.region = region
        self.beastMode = beastMode
        self.dnsModeRaw = dnsMode.rawValue
        self.dnsProviderRaw = dnsProvider.rawValue
        self.mbps = mbps
    }
}
