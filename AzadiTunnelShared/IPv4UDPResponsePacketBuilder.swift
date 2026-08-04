import Foundation

/// Builds an IPv4 UDP response for a packet captured from `NEPacketTunnelFlow`.
/// UDP checksum zero is valid for IPv4; the IPv4 header checksum is always set.
enum IPv4UDPResponsePacketBuilder {
    static func build(
        ipHeaderLength: Int,
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) -> Data? {
        guard ipHeaderLength >= 20,
              ipHeaderLength.isMultiple(of: 4),
              ipHeaderLength <= 60,
              sourceIP.count == 4,
              destinationIP.count == 4 else {
            return nil
        }

        let udpLength = 8 + payload.count
        let packetLength = ipHeaderLength + udpLength
        guard udpLength <= Int(UInt16.max), packetLength <= Int(UInt16.max) else {
            return nil
        }

        var packet = Data(count: packetLength)
        packet[0] = 0x40 | UInt8(ipHeaderLength / 4)
        let totalLength = UInt16(packetLength)
        packet[2] = UInt8(totalLength >> 8)
        packet[3] = UInt8(totalLength & 0xff)
        packet[8] = 64
        packet[9] = 17

        packet[12] = destinationIP[0]
        packet[13] = destinationIP[1]
        packet[14] = destinationIP[2]
        packet[15] = destinationIP[3]
        packet[16] = sourceIP[0]
        packet[17] = sourceIP[1]
        packet[18] = sourceIP[2]
        packet[19] = sourceIP[3]

        let udpOffset = ipHeaderLength
        packet[udpOffset] = UInt8(destinationPort >> 8)
        packet[udpOffset + 1] = UInt8(destinationPort & 0xff)
        packet[udpOffset + 2] = UInt8(sourcePort >> 8)
        packet[udpOffset + 3] = UInt8(sourcePort & 0xff)
        packet[udpOffset + 4] = UInt8(UInt16(udpLength) >> 8)
        packet[udpOffset + 5] = UInt8(UInt16(udpLength) & 0xff)
        packet.replaceSubrange((udpOffset + 8)..<packet.endIndex, with: payload)

        let checksum = internetChecksum(data: packet, offset: 0, length: ipHeaderLength)
        packet[10] = UInt8(checksum >> 8)
        packet[11] = UInt8(checksum & 0xff)
        return packet
    }

    static func internetChecksum(data: Data, offset: Int, length: Int) -> UInt16 {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            return UInt16.max
        }
        var sum: UInt32 = 0
        var index = offset
        let end = offset + length
        while index + 1 < end {
            sum += UInt32(data[index]) << 8 | UInt32(data[index + 1])
            index += 2
        }
        if index < end { sum += UInt32(data[index]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
}
