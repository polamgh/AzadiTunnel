import Darwin
import Foundation
import Network

#if canImport(tun2socks)
import tun2socks

/// Relays one lwIP TCP socket through SOCKS5 using the same client as DNS/HTTP probes.
final class SOCKS5TunnelSession: NSObject, TSTCPSocketDelegate {
    private let tcpSocket: TSTCPSocket
    private let proxyHost: String
    private let proxyPort: Int
    private let destHost: String
    private let destinationPort: UInt16
    private var upstream: NWConnection?
    private var pendingClientData: [Data] = []
    private var relayTask: Task<Void, Never>?

    init(tcpSocket: TSTCPSocket, proxyHost: String, proxyPort: Int, destination: in_addr, destinationPort: UInt16) {
        self.tcpSocket = tcpSocket
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.destinationPort = destinationPort
        var addr = destination
        self.destHost = String(cString: inet_ntoa(addr))
    }

    func start() {
        relayTask = Task {
            do {
                let conn = try await Socks5TCPClient.openConnection(
                    proxyHost: proxyHost,
                    proxyPort: proxyPort,
                    targetHost: destHost,
                    targetPort: destinationPort
                )
                upstream = conn
                TunnelStatisticsStore.recordTcpRelaySession()
                if destHost.hasPrefix("149.154.") || destHost.hasPrefix("91.108.") {
                    SharedLogger.shared.logRaw(
                        "TELEGRAM_RELAY_OK",
                        detail: "\(destHost):\(destinationPort)"
                    )
                }
                let backlog = pendingClientData
                pendingClientData = []
                for chunk in backlog {
                    try await Socks5TCPClient.relaySend(conn, data: chunk)
                    TunnelStatisticsStore.recordPacketBytes(down: 0, up: chunk.count)
                }
                await pumpFromProxy(conn)
            } catch {
                if let err = error as? Socks5TCPClient.Socks5Error,
                   case .connectRejected(let rep) = err {
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "tun_relay_socks rep=\(rep) dest=\(destHost):\(destinationPort)"
                    )
                } else {
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "tun_relay dest=\(destHost):\(destinationPort) err=\(error.localizedDescription)"
                    )
                }
                closeTunSocket()
            }
        }
    }

    private func pumpFromProxy(_ conn: NWConnection) async {
        while !Task.isCancelled {
            do {
                let chunk = try await Socks5TCPClient.relayReceive(conn, maxLength: 65535)
                guard !chunk.isEmpty else { continue }
                TunnelStatisticsStore.recordPacketBytes(down: chunk.count, up: 0)
                let payload = chunk
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    TSIPStack.stack.processQueue.async {
                        self.tcpSocket.writeData(payload)
                        cont.resume()
                    }
                }
            } catch {
                break
            }
        }
        upstream?.cancel()
        closeTunSocket()
    }

    func didReadData(_ data: Data, from: TSTCPSocket) {
        guard !data.isEmpty else { return }
        if let conn = upstream {
            let chunk = data
            Task {
                try? await Socks5TCPClient.relaySend(conn, data: chunk)
                TunnelStatisticsStore.recordPacketBytes(down: 0, up: chunk.count)
            }
        } else {
            pendingClientData.append(data)
        }
    }

    func didWriteData(_ length: Int, from: TSTCPSocket) {}
    func localDidClose(_ socket: TSTCPSocket) { teardown() }
    func socketDidReset(_ socket: TSTCPSocket) { teardown() }
    func socketDidAbort(_ socket: TSTCPSocket) { teardown() }
    func socketDidClose(_ socket: TSTCPSocket) { teardown() }

    private func teardown() {
        relayTask?.cancel()
        upstream?.cancel()
        upstream = nil
        SOCKS5RelayGate.release()
    }

    private func closeTunSocket() {
        TSIPStack.stack.processQueue.async {
            self.tcpSocket.close()
        }
        teardown()
    }
}

/// Limits parallel SOCKS handshakes so Psiphon local proxy is not flooded (Telegram opens many sockets).
enum SOCKS5RelayGate {
    private static let maxActive = 64
    private static var active = 0
    private static let lock = NSLock()

    static func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maxActive else { return false }
        active += 1
        return true
    }

    static func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

#endif
