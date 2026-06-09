import Foundation
import Network
import NetworkExtension

#if canImport(tun2socks)
import tun2socks
#endif

/// Forwards packets from `NEPacketTunnelFlow` through Psiphon's local proxy.
/// SOCKS: tun2socks (TCP). HTTP: tunnel proxy settings + packet pump.
final class PacketTunnelTrafficForwarder {
    private static var tunTcpSeen = 0
    private static var udpDropLogged = Set<String>()
    private static var ipv6DropLogged = 0

    private let packetFlow: NEPacketTunnelFlow
    private let socksHost: String
    private let socksPort: Int
    private let httpPort: Int
    private let proxyType: PsiphonLocalProxyType
    private var cancelled = false

#if canImport(tun2socks)
    private var stackReady = false
    /// Must outlive TSIPStack — its `delegate` is weak.
    private var socksStackDelegate: SocksTun2SocksDelegate?
#endif

    init(
        packetFlow: NEPacketTunnelFlow,
        socksHost: String,
        socksPort: Int,
        httpPort: Int,
        proxyType: PsiphonLocalProxyType
    ) {
        self.packetFlow = packetFlow
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.proxyType = proxyType
    }

    func start() throws {
        switch proxyType {
        case .socks, .dual:
            try startSocksForwarding()
        case .http:
            startHttpPump()
        case .unknown:
            throw PsiphonTunnelCoreError.proxyNotReady
        }
    }

    func stop() {
        cancelled = true
#if canImport(tun2socks)
        socksStackDelegate = nil
        TSIPStack.stack.processQueue.sync {
            TSIPStack.stack.suspendTimer()
            TSIPStack.stack.delegate = nil
        }
#endif
    }

    private func startHttpPump() {
        scheduleReadLoop { _, _ in }
    }

    private func startSocksForwarding() throws {
#if canImport(tun2socks)
        let stack = TSIPStack.stack
        stack.processQueue.sync {
            stack.outputBlock = { [weak self] packets, protocols in
                guard let self, !self.cancelled else { return }
                let up = packets.reduce(0) { $0 + $1.count }
                if up > 0 {
                    TunnelStatisticsStore.recordPacketBytes(down: 0, up: up)
                }
                self.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            let delegate = SocksTun2SocksDelegate(
                socksHost: self.socksHost,
                socksPort: self.socksPort,
                httpPort: self.httpPort
            )
            self.socksStackDelegate = delegate
            stack.delegate = delegate
            stack.resumeTimer()
            self.stackReady = true
            SharedLogger.shared.logRaw(
                "TUN2SOCKS_READY",
                detail: "delegate=\(stack.delegate != nil)"
            )
        }
        scheduleReadLoop { packets, _ in
            TSIPStack.stack.processQueue.async {
                for packet in packets {
                    TSIPStack.stack.received(packet: packet)
                }
            }
        }
#else
        throw PsiphonTunnelCoreError.startFailed("tun2socks package not linked; cannot forward SOCKS traffic")
#endif
    }

    private func scheduleReadLoop(handler: @escaping ([Data], [NSNumber]) -> Void) {
        guard !cancelled else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, !self.cancelled else { return }

            var tcpPackets: [Data] = []
            var tcpProtocols: [NSNumber] = []
            tcpPackets.reserveCapacity(packets.count)
            tcpProtocols.reserveCapacity(protocols.count)

            for (packet, proto) in zip(packets, protocols) {
                guard packet.count >= 1 else { continue }
                let version = packet[0] >> 4
                if version == 6 {
                    if Self.ipv6DropLogged < 8 {
                        Self.ipv6DropLogged += 1
                        if SharedSettingsStore.shared.appSettings.messagingAppsCompatibilityModeEnabled {
                            SharedLogger.shared.logRaw(
                                "IPV6_BLACKHOLED",
                                detail: "len=\(packet.count) reason=messaging_compat_no_relay"
                            )
                        }
                        MessagingAppsDiagnostics.logIpv6Dropped(length: packet.count)
                    }
                    continue
                }
                guard version == 4 else { continue }

                if packet.count >= 20, packet[9] == 17,
                   let udp = Self.udpEndpoints(packet), udp.dstPort != 53 {
                    let key = "\(udp.dstIP):\(udp.dstPort)"
                    if Self.udpDropLogged.insert(key).inserted {
                        MessagingAppsDiagnostics.logUdpDropped(
                            destIP: udp.dstIP,
                            destPort: udp.dstPort,
                            length: packet.count
                        )
                    }
                }

                if packet.count >= 20, packet[9] == 6 {
                    Self.tunTcpSeen += 1
                    if Self.tunTcpSeen <= 5 || Self.tunTcpSeen % 50 == 0 {
                        SharedLogger.shared.logRaw("TUN_TCP_PKT", detail: "n=\(Self.tunTcpSeen) len=\(packet.count)")
                    }
                    if SharedSettingsStore.shared.appSettings.secureDNSMode == .doh,
                       let ports = Self.tcpPorts(packet),
                       ports.dst == 53 || ports.src == 53 {
                        SharedLogger.shared.logRaw(
                            "SECURE_DNS_BYPASS_DETECTED",
                            detail: "reason=tcp_53_cleartext_blocked src_port=\(ports.src) dst_port=\(ports.dst) mode=doh"
                        )
                        continue
                    }
                }

                let down = packet.count
                if down > 0 {
                    TunnelStatisticsStore.recordPacketBytes(down: down, up: 0)
                }
                if TunnelDnsForwarder.handleIfDnsQuery(
                    packet: packet,
                    protocolNumber: proto,
                    packetFlow: self.packetFlow,
                    socksHost: self.socksHost,
                    socksPort: self.socksPort,
                    httpPort: self.httpPort
                ) {
                    continue
                }
                tcpPackets.append(packet)
                tcpProtocols.append(proto)
            }

            if !tcpPackets.isEmpty {
                handler(tcpPackets, tcpProtocols)
            }
            self.scheduleReadLoop(handler: handler)
        }
    }

