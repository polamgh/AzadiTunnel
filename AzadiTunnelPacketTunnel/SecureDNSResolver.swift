import Foundation

/// Resolves TUN DNS wire-format queries through Secure DNS (DoH/DoT) via Psiphon local proxy.
enum SecureDNSResolver {
    struct Result {
        let payload: Data
        let usedSecurePath: Bool
    }

    static func resolve(
        wireQuery: Data,
        queryId: UInt16,
        qname: String,
        settings: AppSettings,
        socksPort: Int,
        httpPort: Int
    ) async throws -> Result {
        switch settings.secureDNSMode {
        case .off:
            throw SecureDNSTransportError.noResolver
        case .doh:
            guard let endpoint = SecureDNSConfiguration.dohEndpoint(for: settings) else {
                throw SecureDNSTransportError.noResolver
            }
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SELECTED",
                detail: "id=\(queryId) mode=doh provider=\(settings.secureDNSProvider.rawValue) url=\(endpoint.url.absoluteString) qname=\(qname)"
            )
            do {
                let payload = try await SecureDNSDoHClient.post(
                    endpoint: endpoint,
                    provider: settings.secureDNSProvider,
                    wireQuery: wireQuery,
                    socksPort: socksPort,
                    httpPort: httpPort,
                    queryId: queryId,
                    qname: qname
                )
                let validated = try validateDNSWireResponse(payload, expectedId: queryId)
                SharedLogger.shared.log(
                    .secureDnsDohQueryOk,
                    detail: "id=\(queryId) provider=\(settings.secureDNSProvider.rawValue) bytes=\(validated.count) qname=\(qname)"
                )
                return Result(payload: validated, usedSecurePath: true)
            } catch {
                SharedLogger.shared.log(
                    .secureDnsDohQueryFailed,
                    detail: "id=\(queryId) provider=\(settings.secureDNSProvider.rawValue) reason=\(error.localizedDescription) qname=\(qname)"
                )
                throw error
            }
        case .dot:
            guard let endpoint = SecureDNSConfiguration.dotEndpoint(for: settings) else {
                throw SecureDNSTransportError.noResolver
            }
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SELECTED",
                detail: "id=\(queryId) mode=dot provider=\(settings.secureDNSProvider.rawValue) host=\(endpoint.host):\(endpoint.port) qname=\(qname)"
            )
            let payload = try await SecureDNSTransport.queryDoT(
                wireQuery: wireQuery,
                settings: settings,
                socksPort: socksPort,
                queryId: queryId,
                qname: qname
            )
            let validated = try validateDNSWireResponse(payload, expectedId: queryId)
            return Result(payload: validated, usedSecurePath: true)
        }
    }

    static func queryId(from payload: Data) -> UInt16 {
        guard payload.count >= 2 else { return 0 }
        return UInt16(payload[0]) << 8 | UInt16(payload[1])
    }

    static func validateDNSWireResponse(_ data: Data, expectedId: UInt16) throws -> Data {
        guard data.count >= 12 else {
            throw SecureDNSTransportError.dotBadResponse
        }
        let id = queryId(from: data)
        guard id == expectedId else {
            throw SecureDNSTransportError.dohBadStatus(-10)
        }
        guard data[2] & 0x80 != 0 else {
            throw SecureDNSTransportError.dohBadStatus(-11)
        }
        return data
    }

    static func buildAQuery(qname: String, id: UInt16) throws -> Data {
        let normalized = qname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else {
            throw SecureDNSTransportError.dohBadStatus(-12)
        }
        var query = Data()
        query.append(UInt8(id >> 8))
        query.append(UInt8(id & 0xff))
        query.append(contentsOf: [0x01, 0x00]) // standard recursive query
        query.append(contentsOf: [0x00, 0x01]) // QDCOUNT
        query.append(contentsOf: [0x00, 0x00]) // ANCOUNT
        query.append(contentsOf: [0x00, 0x00]) // NSCOUNT
        query.append(contentsOf: [0x00, 0x00]) // ARCOUNT
        for label in normalized.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else {
                throw SecureDNSTransportError.dohBadStatus(-12)
            }
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(0x00)
        query.append(contentsOf: [0x00, 0x01]) // A
        query.append(contentsOf: [0x00, 0x01]) // IN
        return query
    }

    static func ipv4Answers(from response: Data) -> [String] {
        guard response.count >= 12 else { return [] }
        let qdCount = Int(readUInt16(response, at: 4))
        let anCount = Int(readUInt16(response, at: 6))
        var offset = 12

        for _ in 0..<qdCount {
            guard skipDomainName(response, offset: &offset), offset + 4 <= response.count else {
                return []
            }
            offset += 4
        }

        var answers: [String] = []
        for _ in 0..<anCount {
            guard skipDomainName(response, offset: &offset), offset + 10 <= response.count else {
                return answers
            }
            let type = readUInt16(response, at: offset)
            let klass = readUInt16(response, at: offset + 2)
            let rdLength = Int(readUInt16(response, at: offset + 8))
            offset += 10
            guard offset + rdLength <= response.count else { return answers }
            if type == 1, klass == 1, rdLength == 4 {
                answers.append(
                    "\(response[offset]).\(response[offset + 1]).\(response[offset + 2]).\(response[offset + 3])"
                )
            }
            offset += rdLength
        }
        return answers
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func skipDomainName(_ data: Data, offset: inout Int) -> Bool {
        var labels = 0
        while offset < data.count, labels < 128 {
            labels += 1
            let length = Int(data[offset])
            if length == 0 {
                offset += 1
                return true
            }
            if length & 0xc0 == 0xc0 {
                guard offset + 1 < data.count else { return false }
                offset += 2
                return true
            }
            guard length < 64, offset + 1 + length <= data.count else {
                return false
            }
            offset += 1 + length
        }
        return false
    }
}
