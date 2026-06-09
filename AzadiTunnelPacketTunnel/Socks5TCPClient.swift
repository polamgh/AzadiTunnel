import Foundation
import Network

#if canImport(tun2socks)
import tun2socks
#endif

/// Minimal SOCKS5 TCP CONNECT client (RFC 1928) to Psiphon local proxy.
enum Socks5TCPClient {
    enum Socks5Error: LocalizedError {
        case handshakeFailed
        case connectFailed
        case connectRejected(rep: UInt8)
        case httpNoHeaders
        case timeout(String)
        case remoteClosed
        case connectionCancelled

        var errorDescription: String? {
            switch self {
            case .handshakeFailed: return "handshake_failed"
            case .connectFailed: return "connect_failed"
            case .connectRejected(let rep): return "connect_rejected:\(rep)"
            case .httpNoHeaders: return "http_no_headers"
            case .timeout(let stage): return "timeout:\(stage)"
            case .remoteClosed: return "remote_closed"
            case .connectionCancelled: return "connection_cancelled"
            }
        }
    }

    /// Psiphon SOCKS rejects CONNECT to well-known resolver literals; use anycast edge instead.
    private static let resolverIPOverrides: [String: String] = [
        "1.1.1.1": "162.159.195.42",
        "1.0.0.1": "162.159.195.42",
        "8.8.8.8": "142.250.80.46",
        "8.8.4.4": "142.250.80.46",
    ]

    private static let hostnameOverrides: [String: String] = [
        "dns.google": "142.250.80.46",
        "one.one.one.one": "162.159.195.42",
        "cloudflare-dns.com": "162.159.195.42",
        "dns.quad9.net": "9.9.9.9",
        "dns.adguard-dns.com": "94.140.14.14",
        "connectivitycheck.gstatic.com": "142.250.80.78",
    ]

    /// Maps SOCKS CONNECT targets so Psiphon can reach public DNS / resolver hosts.
    static func socksTargetHost(for host: String) -> String {
        if let mapped = resolverIPOverrides[host] { return mapped }
        return hostnameOverrides[host.lowercased()] ?? host
    }

    /// DNS query over TCP (RFC 7766) via SOCKS to a resolver outside tunnel DNS IPs.
    static func tcpDnsQuery(
        query: Data,
        resolverIPv4: String = "9.9.9.9",
        proxyHost: String = "127.0.0.1",
        proxyPort: Int
    ) async throws -> Data {
        let connection = try await openConnection(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            targetHost: resolverIPv4,
            targetPort: 53
        )
        defer { connection.cancel() }
        var framed = Data()
        let len = UInt16(query.count)
        framed.append(UInt8(len >> 8))
        framed.append(UInt8(len & 0xff))
        framed.append(query)
        try await sendAll(connection, data: framed)
        let lenHeader = try await receiveExact(connection, count: 2, timeout: 8)
        let respLen = Int(UInt16(lenHeader[0]) << 8 | UInt16(lenHeader[1]))
        guard respLen > 0, respLen <= 4096 else { throw Socks5Error.connectFailed }
        return try await receiveExact(connection, count: respLen, timeout: 8)
    }

    /// HTTP GET to `host` through Psiphon SOCKS (full CONNECT reply consumed before reading body).
    static func httpGet(
        path: String,
        host: String,
        port: UInt16 = 80,
        proxyHost: String = "127.0.0.1",
        proxyPort: Int
    ) async throws -> Data {
        let connection = try await openConnection(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            targetHost: host,
            targetPort: port
        )
        defer { connection.cancel() }
        let request =
            "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
        try await sendAll(connection, data: Data(request.utf8))
        return try await readHttpBody(connection)
    }

