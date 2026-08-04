import Foundation

/// The IP families a packet engine can relay all the way from the TUN interface to the
/// configured upstream tunnel. This is deliberately a runtime capability, not a user setting.
enum PacketEngineIPv6Support: String, Equatable, Sendable {
    case unavailable
    case endToEnd
}

/// Capabilities of the active packet engine. Keeping this explicit prevents a Network Extension
/// route from claiming IPv6 support merely because an IPv6 interface exists.
struct PacketEngineCapabilities: Equatable, Sendable {
    let ipv6: PacketEngineIPv6Support

    init(ipv6: PacketEngineIPv6Support = .unavailable) {
        self.ipv6 = ipv6
    }

    /// Safe default for engines created before the capability API existed.
    static let ipv4Only = PacketEngineCapabilities(ipv6: .unavailable)

    /// Capability value a fully dual-stack packet engine must advertise.
    static let ipv4AndIPv6 = PacketEngineCapabilities(ipv6: .endToEnd)

    var relaysIPv6EndToEnd: Bool {
        ipv6 == .endToEnd
    }

    var logValue: String {
        relaysIPv6EndToEnd ? "ipv4_ipv6" : "ipv4_only"
    }
}

/// Pure policy used by route construction, packet forwarding, and DNS interception.
///
/// When IPv6 is unavailable, the fail-closed actions are intentionally local and immediate:
/// capture IPv6 in the extension, do not send it to an IPv4-only engine, return an ICMPv6
/// administratively-prohibited response, and return an empty AAAA answer. A capture route that
/// emits an explicit rejection is materially different from silently installing a blackhole.
struct PacketEngineRoutePlan: Equatable, Sendable {
    let installsIPv4DefaultRoute: Bool
    /// Captures IPv6 in the packet extension so unsupported traffic cannot bypass the VPN.
    let installsIPv6CaptureRoute: Bool
    /// True only when the engine relays IPv6; false means captured packets are rejected locally.
    let installsIPv6DefaultRoute: Bool
    let forwardsIPv6Packets: Bool
    let suppressesAAAA: Bool
    let emitsIPv6Rejects: Bool

    var dropsUnrelayedIPv6Packets: Bool {
        !forwardsIPv6Packets
    }

    /// The unsupported path fails closed at both packet and name-resolution boundaries.
    var failsClosedForIPv6: Bool {
        installsIPv6CaptureRoute && dropsUnrelayedIPv6Packets && emitsIPv6Rejects && suppressesAAAA
    }

    /// A capture route with an explicit ICMPv6 rejection is not a silent blackhole route.
    var isBlackhole: Bool {
        installsIPv6CaptureRoute && dropsUnrelayedIPv6Packets && !emitsIPv6Rejects
    }

    func shouldSuppressAAAA(qtype: UInt16) -> Bool {
        qtype == 28 && suppressesAAAA
    }

    static func fullTunnel(for capabilities: PacketEngineCapabilities) -> PacketEngineRoutePlan {
        let relaysIPv6 = capabilities.relaysIPv6EndToEnd
        return PacketEngineRoutePlan(
            installsIPv4DefaultRoute: true,
            installsIPv6CaptureRoute: true,
            installsIPv6DefaultRoute: relaysIPv6,
            forwardsIPv6Packets: relaysIPv6,
            suppressesAAAA: !relaysIPv6,
            emitsIPv6Rejects: !relaysIPv6
        )
    }
}

/// Capability boundary implemented by packet engines. A default keeps older engine adapters
/// safe during migration: an engine that does not opt in is treated as IPv4-only.
protocol PacketEngineCapabilityProviding: AnyObject {
    var packetEngineCapabilities: PacketEngineCapabilities { get }
}

extension PacketEngineCapabilityProviding {
    var packetEngineCapabilities: PacketEngineCapabilities {
        .ipv4Only
    }
}
