import Foundation

/// A single IPv4 destination expressed as a network address + subnet mask, ready to become an
/// `NEIPv4Route(destinationAddress:subnetMask:)` in the packet-tunnel extension.
///
/// Kept free of any `NetworkExtension` import so it can be unit-tested and reused from the app.
struct BypassRoute: Equatable, Hashable {
    /// Network address with host bits zeroed (e.g. `1.2.3.0` for `1.2.3.4/24`).
    let address: String
    /// Dotted subnet mask (e.g. `255.255.255.0`).
    let mask: String
    /// CIDR prefix length 0…32.
    let prefix: Int

    var cidr: String { "\(address)/\(prefix)" }
}

/// Parses user/remote CIDR + IP strings into normalized `BypassRoute` values.
enum BypassRoutes {
    /// Split a free-form blob (newline / comma / whitespace separated) into trimmed tokens.
    static func tokenize(_ blob: String) -> [String] {
        blob
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Parse a single `a.b.c.d` (→ /32) or `a.b.c.d/n` entry. Returns nil if malformed.
    static func parse(_ entry: String) -> BypassRoute? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let ipPart = String(parts[0])
        let prefix: Int
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...32).contains(p) else { return nil }
            prefix = p
        } else {
            prefix = 32
        }
        guard let octets = ipv4Octets(ipPart) else { return nil }

        let raw = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
        let maskValue: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = raw & maskValue

        return BypassRoute(
            address: dotted(network),
            mask: dotted(maskValue),
            prefix: prefix
        )
    }

    /// Parse and de-duplicate a list of entries, preserving order.
    static func parseList(_ entries: [String]) -> [BypassRoute] {
        var seen = Set<BypassRoute>()
        var result: [BypassRoute] = []
        for entry in entries {
            guard let route = parse(entry) else { continue }
            if seen.insert(route).inserted { result.append(route) }
        }
        return result
    }

    /// Convenience: tokenize a blob and parse it.
    static func parseBlob(_ blob: String) -> [BypassRoute] {
        parseList(tokenize(blob))
    }

    static func ipv4Octets(_ ip: String) -> [UInt8]? {
        let comps = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count == 4 else { return nil }
        var octets = [UInt8]()
        for c in comps {
            guard let v = Int(c), (0...255).contains(v) else { return nil }
            octets.append(UInt8(v))
        }
        return octets
    }

    static func isValidIPv4(_ ip: String) -> Bool {
        ipv4Octets(ip) != nil
    }

    /// True when `ip` falls inside `route` (network address + prefix).
    static func contains(ip: String, in route: BypassRoute) -> Bool {
        guard let octets = ipv4Octets(ip) else { return false }
        let addr = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
        guard let netOctets = ipv4Octets(route.address) else { return false }
        let network = UInt32(netOctets[0]) << 24 | UInt32(netOctets[1]) << 16 | UInt32(netOctets[2]) << 8 | UInt32(netOctets[3])
        let mask: UInt32 = route.prefix == 0 ? 0 : ~UInt32(0) << (32 - route.prefix)
        return (addr & mask) == (network & mask)
    }

    private static func dotted(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