    private static func tcpPorts(_ packet: Data) -> (src: UInt16, dst: UInt16)? {
        guard packet.count >= 20, packet[0] >> 4 == 4, packet[9] == 6 else { return nil }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard packet.count >= ihl + 4 else { return nil }
        let src = UInt16(packet[ihl]) << 8 | UInt16(packet[ihl + 1])
        let dst = UInt16(packet[ihl + 2]) << 8 | UInt16(packet[ihl + 3])
        return (src, dst)
    }

    private static func udpEndpoints(_ packet: Data) -> (dstIP: String, dstPort: UInt16)? {
        guard packet.count >= 20, packet[0] >> 4 == 4, packet[9] == 17 else { return nil }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard packet.count >= ihl + 4 else { return nil }
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        let dst = UInt16(packet[ihl + 2]) << 8 | UInt16(packet[ihl + 3])
        return (dstIP, dst)
    }
}

#if canImport(tun2socks)
private final class SocksTun2SocksDelegate: NSObject, TSIPStackDelegate {
    private let socksHost: String
    private let socksPort: Int
    private let httpPort: Int

    init(socksHost: String, socksPort: Int, httpPort: Int) {
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.httpPort = httpPort
    }

    func didAcceptTCPSocket(_ sock: TSTCPSocket) {
        guard SOCKS5RelayGate.tryAcquire() else {
            sock.reset()
            return
        }
        // lwIP pcb: local_ip:local_port is the internet peer; remote_ip is the TUN client.
        var peer = sock.destinationAddress
        let peerPort = sock.destinationPort
        let peerIP = String(cString: inet_ntoa(peer))
        switch MessagingAppsConfiguration.messagingApp(host: peerIP, port: peerPort) {
        case .telegram:
            SharedLogger.shared.logRaw("TUN_SOCKS_ACCEPT", detail: "telegram=\(peerIP):\(peerPort)")
        case .whatsapp:
            SharedLogger.shared.logRaw("TUN_SOCKS_ACCEPT", detail: "whatsapp=\(peerIP):\(peerPort)")
        case .messaging, .other:
            break
        }
        TcpRelayDiagnostics.logTunAccept(host: peerIP, port: peerPort)
        let session = SOCKS5TunnelSession(
            tcpSocket: sock,
            proxyHost: socksHost,
            proxyPort: socksPort,
            httpPort: httpPort,
            destination: peer,
            destinationPort: peerPort
        )
        sock.delegate = session
        session.start()
    }
}
#endif
