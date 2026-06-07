import Foundation

/// Forwards DNS wire-format queries through Psiphon to DoH or DoT resolvers.
enum SecureDNSTransport {
    static func query(
        wireQuery: Data,
        settings: AppSettings,
        socksPort: Int,
        httpPort: Int,
        queryId: UInt16 = 0,
        qname: String = ""
    ) async throws -> Data {
        let result = try await SecureDNSResolver.resolve(
            wireQuery: wireQuery,
            queryId: queryId == 0 ? SecureDNSResolver.queryId(from: wireQuery) : queryId,
            qname: qname,
            settings: settings,
            socksPort: socksPort,
            httpPort: httpPort
        )
        return result.payload
    }

    static func runTest(
        settings: AppSettings,
        socksPort: Int,
        httpPort: Int
    ) async -> (ok: Bool, detail: String) {
        _ = settings
        return await TunnelDnsForwarder.runTest(
            socksHost: "127.0.0.1",
            socksPort: socksPort,
            httpPort: httpPort
        )
    }

    static func queryDoT(
        wireQuery: Data,
        settings: AppSettings,
        socksPort: Int,
        queryId: UInt16,
        qname: String
    ) async throws -> Data {
        guard let endpoint = SecureDNSConfiguration.dotEndpoint(for: settings) else {
            throw SecureDNSTransportError.noResolver
        }
        guard socksPort > 0 else {
            throw SecureDNSTransportError.noProxy
        }

        let connection = try await Socks5TCPClient.openConnection(
            proxyHost: "127.0.0.1",
            proxyPort: socksPort,
            targetHost: endpoint.host,
            targetPort: endpoint.port
        )
        defer { connection.cancel() }

        do {
            let tls = NWConnectionTLSClient(connection: connection, hostname: endpoint.host)
            try tls.handshake()

            var frame = Data()
            let len = UInt16(wireQuery.count)
            frame.append(UInt8(len >> 8))
            frame.append(UInt8(len & 0xff))
            frame.append(wireQuery)
            try tls.write(frame)

            let header = try tls.read(count: 2)
            let respLen = Int(UInt16(header[0]) << 8 | UInt16(header[1]))
            guard respLen > 0, respLen <= 4096 else {
                SharedLogger.shared.log(.secureDnsDotQueryFailed, detail: "id=\(queryId) reason=bad_length len=\(respLen) qname=\(qname)")
                throw SecureDNSTransportError.dotBadResponse
            }
            let payload = try tls.read(count: respLen)
            SharedLogger.shared.log(.secureDnsDotQueryOk, detail: "id=\(queryId) provider=\(settings.secureDNSProvider.rawValue) bytes=\(payload.count) qname=\(qname)")
            return payload
        } catch {
            SharedLogger.shared.log(.secureDnsDotQueryFailed, detail: "id=\(queryId) reason=\(error.localizedDescription) qname=\(qname)")
            throw error
        }
    }
}
