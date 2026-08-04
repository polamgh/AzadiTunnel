import Darwin
import Foundation

/// The packet families handled by the native Psiphon packet transport.
enum PsiphonPacketTunnelPacketKind: Equatable, Sendable {
    case ipv4TCP
    case ipv4UDP
    case ipv4Other
    case ipv6TCP
    case ipv6UDP
    case ipv6Other
}

/// Small, dependency-free packet checks shared by the flow bridge and tests.
/// The native core performs the complete IP/TCP/UDP validation; these checks
/// only prevent the callback boundary from accepting malformed or unknown IP
/// packets and from silently guessing an address family.
enum PsiphonPacketTunnelCapabilities {
    static let supportsTCP = true
    static let supportsUDP = true
    static let supportsIPv4 = true
    static let supportsIPv6 = true

    /// Full packet mode is ready only when the callback, Psiphon's special
    /// packet transport channel, and the SOCKS listener used by mandatory
    /// in-tunnel DoH are all live.
    static func isReadyForStart(
        packetMode: Bool,
        hasPacketProvider: Bool,
        packetTransportReady: Bool,
        hasSocks: Bool,
        coreConnected: Bool
    ) -> Bool {
        guard coreConnected, hasSocks else { return false }
        if packetMode {
            return hasPacketProvider && packetTransportReady
        }
        return true
    }

    static func kind(of packet: Data) -> PsiphonPacketTunnelPacketKind? {
        guard let version = packet.first.map({ $0 >> 4 }) else { return nil }
        switch version {
        case 4:
            let headerLength = Int(packet[0] & 0x0f) * 4
            guard headerLength >= 20, packet.count >= headerLength else { return nil }
            switch packet[9] {
            case 6: return .ipv4TCP
            case 17: return .ipv4UDP
            default: return .ipv4Other
            }
        case 6:
            guard packet.count >= 40 else { return nil }
            switch packet[6] {
            case 6: return .ipv6TCP
            case 17: return .ipv6UDP
            default: return .ipv6Other
            }
        default:
            return nil
        }
    }

    static func protocolNumber(for packet: Data) -> NSNumber? {
        guard let version = packet.first.map({ $0 >> 4 }) else { return nil }
        switch version {
        case 4:
            let headerLength = Int(packet[0] & 0x0f) * 4
            guard headerLength >= 20, packet.count >= headerLength else { return nil }
            return NSNumber(value: AF_INET)
        case 6 where packet.count >= 40:
            return NSNumber(value: AF_INET6)
        default:
            return nil
        }
    }
}
