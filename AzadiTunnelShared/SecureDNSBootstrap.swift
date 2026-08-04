import Foundation

/// Explicit bootstrap plan for DoH. Every target is sent as a SOCKS address to Psiphon; the TLS
/// server name remains the original HTTPS hostname, so bootstrap IPs never weaken certificate/SNI
/// validation and no endpoint hostname is resolved by the device.
enum SecureDNSBootstrap {
    struct Target: Equatable, Sendable {
        let connectHost: String
        let tlsServerName: String
        let usesSystemResolver: Bool

        init(connectHost: String, tlsServerName: String) {
            self.connectHost = connectHost
            self.tlsServerName = tlsServerName
            self.usesSystemResolver = false
        }
    }

    static func targets(endpointHost: String, bootstrapIPs: [String]) -> [Target] {
        // Prefer a domain ATYP so Psiphon performs the lookup inside its established tunnel. Some
        // Psiphon builds reject public resolver literals; those are validated alternatives, not
        // the first attempt and never a reason to invoke the device resolver.
        var hosts = [endpointHost]
        hosts.append(contentsOf: bootstrapIPs)

        var seen = Set<String>()
        return hosts.compactMap { host in
            guard !host.isEmpty, seen.insert(host).inserted else { return nil }
            return Target(connectHost: host, tlsServerName: endpointHost)
        }
    }
}
