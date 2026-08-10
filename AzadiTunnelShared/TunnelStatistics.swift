import Foundation
import Network

/// Accepts only globally routable IPv4/IPv6 literals returned by a public-IP service.
/// This prevents captive-portal text or a private/loopback address from marking a
/// tunnel as ready.
enum PublicIPAddress {
    static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let address = IPv4Address(value) {
            let bytes = [UInt8](address.rawValue)
            guard isGloballyRoutableIPv4(bytes) else { return nil }
            return bytes.map(String.init).joined(separator: ".")
        }

        if let address = IPv6Address(value) {
            let bytes = [UInt8](address.rawValue)
            guard isGloballyRoutableIPv6(bytes) else { return nil }
            return value
        }

        return nil
    }

    private static func isGloballyRoutableIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0]
        let b = bytes[1]
        let c = bytes[2]

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100, (64...127).contains(b) { return false }
        if a == 169, b == 254 { return false }
        if a == 172, (16...31).contains(b) { return false }
        if a == 192, b == 168 { return false }
        if a == 192, b == 0, c == 0 { return false }
        if a == 192, b == 0, c == 2 { return false }
        if a == 198, b == 18 || b == 19 { return false }
        if a == 198, b == 51, c == 100 { return false }
        if a == 203, b == 0, c == 113 { return false }
        return true
    }

    private static func isGloballyRoutableIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // Current globally routable unicast space is 2000::/3. This excludes
        // loopback, link-local, unique-local, multicast and documentation space.
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return false
        }
        return true
    }
}

/// Live/session traffic counters shared between extension and app (no secrets).
struct TunnelStatistics: Codable, Equatable {
    /// Cumulative download since install — never cleared on disconnect/reconnect.
    var bytesDown: UInt64 = 0
    /// Cumulative upload since install — never cleared on disconnect/reconnect.
    var bytesUp: UInt64 = 0
    var downloadSpeedBps: UInt64 = 0
    var uploadSpeedBps: UInt64 = 0
    var connectedAt: Date?
    var lastPublicIP: String = ""
    var selectedRegion: String = ""
    /// Psiphon egress region code/name when tunnel is up.
    var connectedServerRegion: String = ""
    /// Established tunnel protocol from Psiphon `ConnectedServer` notice (e.g. TLS-OSSH).
    var connectedTunnelProtocol: String = ""
    /// Latest Conduit / in-proxy attempt line (Shiro dashboard parity).
    var conduitStatusLine: String = ""
    var conduitStatusHistory: [String] = []
    var conduitStatusUpdatedAt: Date?
    var connectedCity: String = ""
    var connectedCountry: String = ""
    /// Legacy local SOCKS TCP relay sessions (packet-mode traffic is counted by Psiphon).
    var tcpRelaySessions: UInt64 = 0
    /// True when connected in Proxy Only mode (no full-device routing).
    var proxyOnlyModeActive: Bool = false

    var sessionDuration: TimeInterval {
        guard let connectedAt else { return 0 }
        return Date().timeIntervalSince(connectedAt)
    }

    var egressLocationSubtitle: String {
        let city = connectedCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = connectedCountry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty, !country.isEmpty { return "\(city), \(country)" }
        if !country.isEmpty { return country }
        if !city.isEmpty { return city }
        let region = connectedServerRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !region.isEmpty {
            return RegionDisplayNames.countryName(for: region)
        }
        return ""
    }
}

enum TunnelStatisticsStore {
    private static let key = "tunnel_statistics_json"

