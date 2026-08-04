import Foundation

/// Focused, dependency-free regression checks for the IPv6 capability boundary.
/// Run with `Scripts/run-ipv6-routing-tests.sh`.
@main
struct IPv6RoutingPolicyTests {
    static func main() {
        testCapabilityOnAndOff()
        testLegacyEngineMigrationDefaultsToIPv4Only()
        testRouteConstructionAndNoBlackhole()
        testAAAAIsSuppressedForEveryDomainWhenIPv6IsUnavailable()
        testLiteralGlobalIPv6CannotEscapeUnsupportedPath()
        testICMPv6ErrorsAndMulticastAreNotReflected()
        print("IPv6 routing policy tests passed")
    }

    private static func testCapabilityOnAndOff() {
        let off = PacketEngineRoutePlan.fullTunnel(for: .ipv4Only)
        let on = PacketEngineRoutePlan.fullTunnel(for: .ipv4AndIPv6)

        precondition(!off.forwardsIPv6Packets)
        precondition(off.suppressesAAAA)
        precondition(off.emitsIPv6Rejects)
        precondition(on.forwardsIPv6Packets)
        precondition(!on.suppressesAAAA)
        precondition(!on.emitsIPv6Rejects)
    }

    private static func testLegacyEngineMigrationDefaultsToIPv4Only() {
        let legacy = LegacyEngineMock()
        precondition(legacy.packetEngineCapabilities == .ipv4Only)

        let engine = PsiphonTunnelEngine(core: legacy)
        precondition(engine.packetEngineCapabilities == .ipv4Only)
    }

    private static func testRouteConstructionAndNoBlackhole() {
        let off = PacketEngineRoutePlan.fullTunnel(for: .ipv4Only)
        let on = PacketEngineRoutePlan.fullTunnel(for: .ipv4AndIPv6)

        precondition(off.installsIPv4DefaultRoute)
        precondition(off.installsIPv6CaptureRoute)
        precondition(!off.installsIPv6DefaultRoute)
        precondition(off.failsClosedForIPv6)
        precondition(!off.isBlackhole)

        precondition(on.installsIPv4DefaultRoute)
        precondition(on.installsIPv6CaptureRoute)
        precondition(on.installsIPv6DefaultRoute)
        precondition(!on.isBlackhole)
    }

    private static func testAAAAIsSuppressedForEveryDomainWhenIPv6IsUnavailable() {
        let off = PacketEngineRoutePlan.fullTunnel(for: .ipv4Only)
        let on = PacketEngineRoutePlan.fullTunnel(for: .ipv4AndIPv6)
        let domains = ["example.com", "telegram.org", "g.whatsapp.net", "literal.example"]

        for domain in domains {
            precondition(off.shouldSuppressAAAA(qtype: 28), "AAAA escaped for \(domain)")
            precondition(!on.shouldSuppressAAAA(qtype: 28), "AAAA suppressed for \(domain) with relay")
            precondition(!off.shouldSuppressAAAA(qtype: 1), "A suppressed for \(domain)")
        }
    }

    private static func testLiteralGlobalIPv6CannotEscapeUnsupportedPath() {
        let policy = PacketEngineRoutePlan.fullTunnel(for: .ipv4Only)
        precondition(policy.installsIPv6CaptureRoute)
        precondition(!policy.forwardsIPv6Packets)
        precondition(policy.emitsIPv6Rejects)

        let packet = makeIPv6Packet(nextHeader: 6)
        guard let reject = IPv6PacketRejector.destinationUnreachable(for: packet) else {
            preconditionFailure("A normal captured IPv6 packet must receive a reject")
        }

        precondition(reject.count <= 1280)
        precondition(reject[0] >> 4 == 6)
        precondition(reject[6] == IPv6PacketRejector.icmpv6NextHeader)
        precondition(reject[40] == IPv6PacketRejector.destinationUnreachableType)
        precondition(reject[41] == IPv6PacketRejector.administrativelyProhibitedCode)
        precondition(Data(reject[8..<24]) == IPv6PacketRejector.tunnelAddress)
        precondition(Data(reject[24..<40]) == Data(packet[8..<24]))
        precondition(Data(reject[48...]) == packet)

        let payloadLength = Int(reject[4]) << 8 | Int(reject[5])
        precondition(payloadLength == reject.count - 40)
        precondition(internetChecksum(pseudoHeaderAndICMP(from: reject)) == 0)
    }

