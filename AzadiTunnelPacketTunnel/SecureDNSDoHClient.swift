import Foundation
import Network

/// RFC 8484 DoH POST through Psiphon's local proxy without URLSession/system DNS.
enum SecureDNSDoHClient {
    static func post(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        provider: SecureDNSProvider,
        wireQuery: Data,
        socksPort: Int,
        httpPort: Int,
        queryId: UInt16,
        qname: String
    ) async throws -> Data {
        guard socksPort > 0 || httpPort > 0 else { throw SecureDNSTransportError.noProxy }

        let targets = dohDialTargets(for: endpoint, socksPort: socksPort, httpPort: httpPort)
        let deadline = Date().addingTimeInterval(6)
        var lastError: Error = SecureDNSTransportError.noResolver
        for target in targets {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.4 else {
                lastError = SecureDNSTransportError.tlsReadFailed("doh_query_timeout")
                break
            }
            let connectTimeout = min(target.connectReplyTimeout, max(0.5, remaining))
            let tlsTimeout = min(target.tlsHandshakeTimeout, max(0.5, deadline.timeIntervalSinceNow))
            let responseTimeout = min(target.responseTimeout, max(0.5, deadline.timeIntervalSinceNow))
            SharedLogger.shared.logRaw(
                "SECURE_DNS_DOH_CONNECT",
                detail: "id=\(queryId) proxy=\(target.proxyLabel) host=\(endpoint.host) ip=\(target.requested) dial_ip=\(target.dial) port=\(endpoint.port) provider=\(provider.rawValue) qname=\(qname) bootstrap=\(target.kind) timeout_ms=\(Int(remaining * 1000))"
            )
            if target.dial != target.requested {
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_DOH_CONNECT_REMAP",
                    detail: "id=\(queryId) host=\(endpoint.host) requested_ip=\(target.requested) dial_ip=\(target.dial) qname=\(qname)"
                )
            }
            do {
                switch target.transport {
                case .httpConnect:
                    return try await postViaHTTPConnectTLS(
                        endpoint: endpoint,
                        connectHost: target.dial,
                        wireQuery: wireQuery,
                        httpPort: httpPort,
                        connectReplyTimeout: connectTimeout,
                        tlsTimeout: tlsTimeout,
                        responseTimeout: responseTimeout,
                        deadline: deadline
                    )
                case .socks:
                    if #available(iOS 15.4, *) {
                        return try await postViaSocksNetworkTLS(
                            endpoint: endpoint,
                            targetHost: target.dial,
                            wireQuery: wireQuery,
                            socksPort: socksPort,
                            connectReplyTimeout: connectTimeout,
                            tlsTimeout: tlsTimeout,
                            responseTimeout: responseTimeout,
                            deadline: deadline
                        )
                    } else {
                        return try await postViaSocksTLS(
                            endpoint: endpoint,
                            targetHost: target.dial,
                            wireQuery: wireQuery,
                            socksPort: socksPort,
                            connectReplyTimeout: connectTimeout,
                            tlsTimeout: tlsTimeout,
                            responseTimeout: responseTimeout,
                            deadline: deadline
                        )
                    }
                }
            } catch {
                lastError = error
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_DOH_CONNECT_FAILED",
                    detail: "id=\(queryId) proxy=\(target.proxyLabel) host=\(endpoint.host) ip=\(target.requested) dial_ip=\(target.dial) bootstrap=\(target.kind) reason=\(error.localizedDescription) qname=\(qname)"
                )
            }
        }

        throw lastError
    }

    private enum DoHTransport {
        case httpConnect
        case socks
    }

    private struct DoHDialTarget {
        let transport: DoHTransport
        let requested: String
        let dial: String
        let kind: String
        let connectReplyTimeout: TimeInterval
        let tlsHandshakeTimeout: TimeInterval
        let responseTimeout: TimeInterval

        var proxyLabel: String {
            switch transport {
            case .httpConnect: return "psiphon_http_connect"
            case .socks: return "socks"
            }
        }
    }

    private static func dohDialTargets(
        for endpoint: SecureDNSConfiguration.DoHEndpoint,
        socksPort: Int,
        httpPort: Int
    ) -> [DoHDialTarget] {
        var result: [DoHDialTarget] = []
        var seen = Set<String>()

        if socksPort > 0 {
            func appendSocksTarget(_ requested: String, kind: String) {
                let key = "socks:\(requested)"
                guard seen.insert(key).inserted else { return }
                result.append(
                    DoHDialTarget(
                        transport: .socks,
                        requested: requested,
                        dial: requested,
                        kind: kind,
                        connectReplyTimeout: 2,
                        tlsHandshakeTimeout: 2,
                        responseTimeout: 2.5
                    )
                )
            }

            if let primaryBootstrap = endpoint.bootstrapIPs.first {
                appendSocksTarget(primaryBootstrap, kind: "provider_ip")
            }
            appendSocksTarget(endpoint.host, kind: "socks_hostname")
            for bootstrap in endpoint.bootstrapIPs.dropFirst() {
                let key = "socks:\(bootstrap)"
                guard seen.insert(key).inserted else { continue }
                result.append(
                    DoHDialTarget(
                        transport: .socks,
                        requested: bootstrap,
                        dial: bootstrap,
                        kind: "provider_ip",
                        connectReplyTimeout: 2,
                        tlsHandshakeTimeout: 2,
                        responseTimeout: 2.5
                    )
                )
            }
        }

        if httpPort > 0 {
            // Fallback only: device logs show Psiphon's HTTP CONNECT proxy may close DoH provider
            // CONNECT attempts immediately, but keep it as a quick secondary path.
            for bootstrap in endpoint.bootstrapIPs {
                let key = "http:\(bootstrap)"
                guard seen.insert(key).inserted else { continue }
                result.append(
                    DoHDialTarget(
                        transport: .httpConnect,
                        requested: bootstrap,
                        dial: bootstrap,
                        kind: "provider_ip",
                        connectReplyTimeout: 1.5,
                        tlsHandshakeTimeout: 2,
                        responseTimeout: 2
                    )
                )
            }
            let key = "http:\(endpoint.host)"
            if seen.insert(key).inserted {
                result.append(
                    DoHDialTarget(
                        transport: .httpConnect,
                        requested: endpoint.host,
                        dial: endpoint.host,
                        kind: "http_connect_hostname",
                        connectReplyTimeout: 1.5,
                        tlsHandshakeTimeout: 2,
                        responseTimeout: 2
                    )
                )
            }
        }

        if result.isEmpty {
            result.append(
                DoHDialTarget(
                    transport: .socks,
                    requested: endpoint.host,
                    dial: endpoint.host,
                    kind: "socks_hostname",
                    connectReplyTimeout: 2.5,
                    tlsHandshakeTimeout: 2.5,
                    responseTimeout: 3
                )
            )
        }
        return result
    }

    private static func postViaHTTPConnectTLS(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        connectHost: String,
        wireQuery: Data,
        httpPort: Int,
        connectReplyTimeout: TimeInterval,
        tlsTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        deadline: Date
    ) async throws -> Data {
        guard httpPort > 0 else { throw SecureDNSTransportError.noProxy }
        let connection = try await openHTTPConnectTunnel(
            endpoint: endpoint,
            connectHost: connectHost,
            httpPort: httpPort,
            timeout: connectReplyTimeout
        )
        defer { connection.cancel() }

        let tls = NWConnectionTLSClient(connection: connection, hostname: endpoint.host)
        let handshakeBudget = min(tlsTimeout, try remainingBudget(deadline: deadline, stage: "doh_tls_timeout"))
        try tls.handshake(timeout: handshakeBudget)
        try tls.write(buildDoHRequest(endpoint: endpoint, wireQuery: wireQuery))
        let readBudget = min(responseTimeout, try remainingBudget(deadline: deadline, stage: "doh_response_timeout"))
        return try readHttpResponseBody(tls: tls, timeout: readBudget)
    }

    private static func postViaSocksTLS(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        targetHost: String,
        wireQuery: Data,
        socksPort: Int,
        connectReplyTimeout: TimeInterval,
        tlsTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        deadline: Date
    ) async throws -> Data {
        let connection = try await Socks5TCPClient.openConnection(
            proxyHost: "127.0.0.1",
            proxyPort: socksPort,
            targetHost: targetHost,
            targetPort: endpoint.port,
            useHostOverrides: false,
            readyTimeout: 1.5,
            methodTimeout: 1.5,
            connectReplyTimeout: connectReplyTimeout
        )
        defer { connection.cancel() }

        let tls = NWConnectionTLSClient(connection: connection, hostname: endpoint.host)
        let handshakeBudget = min(tlsTimeout, try remainingBudget(deadline: deadline, stage: "doh_tls_timeout"))
        try tls.handshake(timeout: handshakeBudget)
        try tls.write(buildDoHRequest(endpoint: endpoint, wireQuery: wireQuery))

        let readBudget = min(responseTimeout, try remainingBudget(deadline: deadline, stage: "doh_response_timeout"))
        return try readHttpResponseBody(tls: tls, timeout: readBudget)
    }

    private static func remainingBudget(deadline: Date, stage: String) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.2 else {
            throw SecureDNSTransportError.tlsReadFailed(stage)
        }
        return max(0.2, remaining)
    }

    private static func buildDoHRequest(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        wireQuery: Data
    ) -> Data {
        let hostHeader = endpoint.port == 443 ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
        let header =
            "POST \(endpoint.pathAndQuery) HTTP/1.1\r\n" +
            "Host: \(hostHeader)\r\n" +
            "Content-Type: application/dns-message\r\n" +
            "Accept: application/dns-message\r\n" +
            "Content-Length: \(wireQuery.count)\r\n" +
            "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(wireQuery)
        return payload
    }

    private static func openHTTPConnectTunnel(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        connectHost: String,
        httpPort: Int,
        timeout: TimeInterval
    ) async throws -> NWConnection {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: UInt16(httpPort)),
            using: .tcp
        )
        try await waitReady(connection, timeout: 2)
        let hostHeader = endpoint.port == 443 ? connectHost : "\(connectHost):\(endpoint.port)"
        let request =
            "CONNECT \(hostHeader) HTTP/1.1\r\n" +
            "Host: \(hostHeader)\r\n" +
            "Proxy-Connection: keep-alive\r\n\r\n"
        try await sendAll(connection, data: Data(request.utf8))

        var head = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while head.count < 16 * 1024, Date() < deadline {
            let chunk = try await Socks5TCPClient.relayReceive(
                connection,
                maxLength: min(4096, 16 * 1024 - head.count),
                timeout: max(0.5, min(timeout, deadline.timeIntervalSinceNow))
            )
            head.append(chunk)
            if head.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        guard let headerEnd = head.range(of: Data("\r\n\r\n".utf8)) else {
            connection.cancel()
            throw SecureDNSTransportError.tlsReadFailed("http_connect_no_headers")
        }
        let status = String(data: head.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        guard status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") else {
            connection.cancel()
            throw SecureDNSTransportError.dohBadStatus(-20)
        }
        return connection
    }

    private static func waitReady(
        _ connection: NWConnection,
        timeout: TimeInterval,
        stage: String = "http_connect_ready_timeout"
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>()
            gate.scheduleTimeout(after: timeout) {
                connection.stateUpdateHandler = nil
                connection.cancel()
                _ = gate.resume(cont, throwing: SecureDNSTransportError.tlsReadFailed(stage))
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
                    _ = gate.resume(cont, throwing: SecureDNSTransportError.noProxy)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func sendAll(_ connection: NWConnection, data: Data, timeout: TimeInterval? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>()
            if let timeout {
                gate.scheduleTimeout(after: timeout) {
                    connection.cancel()
                    _ = gate.resume(cont, throwing: SecureDNSTransportError.tlsWriteFailed("timeout"))
                }
            }
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { _ = gate.resume(cont, throwing: err) }
                else { _ = gate.resume(cont, returning: ()) }
            })
        }
    }

    private struct HTTPHeaderBlock {
        let statusCode: Int
        let fields: [String: String]
    }

    private static func readHttpResponseBody(tls: NWConnectionTLSClient, timeout: TimeInterval) throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < 65536, Date() < deadline {
            let chunk = try tls.readSome(
                maxCount: min(4096, 65536 - buffer.count),
                timeout: max(0.5, min(3, deadline.timeIntervalSinceNow))
            )
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }

            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            let headers = try parseHTTPHeaders(headerData)
            guard headers.statusCode == 200 else {
                throw SecureDNSTransportError.dohBadStatus(headers.statusCode)
            }
            let contentType = headers.fields["content-type"]?.lowercased() ?? ""
            let mediaType = contentType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard mediaType == "application/dns-message" else {
                throw SecureDNSTransportError.dohBadStatus(-6)
            }

            var body = buffer.subdata(in: headerRange.upperBound..<buffer.count)
            if headers.fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
                body = try readChunkedBody(initialBody: body, tls: tls, deadline: deadline)
            } else if let contentLength = headers.fields["content-length"].flatMap(Int.init) {
                while body.count < contentLength, Date() < deadline {
                    let more = try tls.readSome(
                        maxCount: min(4096, contentLength - body.count),
                        timeout: max(0.5, min(3, deadline.timeIntervalSinceNow))
                    )
                    if more.isEmpty { break }
                    body.append(more)
                }
                guard body.count >= contentLength else {
                    throw SecureDNSTransportError.dohBadStatus(-7)
                }
                body = body.prefix(contentLength)
            }

            guard !body.isEmpty else { throw SecureDNSTransportError.dohBadStatus(-4) }
            return body
        }
        throw SecureDNSTransportError.dohBadStatus(-5)
    }

    @available(iOS 15.4, *)
    private static func postViaSocksNetworkTLS(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        targetHost: String,
        wireQuery: Data,
        socksPort: Int,
        connectReplyTimeout: TimeInterval,
        tlsTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        deadline: Date
    ) async throws -> Data {
        let parameters = makeSocksTLSParameters(
            tlsHost: endpoint.host,
            targetHost: targetHost,
            targetPort: endpoint.port,
            timeout: max(1, connectReplyTimeout + tlsTimeout)
        )
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: UInt16(socksPort)),
            using: parameters
        )
        defer { connection.cancel() }

        let readyBudget = min(
            max(1, connectReplyTimeout + tlsTimeout),
            try remainingBudget(deadline: deadline, stage: "doh_tls_ready_timeout")
        )
        try await waitReady(connection, timeout: readyBudget, stage: "doh_tls_ready_timeout")
        try await sendAll(
            connection,
            data: buildDoHRequest(endpoint: endpoint, wireQuery: wireQuery),
            timeout: min(1.5, try remainingBudget(deadline: deadline, stage: "doh_http_write_timeout"))
        )
        let readBudget = min(responseTimeout, try remainingBudget(deadline: deadline, stage: "doh_response_timeout"))
        return try await readHttpResponseBody(connection: connection, timeout: readBudget)
    }

    @available(iOS 15.4, *)
    private static func makeSocksTLSParameters(
        tlsHost: String,
        targetHost: String,
        targetPort: UInt16,
        timeout: TimeInterval
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, tlsHost)
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(max(1, timeout.rounded(.up)))
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let socksFramer = NWProtocolFramer.Options(definition: SecureDNSSOCKS5ConnectFramer.definition)
        SecureDNSSOCKS5ConnectFramer.setTarget(host: targetHost, port: targetPort, on: socksFramer)
        parameters.defaultProtocolStack.applicationProtocols.append(socksFramer)
        SharedLogger.shared.logRaw(
            "SECURE_DNS_DOH_STACK",
            detail: "order=tls,socks,tcp tls_host=\(tlsHost) target=\(targetHost):\(targetPort)"
        )
        return parameters
    }

    private static func readHttpResponseBody(connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < 65536, Date() < deadline {
            let chunk = try await Socks5TCPClient.relayReceive(
                connection,
                maxLength: min(4096, 65536 - buffer.count),
                timeout: max(0.2, min(1, deadline.timeIntervalSinceNow))
            )
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }

            let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
            let headers = try parseHTTPHeaders(headerData)
            guard headers.statusCode == 200 else {
                throw SecureDNSTransportError.dohBadStatus(headers.statusCode)
            }
            let contentType = headers.fields["content-type"]?.lowercased() ?? ""
            let mediaType = contentType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard mediaType == "application/dns-message" else {
                throw SecureDNSTransportError.dohBadStatus(-6)
            }

            var body = buffer.subdata(in: headerRange.upperBound..<buffer.count)
            if headers.fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
                while Date() < deadline {
                    if let decoded = try decodeChunkedBodyIfComplete(body) {
                        guard !decoded.isEmpty else { throw SecureDNSTransportError.dohBadStatus(-4) }
                        return decoded
                    }
                    let more = try await Socks5TCPClient.relayReceive(
                        connection,
                        maxLength: 4096,
                        timeout: max(0.2, min(1, deadline.timeIntervalSinceNow))
                    )
                    if more.isEmpty { break }
                    body.append(more)
                }
                throw SecureDNSTransportError.dohBadStatus(-8)
            } else if let contentLength = headers.fields["content-length"].flatMap(Int.init) {
                while body.count < contentLength, Date() < deadline {
                    let more = try await Socks5TCPClient.relayReceive(
                        connection,
                        maxLength: min(4096, contentLength - body.count),
                        timeout: max(0.2, min(1, deadline.timeIntervalSinceNow))
                    )
                    if more.isEmpty { break }
                    body.append(more)
                }
                guard body.count >= contentLength else {
                    throw SecureDNSTransportError.dohBadStatus(-7)
                }
                body = body.prefix(contentLength)
            }

            guard !body.isEmpty else { throw SecureDNSTransportError.dohBadStatus(-4) }
            return body
        }
        throw SecureDNSTransportError.dohBadStatus(-5)
    }

    private static func parseHTTPHeaders(_ data: Data) throws -> HTTPHeaderBlock {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SecureDNSTransportError.dohBadStatus(-2)
        }
        let lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else {
            throw SecureDNSTransportError.dohBadStatus(-2)
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw SecureDNSTransportError.dohBadStatus(-2)
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        return HTTPHeaderBlock(statusCode: statusCode, fields: fields)
    }

    private static func readChunkedBody(
        initialBody: Data,
        tls: NWConnectionTLSClient,
        deadline: Date
    ) throws -> Data {
        var encoded = initialBody
        while Date() < deadline {
            if let decoded = try decodeChunkedBodyIfComplete(encoded) {
                return decoded
            }
            let more = try tls.readSome(
                maxCount: 4096,
                timeout: max(0.5, min(3, deadline.timeIntervalSinceNow))
            )
            if more.isEmpty { break }
            encoded.append(more)
        }
        throw SecureDNSTransportError.dohBadStatus(-8)
    }

    private static func decodeChunkedBodyIfComplete(_ encoded: Data) throws -> Data? {
        var offset = 0
        var decoded = Data()
        let crlf = Data("\r\n".utf8)

        while offset < encoded.count {
            guard let lineRange = encoded.range(of: crlf, options: [], in: offset..<encoded.count) else {
                return nil
            }
            let sizeLineData = encoded.subdata(in: offset..<lineRange.lowerBound)
            guard let sizeLine = String(data: sizeLineData, encoding: .ascii) else {
                throw SecureDNSTransportError.dohBadStatus(-8)
            }
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw SecureDNSTransportError.dohBadStatus(-8)
            }
            offset = lineRange.upperBound
            if size == 0 {
                return decoded
            }
            guard offset + size + 2 <= encoded.count else {
                return nil
            }
            decoded.append(encoded.subdata(in: offset..<(offset + size)))
            offset += size
            guard encoded.subdata(in: offset..<(offset + 2)) == crlf else {
                throw SecureDNSTransportError.dohBadStatus(-8)
            }
            offset += 2
        }

        return nil
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