    static func load() -> TunnelStatistics {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName),
              let data = defaults.data(forKey: key),
              let stats = try? JSONDecoder().decode(TunnelStatistics.self, from: data) else {
            return TunnelStatistics()
        }
        return stats
    }

    static func save(_ stats: TunnelStatistics) {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName),
              let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }

    /// New VPN session: reset speeds/timer only — keep lifetime byte totals.
    static func resetSession() {
        var s = load()
        s.connectedAt = nil
        s.downloadSpeedBps = 0
        s.uploadSpeedBps = 0
        s.tcpRelaySessions = 0
        s.connectedServerRegion = ""
        s.connectedCity = ""
        s.connectedCountry = ""
        s.connectedTunnelProtocol = ""
        s.lastPublicIP = ""
        clearConduitStatus(on: &s)
        save(s)
    }

    /// Authoritative totals from Psiphon (all apps: HTTP proxy, SOCKS, speed tests, etc.).
    static func recordTransferred(sent: Int64, received: Int64) {
        guard sent > 0 || received > 0 else { return }
        var s = load()
        if received > 0 { s.bytesDown &+= UInt64(received) }
        if sent > 0 { s.bytesUp &+= UInt64(sent) }
        save(s)
    }

    static func recordPacketBytes(down: Int, up: Int) {
        // Legacy path — prefer recordTransferred from Psiphon when EmitBytesTransferred is on.
    }

    static func recordTcpRelaySession() {
        var s = load()
        s.tcpRelaySessions &+= 1
        save(s)
        if s.tcpRelaySessions == 1 || s.tcpRelaySessions % 25 == 0 {
            SharedLogger.shared.log(.tcpRelayOk, detail: "sessions=\(s.tcpRelaySessions)")
        }
    }

    static func updateSpeeds(downloadBps: UInt64, uploadBps: UInt64) {
        var s = load()
        s.downloadSpeedBps = downloadBps
        s.uploadSpeedBps = uploadBps
        save(s)
    }

    static func markConnected(region: String, proxyOnly: Bool = false) {
        var s = load()
        s.connectedAt = Date()
        s.selectedRegion = region
        s.proxyOnlyModeActive = proxyOnly
        save(s)
    }

    static func markDisconnected() {
        var s = load()
        s.connectedAt = nil
        s.downloadSpeedBps = 0
        s.uploadSpeedBps = 0
        s.connectedTunnelProtocol = ""
        s.proxyOnlyModeActive = false
        clearConduitStatus(on: &s)
        save(s)
    }

    static func clearConduitStatus() {
        var s = load()
        clearConduitStatus(on: &s)
        save(s)
    }

    static func setConduitStatusLine(_ message: String) {
        guard let line = ConduitStatusParser.parseDashboardLine(from: message) else { return }
        var s = load()
        if ConduitStatusParser.appendHistory(line, to: &s) {
            save(s)
            SharedLogger.shared.logRaw("CONDUIT_STATUS", detail: line)
        }
    }

    static func seedConduitConnecting(missingDistributorKeys: Bool = false) {
        var s = load()
        let seed = missingDistributorKeys
            ? PsiphonDistributorKeys.conduitBlockedStatusLine
            : "Starting Conduit relays…"
        if s.conduitStatusLine.isEmpty || missingDistributorKeys {
            s.conduitStatusLine = seed
            s.conduitStatusUpdatedAt = Date()
            save(s)
            SharedLogger.shared.logRaw("CONDUIT_STATUS", detail: seed)
        }
    }

    private static func clearConduitStatus(on stats: inout TunnelStatistics) {
        stats.conduitStatusLine = ""
        stats.conduitStatusHistory = []
        stats.conduitStatusUpdatedAt = nil
    }

    static func setConnectedTunnelProtocol(_ rawProtocol: String) {
        let trimmed = rawProtocol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s = load()
        s.connectedTunnelProtocol = trimmed
        save(s)
    }

    static func connectedTunnelProtocolDisplayName() -> String {
        let raw = load().connectedTunnelProtocol
        guard !raw.isEmpty else { return "" }
        return ConnectedTunnelProtocolParser.displayName(for: raw)
    }

    static func setPublicIP(_ ip: String) {
        var s = load()
        s.lastPublicIP = ip
        save(s)
    }

    static func clearPublicIP() {
        var s = load()
        s.lastPublicIP = ""
        save(s)
    }

    static func setConnectedServerRegion(_ region: String) {
        var s = load()
        s.connectedServerRegion = region
        let name = RegionDisplayNames.countryName(for: region)
        if s.connectedCountry.isEmpty, !name.isEmpty {
            s.connectedCountry = name
        }
        save(s)
    }

    static func setEgressGeo(city: String, country: String) {
        var s = load()
        if !city.isEmpty { s.connectedCity = city }
        if !country.isEmpty { s.connectedCountry = country }
        save(s)
    }
}
