import Foundation

/// Builds an ICMPv6 Destination Unreachable response for an IPv6 packet captured by the tunnel.
///
/// This is used only when the selected packet engine cannot relay IPv6. The packet is captured by
/// Network Extension, rejected immediately, and never sent to the physical interface or an
/// IPv4-only proxy. Error packets, multicast traffic, and unspecified sources are not answered as
/// required by ICMPv6 error-message rules.
enum IPv6PacketRejector {
    static let icmpv6NextHeader: UInt8 = 58
    static let destinationUnreachableType: UInt8 = 1
    static let administrativelyProhibitedCode: UInt8 = 1
    static let tunnelAddress = Data([
        0xfd, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02
    ])
    private static let ipv6HeaderLength = 40
    private static let icmpv6HeaderLength = 8
    private static let minimumIPv6MTU = 1280

    /// Returns a complete IPv6 packet or nil when an ICMPv6 error must not trigger another error.
    static func destinationUnreachable(for packet: Data) -> Data? {
        guard packet.count >= ipv6HeaderLength,
              packet[0] >> 4 == 6 else {
            return nil
        }

        let source = packet.subdata(in: 8..<24)
        let destination = packet.subdata(in: 24..<40)
        guard !isUnspecified(source), !isMulticast(source),
              !isUnspecified(destination), !isMulticast(destination) else {
            return nil
        }

        // ICMPv6 error messages have types 0...127. Never answer an error with another error.
        if let icmpType = icmpv6Type(in: packet), icmpType < 128 {
            return nil
        }

        let maxQuoteLength = minimumIPv6MTU - ipv6HeaderLength - icmpv6HeaderLength
        let quote = packet.prefix(maxQuoteLength)
        let payloadLength = icmpv6HeaderLength + quote.count
        var response = Data(repeating: 0, count: ipv6HeaderLength + payloadLength)

        response[0] = 0x60
        response[4] = UInt8((payloadLength >> 8) & 0xff)
        response[5] = UInt8(payloadLength & 0xff)
        response[6] = icmpv6NextHeader
        response[7] = 64
        response.replaceSubrange(8..<24, with: tunnelAddress)
        response.replaceSubrange(24..<40, with: source)

        let icmpOffset = ipv6HeaderLength
        response[icmpOffset] = destinationUnreachableType
        response[icmpOffset + 1] = administrativelyProhibitedCode
        response.replaceSubrange(
            (icmpOffset + 8)..<(icmpOffset + 8 + quote.count),
            with: quote
        )

        var checksumInput = Data()
        checksumInput.append(tunnelAddress)
        checksumInput.append(source)
        appendUInt32(UInt32(payloadLength), to: &checksumInput)
        checksumInput.append(contentsOf: [0, 0, 0, icmpv6NextHeader])
        checksumInput.append(response.subdata(in: icmpOffset..<(icmpOffset + payloadLength)))
        let checksum = internetChecksum(checksumInput)
        response[icmpOffset + 2] = UInt8(checksum >> 8)
        response[icmpOffset + 3] = UInt8(checksum & 0xff)

        return response
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func isUnspecified(_ address: Data) -> Bool {
        address.allSatisfy { $0 == 0 }
    }

    private static func isMulticast(_ address: Data) -> Bool {
        address.first == 0xff
    }

    private static func icmpv6Type(in packet: Data) -> UInt8? {
        var nextHeader = packet[6]
        var offset = ipv6HeaderLength

        // Walk the bounded set of IPv6 extension headers that can precede ICMPv6. If the
        // payload is encrypted or malformed, return nil and let the packet be rejected.
        for _ in 0..<8 {
            switch nextHeader {
            case icmpv6NextHeader:
                return offset < packet.count ? packet[offset] : nil
            case 0, 43, 60: // Hop-by-Hop, Routing, Destination Options.
                guard offset + 2 <= packet.count else { return nil }
                nextHeader = packet[offset]
                offset += (Int(packet[offset + 1]) + 1) * 8
            case 44: // Fragment.
                guard offset + 8 <= packet.count else { return nil }
                nextHeader = packet[offset]
                offset += 8
            case 51: // Authentication Header.
                guard offset + 2 <= packet.count else { return nil }
                nextHeader = packet[offset]
                offset += (Int(packet[offset + 1]) + 2) * 4
            default:
                return nil
            }
            guard offset <= packet.count else { return nil }
        }
        return nil
    }

    private static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var offset = 0
        while offset + 1 < data.count {
            sum += (UInt32(data[offset]) << 8) | UInt32(data[offset + 1])
            sum = (sum & 0xffff) + (sum >> 16)
            offset += 2
        }
        if offset < data.count {
            sum += UInt32(data[offset]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum & 0xffff)
    }
}
