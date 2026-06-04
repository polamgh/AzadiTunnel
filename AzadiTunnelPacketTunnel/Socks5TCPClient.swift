import Foundation
import Network

#if canImport(tun2socks)
import tun2socks
#endif

/// Minimal SOCKS5 TCP CONNECT client (RFC 1928) to Psiphon local proxy.
enum Socks5TCPClient {
    enum Socks5Error: Swift.Error {
        case handshakeFailed
        case connectFailed
        case connectRejected(rep: UInt8)
        case httpNoHeaders

        var errorDescription: String? {
            switch self {
            case .handshakeFailed: return "handshake_failed"
            case .connectFailed: return "connect_failed"
            case .connectRejected(let rep): return "connect_rejected:\(rep)"
            case .httpNoHeaders: return "http_no_headers"
            }
        }
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
        let lenHeader = try await receiveExact(connection, count: 2)
        let respLen = Int(UInt16(lenHeader[0]) << 8 | UInt16(lenHeader[1]))
        guard respLen > 0, respLen <= 4096 else { throw Socks5Error.connectFailed }
        return try await receiveExact(connection, count: respLen)
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

    /// Avoid tunnel DNS IPs (1.1.1.1 / 8.8.8.8) — Psiphon SOCKS rejects CONNECT to them (rep=1).
    private static func socksConnectHost(for host: String) -> String {
        if parseIPv4(host) != nil { return host }
        switch host {
        case "dns.google": return "142.250.80.46"
        case "one.one.one.one": return "162.159.195.42"
        case "connectivitycheck.gstatic.com": return "142.250.80.78"
        default: return host
        }
    }

    static func openConnection(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: UInt16
    ) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort))
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await waitReady(connection)

        try await sendAll(connection, data: Data([0x05, 0x01, 0x00]))
        let methodReply = try await receiveExact(connection, count: 2)
        guard methodReply[0] == 0x05, methodReply[1] == 0x00 else {
            SharedLogger.shared.log(.internetTestFailed, detail: "socks_method rep=\(methodReply.map { String($0) }.joined(separator: ","))")
            throw Socks5Error.handshakeFailed
        }

        let connectHost = socksConnectHost(for: targetHost)
        var connect = Data([0x05, 0x01, 0x00])
        if let ipv4 = parseIPv4(connectHost) {
            connect.append(contentsOf: [0x01])
            connect.append(contentsOf: ipv4)
        } else {
            connect.append(0x03)
            guard let hostData = targetHost.data(using: .utf8) else { throw Socks5Error.connectFailed }
            connect.append(UInt8(hostData.count))
            connect.append(hostData)
        }
        connect.append(UInt8(targetPort >> 8))
        connect.append(UInt8(targetPort & 0xff))
        try await sendAll(connection, data: connect)
        try await consumeConnectReply(connection)
        return connection
    }

    /// Read and discard the full RFC 1928 CONNECT reply so later reads are DNS payload only.
    private static func consumeConnectReply(_ connection: NWConnection) async throws {
        let header = try await receiveExact(connection, count: 4)
        guard header[0] == 0x05 else { throw Socks5Error.connectFailed }
        guard header[1] == 0x00 else {
            SharedLogger.shared.log(.internetTestFailed, detail: "socks_connect rep=\(header[1])")
            throw Socks5Error.connectRejected(rep: header[1])
        }
        let addressBytes: Int
        switch header[3] {
        case 0x01: addressBytes = 4 + 2
        case 0x03:
            let lenChunk = try await receiveExact(connection, count: 1)
            addressBytes = Int(lenChunk[0]) + 2
        case 0x04: addressBytes = 16 + 2
        default: throw Socks5Error.connectFailed
        }
        guard addressBytes > 0 else { return }
        _ = try await receiveExact(connection, count: addressBytes)
    }

    private static func receiveExact(_ connection: NWConnection, count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(connection, maxLength: count - buffer.count)
            buffer.append(chunk)
        }
        return buffer
    }

    private static func receiveChunk(_ connection: NWConnection, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: Socks5Error.handshakeFailed)
                }
            }
        }
    }

    private static var socksQueue: DispatchQueue {
#if canImport(tun2socks)
        TSIPStack.stack.processQueue
#else
        DispatchQueue(label: "com.polamgh.ali.AzadiTunnel.socks5")
#endif
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let n = UInt8(part), n <= 255 else { return nil }
            bytes.append(n)
        }
        return bytes
    }

    private static func waitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: err)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: Socks5Error.handshakeFailed)
                default:
                    break
                }
            }
            connection.start(queue: Self.socksQueue)
        }
    }

    static func relaySend(_ connection: NWConnection, data: Data) async throws {
        try await sendAll(connection, data: data)
    }

    static func relayReceive(_ connection: NWConnection, maxLength: Int) async throws -> Data {
        try await receiveChunk(connection, maxLength: maxLength)
    }

    private static func sendAll(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private static func readHttpBody(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(30)
        while buffer.count < 65536, Date() < deadline {
            let chunk = try await receiveChunk(connection, maxLength: 65536 - buffer.count)
            if !chunk.isEmpty { buffer.append(chunk) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return buffer.subdata(in: range.upperBound..<buffer.count)
            }
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw Socks5Error.httpNoHeaders
    }

}
