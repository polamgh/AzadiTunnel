import Foundation

#if canImport(tun2socks)
import tun2socks

/// Injects a TCP SYN into the tun2socks stack to verify the TUN → SOCKS path (not just extension-local SOCKS).
enum TunnelStackProbe {
    static func runAfterForwardingStarted() {
        TSIPStack.stack.processQueue.asyncAfter(deadline: .now() + 2) {
            let before = TunnelStatisticsStore.load().tcpRelaySessions
            injectTcpSyn(dst: (142, 250, 80, 78), dstPort: 80)
            injectTcpSyn(dst: (142, 250, 80, 46), dstPort: 80)
            TSIPStack.stack.processQueue.asyncAfter(deadline: .now() + 8) {
                let after = TunnelStatisticsStore.load().tcpRelaySessions
                if after > before {
                    SharedLogger.shared.logRaw("TUN_STACK_PROBE", detail: "ok sessions=\(after - before)")
                } else {
                    SharedLogger.shared.logRaw("TUN_STACK_PROBE", detail: "fail sessions=\(after)")
                }
            }
        }
    }

    private static func injectTcpSyn(dst: (UInt8, UInt8, UInt8, UInt8), dstPort: UInt16) {
        let packet = buildIPv4TcpSynPacket(
            src: (10, 0, 0, 2),
            dst: dst,
            srcPort: UInt16(40_000 + Int.random(in: 0..<20_000)),
            dstPort: dstPort
        )
        TSIPStack.stack.received(packet: packet)
    }

    private static func buildIPv4TcpSynPacket(
        src: (UInt8, UInt8, UInt8, UInt8),
        dst: (UInt8, UInt8, UInt8, UInt8),
        srcPort: UInt16,
        dstPort: UInt16
    ) -> Data {
        var ip = Data(count: 20)
        ip[0] = 0x45
        ip[1] = 0
        let totalLen: UInt16 = 40
        ip[2] = UInt8(totalLen >> 8)
        ip[3] = UInt8(totalLen & 0xff)
        ip[4] = 64
        ip[5] = 0
        ip[6] = 0
        ip[7] = 0
        ip[8] = 64
        ip[9] = 6
        ip[10] = 0
        ip[11] = 0
        ip[12] = src.0
        ip[13] = src.1
        ip[14] = src.2
        ip[15] = src.3
        ip[16] = dst.0
        ip[17] = dst.1
        ip[18] = dst.2
        ip[19] = dst.3
        let ipSum = internetChecksum(data: ip, offset: 0, length: 20)
        ip[10] = UInt8(ipSum >> 8)
        ip[11] = UInt8(ipSum & 0xff)

        var tcp = Data(count: 20)
        tcp[0] = UInt8(srcPort >> 8)
        tcp[1] = UInt8(srcPort & 0xff)
        tcp[2] = UInt8(dstPort >> 8)
        tcp[3] = UInt8(dstPort & 0xff)
        tcp[4] = 0
        tcp[5] = 0
        tcp[6] = 0
        tcp[7] = 0
        tcp[8] = 0
        tcp[9] = 0
        tcp[10] = 0
        tcp[11] = 0
        tcp[12] = 0x50
        tcp[13] = 0x02
        tcp[14] = 0xff
        tcp[15] = 0xff
        let tcpSum = tcpChecksum(
            src: src,
            dst: dst,
            tcpSegment: tcp
        )
        tcp[16] = UInt8(tcpSum >> 8)
        tcp[17] = UInt8(tcpSum & 0xff)

        var packet = Data()
        packet.append(ip)
        packet.append(tcp)
        return packet
    }

    private static func internetChecksum(data: Data, offset: Int, length: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = offset
        let end = offset + length
        while i + 1 < end {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < end { sum += UInt32(data[i]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    private static func tcpChecksum(
        src: (UInt8, UInt8, UInt8, UInt8),
        dst: (UInt8, UInt8, UInt8, UInt8),
        tcpSegment: Data
    ) -> UInt16 {
        var pseudo = Data()
        pseudo.append(contentsOf: [src.0, src.1, src.2, src.3, dst.0, dst.1, dst.2, dst.3, 0, 6])
        let len = UInt16(tcpSegment.count)
        pseudo.append(UInt8(len >> 8))
        pseudo.append(UInt8(len & 0xff))
        pseudo.append(tcpSegment)
        return internetChecksum(data: pseudo, offset: 0, length: pseudo.count)
    }
}
#endif