    private static func testICMPv6ErrorsAndMulticastAreNotReflected() {
        precondition(IPv6PacketRejector.destinationUnreachable(for: makeIPv6Packet(nextHeader: 58, icmpType: 1)) == nil)

        var multicast = makeIPv6Packet(nextHeader: 6)
        multicast[8] = 0xff
        precondition(IPv6PacketRejector.destinationUnreachable(for: multicast) == nil)

        var multicastDestination = makeIPv6Packet(nextHeader: 6)
        multicastDestination[24] = 0xff
        precondition(IPv6PacketRejector.destinationUnreachable(for: multicastDestination) == nil)

        var extendedICMPError = makeIPv6Packet(nextHeader: 0)
        extendedICMPError[40] = 58 // ICMPv6 follows the eight-byte Hop-by-Hop header.
        extendedICMPError[41] = 0
        extendedICMPError[48] = 1
        precondition(IPv6PacketRejector.destinationUnreachable(for: extendedICMPError) == nil)
    }

    private static func makeIPv6Packet(nextHeader: UInt8, icmpType: UInt8? = nil) -> Data {
        var packet = Data(repeating: 0, count: 60)
        packet[0] = 0x60
        packet[4] = 0
        packet[5] = 20
        packet[6] = nextHeader
        packet[7] = 64
        packet.replaceSubrange(
            8..<24,
            with: Data([
                0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 1
            ])
        )
        packet.replaceSubrange(
            24..<40,
            with: Data([
                0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 2
            ])
        )
        if let icmpType {
            packet[40] = icmpType
        }
        for index in 40..<60 {
            if packet[index] == 0 { packet[index] = UInt8(index) }
        }
        return packet
    }

    private static func pseudoHeaderAndICMP(from packet: Data) -> Data {
        let payloadLength = UInt32(Int(packet[4]) << 8 | Int(packet[5]))
        var input = Data(packet[8..<40])
        input.append(UInt8((payloadLength >> 24) & 0xff))
        input.append(UInt8((payloadLength >> 16) & 0xff))
        input.append(UInt8((payloadLength >> 8) & 0xff))
        input.append(UInt8(payloadLength & 0xff))
        input.append(contentsOf: [0, 0, 0, IPv6PacketRejector.icmpv6NextHeader])
        input.append(packet[40...])
        return input
    }

    private static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            sum += (UInt32(data[index]) << 8) | UInt32(data[index + 1])
            sum = (sum & 0xffff) + (sum >> 16)
            index += 2
        }
        if index < data.count { sum += UInt32(data[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
}

private final class LegacyEngineMock: PsiphonTunnelCoreProtocol, @unchecked Sendable {
    var onLocalProxyEndpointsChanged: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)?
    var isRunning: Bool { false }
    var localProxyHost: String { "127.0.0.1" }
    var localProxyPort: Int { 0 }
    var localProxyType: PsiphonLocalProxyType { .unknown }
    var localProxyEndpoints: PsiphonLocalProxyEndpoints {
        PsiphonLocalProxyEndpoints(host: localProxyHost, socksPort: 0, httpPort: 0)
    }
    var lastError: String? { nil }

    func start(
        configJSON: String,
        serverEntriesPath: String?,
        dataDir: URL,
        packetTunnel: PsiphonPacketTunnelIO?
    ) async throws {}
    func stop() async {}
}
