import Darwin
import Foundation
import Network

#if canImport(tun2socks)
import tun2socks

/// Relays one lwIP TCP socket through SOCKS5 using the same client as DNS/HTTP probes.
final class SOCKS5TunnelSession: NSObject, TSTCPSocketDelegate {
    private let tcpSocket: TSTCPSocket
    private let proxyHost: String
    private let socksPort: Int
    private let httpPort: Int
    private let destHost: String
    private let destinationPort: UInt16
    private let diag: TcpRelayDiagnostics.SessionContext
    private var upstream: NWConnection?
    private var pendingClientData: [Data] = []
    private var relayTask: Task<Void, Never>?
    private var bytesUp = 0
    private var bytesDown = 0
    private var lastActivity = Date()
    private var idleWatchTask: Task<Void, Never>?
    private var socksConnectSucceeded = false
    private var receivedFirstByte = false
    private var closing = false
    private var closeLogged = false
    private var pendingCloseReason: String?

    init(
        tcpSocket: TSTCPSocket,
        proxyHost: String,
        proxyPort: Int,
        httpPort: Int,
        destination: in_addr,
        destinationPort: UInt16
    ) {
        self.tcpSocket = tcpSocket
        self.proxyHost = proxyHost
        self.socksPort = proxyPort
        self.httpPort = httpPort
        self.destinationPort = destinationPort
        var addr = destination
        self.destHost = String(cString: inet_ntoa(addr))
        self.diag = TcpRelayDiagnostics.SessionContext(destHost: destHost, destPort: destinationPort)
    }

