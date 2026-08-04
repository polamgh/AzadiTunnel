import Foundation
import XCTest
@testable import AzadiTunnel

final class TunnelDNSResponsePacketTests: XCTestCase {
    func testIPv4UDPResponseHeaderAndPayload() throws {
        let dnsPayload = Data([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0])
        let packet = try XCTUnwrap(IPv4UDPResponsePacketBuilder.build(
            ipHeaderLength: 20,
            sourceIP: [10, 0, 0, 2],
            destinationIP: [10, 0, 0, 1],
            sourcePort: 53_000,
            destinationPort: 53,
            payload: dnsPayload
        ))

        XCTAssertEqual(packet[0], 0x45)
        XCTAssertEqual(readUInt16(packet, at: 2), UInt16(packet.count))
        XCTAssertEqual(packet[8], 64, "IPv4 TTL must be written at byte 8")
        XCTAssertEqual(packet[9], 17, "IPv4 protocol must identify UDP at byte 9")
        XCTAssertEqual(Array(packet[12..<16]), [10, 0, 0, 1])
        XCTAssertEqual(Array(packet[16..<20]), [10, 0, 0, 2])
        XCTAssertEqual(readUInt16(packet, at: 20), 53)
        XCTAssertEqual(readUInt16(packet, at: 22), 53_000)
        XCTAssertEqual(readUInt16(packet, at: 24), UInt16(8 + dnsPayload.count))
        XCTAssertEqual(packet.subdata(in: 28..<packet.count), dnsPayload)
        XCTAssertEqual(
            IPv4UDPResponsePacketBuilder.internetChecksum(data: packet, offset: 0, length: 20),
            0,
            "IPv4 header checksum must validate"
        )
    }

    func testInvalidHeaderShapeFailsClosed() {
        XCTAssertNil(IPv4UDPResponsePacketBuilder.build(
            ipHeaderLength: 19,
            sourceIP: [10, 0, 0, 2],
            destinationIP: [10, 0, 0, 1],
            sourcePort: 53_000,
            destinationPort: 53,
            payload: Data([0])
        ))
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
}
