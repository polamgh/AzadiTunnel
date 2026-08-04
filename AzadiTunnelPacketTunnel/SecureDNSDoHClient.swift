import Foundation

/// RFC 8484 POST client. The TCP stream is opened only to Psiphon's local SOCKS listener; the
/// resolver never uses URLSession, the system resolver, the local HTTP proxy, or plaintext HTTP.
enum SecureDNSDoHClient {
    static func post(
        endpoints: [SecureDNSConfiguration.DoHEndpoint],
        provider: SecureDNSProvider,
        wireQuery: Data,
        socksHost: String,
        socksPort: Int
    ) async throws -> Data {
        guard socksPort > 0 else { throw SecureDNSTransportError.noProxy }
        guard !wireQuery.isEmpty, wireQuery.count <= 65_535 else {
            throw SecureDNSTransportError.invalidDNSMessage
        }

        let candidates = SecureDNSFailoverPolicy.endpointsToTry(endpoints)
        guard !candidates.isEmpty else { throw SecureDNSTransportError.noResolver }
        do {
            return try await SecureDNSFailoverPolicy.perform(
                endpoints: Array(candidates),
                operation: { endpoint, index, deadline in
                    SharedLogger.shared.logRaw(
                        "SECURE_DNS_DOH_ATTEMPT",
                        detail: "provider=\(provider.rawValue) endpoint_index=\(index)"
                    )
                    do {
                        return try await post(
                            endpoint: endpoint,
                            wireQuery: wireQuery,
                            socksHost: socksHost,
                            socksPort: socksPort,
                            deadline: deadline
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Do not persist or log provider/network text that could contain a query,
                        // URL credentials, or other user-controlled data.
                        SharedLogger.shared.logRaw(
                            "SECURE_DNS_DOH_ATTEMPT_FAILED",
                            detail: "provider=\(provider.rawValue) endpoint_index=\(index) reason=transport"
                        )
                        throw error
                    }
                }
            )
        } catch SecureDNSFailoverPolicy.Error.noEndpoints {
            throw SecureDNSTransportError.noResolver
        }
    }

    private static func post(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        wireQuery: Data,
        socksHost: String,
        socksPort: Int,
        deadline: SecureDNSDeadline
    ) async throws -> Data {
        let targets = SecureDNSBootstrap.targets(
            endpointHost: endpoint.host,
            bootstrapIPs: endpoint.bootstrapIPs
        )

        var lastError: Error = SecureDNSTransportError.noResolver
        for target in targets {
            try Task.checkCancellation()
            let remaining = deadline.remaining
            guard remaining > 0.1 else { break }
            do {
                return try await postToTarget(
                    endpoint: endpoint,
                    wireQuery: wireQuery,
                    target: target.connectHost,
                    tlsServerName: target.tlsServerName,
                    socksHost: socksHost,
                    socksPort: socksPort,
                    deadline: deadline
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func postToTarget(
        endpoint: SecureDNSConfiguration.DoHEndpoint,
        wireQuery: Data,
        target: String,
        tlsServerName: String,
        socksHost: String,
        socksPort: Int,
        deadline: SecureDNSDeadline
    ) async throws -> Data {
        let connectBudget = try remainingBudget(deadline, stage: "doh_connect_timeout")
        let connection = try await Socks5TCPClient.openConnection(
            proxyHost: socksHost,
            proxyPort: socksPort,
            targetHost: target,
            targetPort: endpoint.port,
            useHostOverrides: false,
            readyTimeout: min(1.0, connectBudget),
            methodTimeout: min(1.0, try remainingBudget(deadline, stage: "doh_method_timeout")),
            connectReplyTimeout: min(1.5, try remainingBudget(deadline, stage: "doh_connect_reply_timeout")),
            deadline: deadline
        )
        defer { connection.cancel() }

        let tls = NWConnectionTLSClient(connection: connection, hostname: tlsServerName)
        return try await withTaskCancellationHandler(operation: {
            try tls.handshake(timeout: min(1.5, try remainingBudget(deadline, stage: "doh_tls_timeout")))
            try tls.write(
                buildDoHRequest(endpoint: endpoint, wireQuery: wireQuery),
                timeout: try remainingBudget(deadline, stage: "doh_write_timeout")
            )
            return try readHTTPResponseBody(
                tls: tls,
                timeout: try remainingBudget(deadline, stage: "doh_response_timeout")
            )
        }, onCancel: {
            tls.cancel()
        })
    }

    private static func remainingBudget(_ deadline: SecureDNSDeadline, stage: String) throws -> TimeInterval {
        let remaining = deadline.remaining
        guard remaining > 0.1 else {
            throw SecureDNSTransportError.tlsReadFailed(stage)
        }
        return remaining
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
        var request = Data(header.utf8)
        request.append(wireQuery)
        return request
    }

    private struct HTTPHeaderBlock {
        let statusCode: Int
        let fields: [String: String]
    }

    private static func readHTTPResponseBody(
        tls: NWConnectionTLSClient,
        timeout: TimeInterval
    ) throws -> Data {
        let deadline = SecureDNSDeadline(after: timeout)
        let headerTerminator = Data("\r\n\r\n".utf8)
        var buffer = Data()

        while buffer.count <= 16 * 1024, deadline.remaining > 0 {
            if let headerRange = buffer.range(of: headerTerminator) {
                let headers = try parseHTTPHeaders(buffer.subdata(in: 0..<headerRange.lowerBound))
                guard headers.statusCode == 200 else {
                    throw SecureDNSTransportError.dohBadStatus(headers.statusCode)
                }
                let mediaType = (headers.fields["content-type"] ?? "")
                    .split(separator: ";", maxSplits: 1)
                    .first
                    .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                guard mediaType == "application/dns-message" else {
                    throw SecureDNSTransportError.invalidHTTPResponse("content_type")
                }

                var body = buffer.subdata(in: headerRange.upperBound..<buffer.count)
                if headers.fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
                    while deadline.remaining > 0 {
                        if let decoded = try decodeChunkedBodyIfComplete(body) {
                            return try validateBody(decoded)
                        }
                        body.append(try readSome(tls, deadline: deadline))
                    }
                    throw SecureDNSTransportError.tlsReadFailed("doh_chunked_timeout")
                }

                guard let contentLength = headers.fields["content-length"].flatMap(Int.init),
                      contentLength > 0,
                      contentLength <= 65_535 else {
                    throw SecureDNSTransportError.invalidHTTPResponse("content_length")
                }
                while body.count < contentLength, deadline.remaining > 0 {
                    body.append(try readSome(tls, deadline: deadline, maxCount: contentLength - body.count))
                }
                guard body.count >= contentLength else {
                    throw SecureDNSTransportError.tlsReadFailed("doh_body_timeout")
                }
                return try validateBody(Data(body.prefix(contentLength)))
            }

            guard buffer.count < 16 * 1024 else {
                throw SecureDNSTransportError.invalidHTTPResponse("headers_too_large")
            }
            buffer.append(try readSome(tls, deadline: deadline, maxCount: 4096))
        }
        throw SecureDNSTransportError.tlsReadFailed("doh_headers_timeout")
    }

    private static func readSome(
        _ tls: NWConnectionTLSClient,
        deadline: SecureDNSDeadline,
        maxCount: Int = 4_096
    ) throws -> Data {
        let remaining = deadline.remaining
        guard remaining > 0 else { throw SecureDNSTransportError.tlsReadFailed("doh_timeout") }
        let timeout = max(0.01, min(1.0, remaining))
        let data = try tls.readSome(maxCount: max(1, maxCount), timeout: timeout)
        guard !data.isEmpty else { throw SecureDNSTransportError.tlsReadFailed("doh_closed") }
        return data
    }

    private static func validateBody(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= 65_535 else {
            throw SecureDNSTransportError.invalidHTTPResponse("body_size")
        }
        return body
    }

    private static func parseHTTPHeaders(_ data: Data) throws -> HTTPHeaderBlock {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SecureDNSTransportError.invalidHTTPResponse("headers_encoding")
        }
        let lines = raw.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else {
            throw SecureDNSTransportError.invalidHTTPResponse("status_line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw SecureDNSTransportError.invalidHTTPResponse("status_code")
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { fields[name] = value }
        }
        return HTTPHeaderBlock(statusCode: statusCode, fields: fields)
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
                throw SecureDNSTransportError.invalidHTTPResponse("chunk_size")
            }
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw SecureDNSTransportError.invalidHTTPResponse("chunk_size")
            }
            offset = lineRange.upperBound
            if size == 0 {
                return decoded
            }
            guard size <= 65_535, offset + size + 2 <= encoded.count else { return nil }
            decoded.append(encoded.subdata(in: offset..<(offset + size)))
            guard encoded.subdata(in: (offset + size)..<(offset + size + 2)) == crlf else {
                throw SecureDNSTransportError.invalidHTTPResponse("chunk_terminator")
            }
            offset += size + 2
            guard decoded.count <= 65_535 else {
                throw SecureDNSTransportError.invalidHTTPResponse("body_size")
            }
        }
        return nil
    }
}