    func start() {
        diag.log("TCP_RELAY_SESSION_START", detail: "stage=tun_accepted")
        relayTask = Task {
            do {
                let timeouts = MessagingAppsConfiguration.socksRelayTimeouts(for: destHost, port: destinationPort)
                let conn = try await Socks5TCPClient.openConnection(
                    proxyHost: proxyHost,
                    proxyPort: socksPort,
                    targetHost: destHost,
                    targetPort: destinationPort,
                    httpPort: httpPort,
                    diagnostics: diag
                )
                upstream = conn
                socksConnectSucceeded = true
                TunnelStatisticsStore.recordTcpRelaySession()
                MessagingAppsDiagnostics.logTcpRelay(host: destHost, port: destinationPort, ok: true, stage: "socks_connected")
                startIdleWatch(timeouts: timeouts)
                let backlog = pendingClientData
                pendingClientData = []
                for chunk in backlog {
                    try await sendUpstream(chunk)
                }
                await pumpFromProxy(conn, timeouts: timeouts)
            } catch {
                guard !closing else { return }
                let reason: String
                if let err = error as? Socks5TCPClient.Socks5Error,
                   case .connectRejected(let rep) = err {
                    reason = "socks_rep=\(rep)"
                    diag.log("TCP_RELAY_SOCKS_CONNECT_REJECTED", detail: "rep=\(rep)")
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "tun_relay_socks rep=\(rep) dest=\(destHost):\(destinationPort)"
                    )
                } else {
                    reason = error.localizedDescription
                    diag.log("TCP_RELAY_FAIL", detail: "reason=\(reason) up=\(bytesUp) down=\(bytesDown)")
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "tun_relay dest=\(destHost):\(destinationPort) err=\(reason)"
                    )
                }
                MessagingAppsDiagnostics.logTcpRelay(
                    host: destHost,
                    port: destinationPort,
                    ok: false,
                    error: reason,
                    stage: "socks_connect"
                )
                finishClose(reason: reason)
            }
        }
    }

    private func startIdleWatch(timeouts: MessagingAppsConfiguration.SocksRelayTimeouts) {
        idleWatchTask?.cancel()
        guard MessagingAppsConfiguration.isMessagingTcpEndpoint(host: destHost, port: destinationPort) else { return }
        idleWatchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                let idle = Int(Date().timeIntervalSince(lastActivity))
                diag.log(
                    "TCP_RELAY_IDLE",
                    detail: "idle_s=\(idle) up=\(bytesUp) down=\(bytesDown) receive_timeout=\(timeouts.receiveChunk.map { Int($0) } ?? -1)"
                )
            }
        }
    }

    private func sendUpstream(_ chunk: Data) async throws {
        guard let conn = upstream else { return }
        try await Socks5TCPClient.relaySend(conn, data: chunk)
        bytesUp += chunk.count
        lastActivity = Date()
        TunnelStatisticsStore.recordPacketBytes(down: 0, up: chunk.count)
        if bytesUp <= chunk.count || bytesUp % 4096 < chunk.count {
            diag.log("TCP_RELAY_BYTES_SENT", detail: "chunk=\(chunk.count) total_up=\(bytesUp)")
        }
    }

    private func pumpFromProxy(_ conn: NWConnection, timeouts: MessagingAppsConfiguration.SocksRelayTimeouts) async {
        while !Task.isCancelled, !closing {
            do {
                let chunk = try await Socks5TCPClient.relayReceive(
                    conn,
                    maxLength: 65535,
                    timeout: timeouts.receiveChunk
                )
                guard !chunk.isEmpty else { continue }
                bytesDown += chunk.count
                lastActivity = Date()
                TunnelStatisticsStore.recordPacketBytes(down: chunk.count, up: 0)
                if !receivedFirstByte {
                    receivedFirstByte = true
                    diag.log("TCP_RELAY_FIRST_BYTE", detail: "down=\(chunk.count) total_down=\(bytesDown)")
                    MessagingAppsDiagnostics.logTcpRelay(
                        host: destHost,
                        port: destinationPort,
                        ok: true,
                        stage: "first_byte"
                    )
                } else if bytesDown % 8192 < chunk.count {
                    diag.log("TCP_RELAY_BYTES_RECEIVED", detail: "chunk=\(chunk.count) total_down=\(bytesDown)")
                }
                let payload = chunk
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    TSIPStack.stack.processQueue.async {
                        self.tcpSocket.writeData(payload)
                        cont.resume()
                    }
                }
            } catch {
                let reason = relayCloseReason(for: error)
                if reason == "idle_timeout" {
                    diag.log("TCP_RELAY_IDLE_TIMEOUT", detail: "up=\(bytesUp) down=\(bytesDown)")
                    MessagingAppsDiagnostics.logTcpRelay(
                        host: destHost,
                        port: destinationPort,
                        ok: false,
                        error: reason,
                        stage: "relay_pump"
                    )
                }
                requestClose(reason: reason)
                break
            }
        }
        if !closing {
            requestClose(reason: "pump_completed")
        }
    }

    private func relayCloseReason(for error: Error) -> String {
        if closing, let pendingCloseReason { return pendingCloseReason }
        if let err = error as? Socks5TCPClient.Socks5Error {
            switch err {
            case .timeout:
                return receivedFirstByte || socksConnectSucceeded ? "idle_timeout" : "connect_timeout"
            case .remoteClosed:
                return receivedFirstByte ? "remote_closed_after_success" : "remote_closed"
            case .connectionCancelled:
                if receivedFirstByte { return "client_closed_after_success" }
                if socksConnectSucceeded { return "tun_local_close" }
                return "connection_cancelled"
            case .connectFailed:
                return socksConnectSucceeded ? "remote_closed_after_success" : "connect_failed"
            default:
                break
            }
        }
        if receivedFirstByte { return "remote_closed_after_success" }
        if socksConnectSucceeded { return "tun_local_close" }
        return error.localizedDescription
    }

    func didReadData(_ data: Data, from: TSTCPSocket) {
        guard !data.isEmpty else { return }
        if bytesUp == 0, bytesDown == 0 {
            diag.log("TCP_RELAY_TUN_DATA", detail: "first_client_bytes=\(data.count)")
        }
        if let conn = upstream {
            let chunk = data
            Task {
                try? await sendUpstream(chunk)
            }
        } else {
            pendingClientData.append(data)
        }
    }

    func didWriteData(_ length: Int, from: TSTCPSocket) {}
    func localDidClose(_ socket: TSTCPSocket) { requestClose(reason: "tun_local_close") }
    func socketDidReset(_ socket: TSTCPSocket) { requestClose(reason: "tun_reset") }
    func socketDidAbort(_ socket: TSTCPSocket) { requestClose(reason: "tun_abort") }
    func socketDidClose(_ socket: TSTCPSocket) { requestClose(reason: "tun_close") }

    private func requestClose(reason: String) {
        guard !closing else { return }
        closing = true
        pendingCloseReason = normalizedCloseReason(reason)
        upstream?.cancel()
        finishClose(reason: pendingCloseReason ?? reason)
    }

    private func normalizedCloseReason(_ reason: String) -> String {
        switch reason {
        case "tun_close", "tun_local_close":
            if receivedFirstByte { return "client_closed_after_success" }
            if socksConnectSucceeded { return "tun_local_close" }
            return reason
        case "pump_end", "pump_completed":
            if receivedFirstByte { return "pump_completed" }
            if socksConnectSucceeded { return "tun_local_close" }
            return "pump_completed"
        case "connect_failed", "connection_cancelled", "remote_closed":
            if receivedFirstByte { return "client_closed_after_success" }
            if socksConnectSucceeded { return "tun_local_close" }
            return reason
        default:
            return reason
        }
    }

    private func finishClose(reason: String) {
        guard !closeLogged else { return }
        closeLogged = true
        let finalReason = normalizedCloseReason(reason)
        diag.log("TCP_RELAY_CLOSE", detail: "reason=\(finalReason) up=\(bytesUp) down=\(bytesDown)")
        diag.log("TCP_RELAY_SESSION_END", detail: "reason=\(finalReason) up=\(bytesUp) down=\(bytesDown)")
        let isFailure = !socksConnectSucceeded
            || (finalReason == "connect_failed" || finalReason == "connect_timeout")
        if isFailure {
            MessagingAppsDiagnostics.logTcpRelay(
                host: destHost,
                port: destinationPort,
                ok: false,
                error: finalReason,
                stage: socksConnectSucceeded ? "relay_pump" : "socks_connect"
            )
        }
        TSIPStack.stack.processQueue.async {
            self.tcpSocket.close()
        }
        teardown()
    }

    private func teardown() {
        relayTask?.cancel()
        idleWatchTask?.cancel()
        upstream?.cancel()
        upstream = nil
        SOCKS5RelayGate.release()
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