    static func openConnection(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: UInt16,
        httpPort: Int = 0,
        useHostOverrides: Bool = true,
        readyTimeout: TimeInterval = 5,
        methodTimeout: TimeInterval = 5,
        connectReplyTimeout: TimeInterval = 8,
        diagnostics: TcpRelayDiagnostics.SessionContext? = nil
    ) async throws -> NWConnection {
        let timeouts = MessagingAppsConfiguration.socksRelayTimeouts(for: targetHost, port: targetPort)
        let readyTO = readyTimeout == 5 ? timeouts.ready : readyTimeout
        let methodTO = methodTimeout == 5 ? timeouts.method : methodTimeout
        let connectTO = connectReplyTimeout == 8 ? timeouts.connectReply : connectReplyTimeout
        _ = httpPort

        diagnostics?.log(
            "TCP_RELAY_SOCKS_BEGIN",
            detail: "proxy=\(proxyHost):\(proxyPort) timeouts=\(timeouts.profile) ready=\(Int(readyTO)) method=\(Int(methodTO)) connect_reply=\(Int(connectTO))"
        )

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort))
        )
        let connection = NWConnection(to: endpoint, using: connectionParameters(for: targetHost, port: targetPort))
        let readyStarted = Date()
        try await waitReady(connection, timeout: readyTO)
        diagnostics?.log(
            "TCP_RELAY_SOCKS_READY",
            detail: "ms=\(Int(Date().timeIntervalSince(readyStarted) * 1000))"
        )

        try await sendAll(connection, data: Data([0x05, 0x01, 0x00]))
        let methodReply = try await receiveExact(connection, count: 2, timeout: methodTO)
        guard methodReply[0] == 0x05, methodReply[1] == 0x00 else {
            diagnostics?.log(
                "TCP_RELAY_SOCKS_METHOD_FAIL",
                detail: "rep=\(methodReply.map { String($0) }.joined(separator: ","))"
            )
            SharedLogger.shared.log(.internetTestFailed, detail: "socks_method rep=\(methodReply.map { String($0) }.joined(separator: ","))")
            throw Socks5Error.handshakeFailed
        }
        diagnostics?.log("TCP_RELAY_SOCKS_METHOD_OK", detail: "auth=none")

        let connectHost = useHostOverrides ? socksTargetHost(for: targetHost) : targetHost
        var connect = Data([0x05, 0x01, 0x00])
        if let ipv4 = parseIPv4(connectHost) {
            connect.append(contentsOf: [0x01])
            connect.append(contentsOf: ipv4)
        } else {
            connect.append(0x03)
            guard let hostData = connectHost.data(using: .utf8) else { throw Socks5Error.connectFailed }
            connect.append(UInt8(hostData.count))
            connect.append(hostData)
        }
        connect.append(UInt8(targetPort >> 8))
        connect.append(UInt8(targetPort & 0xff))
        let connectStarted = Date()
        diagnostics?.log(
            "TCP_RELAY_SOCKS_CONNECT_SENT",
            detail: "target=\(connectHost):\(targetPort) overridden=\(connectHost != targetHost)"
        )
        try await sendAll(connection, data: connect)
        try await consumeConnectReply(connection, timeout: connectTO)
        diagnostics?.log(
            "TCP_RELAY_SOCKS_CONNECT_OK",
            detail: "ms=\(Int(Date().timeIntervalSince(connectStarted) * 1000))"
        )
        return connection
    }

    private static func connectionParameters(for host: String, port: UInt16) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(
            MessagingAppsConfiguration.socksRelayTimeouts(for: host, port: port).connectReply.rounded(.up)
        )
        if MessagingAppsConfiguration.isMessagingTcpEndpoint(host: host, port: port) {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveCount = 4
            tcp.keepaliveInterval = 15
        }
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Read and discard the full RFC 1928 CONNECT reply so later reads are DNS payload only.
    private static func consumeConnectReply(_ connection: NWConnection, timeout: TimeInterval? = nil) async throws {
        let header = try await receiveExact(connection, count: 4, timeout: timeout)
        guard header[0] == 0x05, header[1] == 0x00 else {
            throw Socks5Error.connectRejected(rep: header[1])
        }
        let addrType = header[3]
        switch addrType {
        case 0x01:
            _ = try await receiveExact(connection, count: 4 + 2, timeout: timeout)
        case 0x03:
            let len = Int(try await receiveExact(connection, count: 1, timeout: timeout)[0])
            _ = try await receiveExact(connection, count: len + 2, timeout: timeout)
        case 0x04:
            _ = try await receiveExact(connection, count: 16 + 2, timeout: timeout)
        default:
            throw Socks5Error.connectFailed
        }
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        let raw = withUnsafeBytes(of: addr.s_addr) { Array($0) }
        return raw
    }

    static func relaySend(_ connection: NWConnection, data: Data) async throws {
        try await sendAll(connection, data: data)
    }

    static func relayReceive(_ connection: NWConnection, maxLength: Int, timeout: TimeInterval? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let gate = ContinuationGate<Data>()
            if let timeout {
                gate.scheduleTimeout(after: timeout) {
                    connection.cancel()
                    _ = gate.resume(cont, throwing: Socks5Error.timeout("receive"))
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, err in
                if let err {
                    _ = gate.resume(cont, throwing: err)
                } else if let data, !data.isEmpty {
                    _ = gate.resume(cont, returning: data)
                } else {
                    _ = gate.resume(cont, throwing: Socks5Error.remoteClosed)
                }
            }
        }
    }

    private static func waitReady(_ connection: NWConnection, timeout: TimeInterval? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>()
            if let timeout {
                gate.scheduleTimeout(after: timeout) {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    _ = gate.resume(cont, throwing: Socks5Error.timeout("ready"))
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    _ = gate.resume(cont, returning: ())
                case .failed(let err):
                    connection.stateUpdateHandler = nil
                    _ = gate.resume(cont, throwing: err)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    _ = gate.resume(cont, throwing: Socks5Error.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func sendAll(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private static func receiveExact(_ connection: NWConnection, count: Int, timeout: TimeInterval? = nil) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await relayReceive(connection, maxLength: count - buffer.count, timeout: timeout)
            buffer.append(chunk)
        }
        return buffer
    }

    private static func readHttpBody(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(20)
        while buffer.count < 65536, Date() < deadline {
            let chunk = try await relayReceive(connection, maxLength: 4096, timeout: 8)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return buffer.subdata(in: range.upperBound..<buffer.count)
            }
        }
        throw Socks5Error.httpNoHeaders
    }

    private final class ContinuationGate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private var timeoutItem: DispatchWorkItem?

        func scheduleTimeout(after timeout: TimeInterval, _ body: @escaping @Sendable () -> Void) {
            let item = DispatchWorkItem(block: body)
            lock.lock()
            if didResume {
                lock.unlock()
                item.cancel()
                return
            }
            timeoutItem = item
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: item)
        }

        func resume(_ continuation: CheckedContinuation<Value, Error>, returning value: Value) -> Bool {
            lock.lock()
            if didResume {
                lock.unlock()
                return false
            }
            didResume = true
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()
            item?.cancel()
            continuation.resume(returning: value)
            return true
        }

        func resume(_ continuation: CheckedContinuation<Value, Error>, throwing error: Error) -> Bool {
            lock.lock()
            if didResume {
                lock.unlock()
                return false
            }
            didResume = true
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()
            item?.cancel()
            continuation.resume(throwing: error)
            return true
        }
    }
}
