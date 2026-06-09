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
        collectIPv4Records(from: response, sections: [.answer, .authority, .additional])
    }

    static func cnameTargets(from response: Data) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for record in resourceRecords(from: response, sections: [.answer, .authority, .additional]) {
            guard record.type == 5, let name = readDomainName(response, offset: record.rdataOffset, end: record.rdataOffset + record.rdLength) else {
                continue
            }
            let normalized = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if seen.insert(normalized).inserted { names.append(normalized) }
        }
        return names
    }

    /// Resolve with CNAME chase and multi-provider fallback for WhatsApp/messaging domains.
    static func resolveForMessaging(
        wireQuery: Data,
        queryId: UInt16,
        qname: String,
        settings: AppSettings,
        socksPort: Int,
        httpPort: Int
    ) async throws -> (result: Result, provider: SecureDNSProvider) {
        let chain = MessagingAppsConfiguration.dnsProviderFallbackChain(primary: settings.secureDNSProvider)
        var lastResult: Result?
        var lastProvider = settings.secureDNSProvider
        var lastError: Error?

        for provider in chain {
            var trial = settings
            trial.secureDNSProvider = provider
            do {
                let result = try await resolveChasingCNAME(
                    wireQuery: wireQuery,
                    queryId: queryId,
                    qname: qname,
                    settings: trial,
                    socksPort: socksPort,
                    httpPort: httpPort
                )
                let ips = ipv4Answers(from: result.payload)
                if !ips.isEmpty {
                    if provider != settings.secureDNSProvider {
                        MessagingAppsDiagnostics.logDnsProviderFallback(
                            domain: qname,
                            from: settings.secureDNSProvider,
                            to: provider,
                            reason: "empty_a_record"
                        )
                    }
                    return (result, provider)
                }
                lastResult = result
                lastProvider = provider
                if MessagingAppsConfiguration.isWhatsAppDomain(qname) {
                    SharedLogger.shared.logRaw(
                        "WHATSAPP_DNS_EMPTY_ANSWER",
                        detail: "domain=\(qname) provider=\(provider.rawValue) cnames=\(cnameTargets(from: result.payload).joined(separator: ","))"
                    )
                }
                if let next = chain.dropFirst(chain.firstIndex(of: provider)! + 1).first {
                    MessagingAppsDiagnostics.logDnsProviderFallback(
                        domain: qname,
                        from: provider,
                        to: next,
                        reason: "empty_a_record"
                    )
                }
            } catch {
                lastError = error
                if provider != settings.secureDNSProvider {
                    MessagingAppsDiagnostics.logDnsProviderFallback(
                        domain: qname,
                        from: settings.secureDNSProvider,
                        to: provider,
                        reason: error.localizedDescription
                    )
                }
            }
        }

        if let lastResult {
            return (lastResult, lastProvider)
        }
        throw lastError ?? SecureDNSTransportError.noResolver
    }

    private static func resolveChasingCNAME(
        wireQuery: Data,
        queryId: UInt16,
        qname: String,
        settings: AppSettings,
        socksPort: Int,
        httpPort: Int,
        depth: Int = 0
    ) async throws -> Result {
        let result = try await resolve(
            wireQuery: wireQuery,
            queryId: queryId,
            qname: qname,
            settings: settings,
            socksPort: socksPort,
            httpPort: httpPort
        )
        if !ipv4Answers(from: result.payload).isEmpty || depth >= 4 {
            return result
        }
        guard let cname = cnameTargets(from: result.payload).first else {
            return result
        }
        MessagingAppsDiagnostics.logDnsCnameChase(
            domain: qname,
            cname: cname,
            provider: settings.secureDNSProvider
        )
        let chaseQuery = try buildAQuery(qname: cname, id: queryId)
        return try await resolveChasingCNAME(
            wireQuery: chaseQuery,
            queryId: queryId,
            qname: cname,
            settings: settings,
            socksPort: socksPort,
            httpPort: httpPort,
            depth: depth + 1
        )
    }

    private enum RecordSection {
        case answer
        case authority
        case additional
    }

    private struct ParsedResourceRecord {
        let type: UInt16
        let rdataOffset: Int
        let rdLength: Int
    }

    private static func collectIPv4Records(from response: Data, sections: [RecordSection]) -> [String] {
        var answers: [String] = []
        var seen = Set<String>()
        for record in resourceRecords(from: response, sections: sections) {
            guard record.type == 1, record.rdLength == 4 else { continue }
            let offset = record.rdataOffset
            guard offset + 4 <= response.count else { continue }
            let ip = "\(response[offset]).\(response[offset + 1]).\(response[offset + 2]).\(response[offset + 3])"
            if seen.insert(ip).inserted { answers.append(ip) }
        }
        return answers
    }

    private static func resourceRecords(from response: Data, sections: [RecordSection]) -> [ParsedResourceRecord] {
        guard response.count >= 12 else { return [] }
        let qdCount = Int(readUInt16(response, at: 4))
        let sectionCounts: [RecordSection: Int] = [
            .answer: Int(readUInt16(response, at: 6)),
            .authority: Int(readUInt16(response, at: 8)),
            .additional: Int(readUInt16(response, at: 10)),
        ]
        var offset = 12
        for _ in 0..<qdCount {
            guard skipDomainName(response, offset: &offset), offset + 4 <= response.count else { return [] }
            offset += 4
        }

        var records: [ParsedResourceRecord] = []
        for section in [.answer, .authority, .additional] as [RecordSection] {
            guard sections.contains(section) else {
                offset = skipSection(response, offset: offset, count: sectionCounts[section] ?? 0)
                continue
            }
            let count = sectionCounts[section] ?? 0
            for _ in 0..<count {
                guard skipDomainName(response, offset: &offset), offset + 10 <= response.count else { return records }
                let type = readUInt16(response, at: offset)
                let rdLength = Int(readUInt16(response, at: offset + 8))
                let rdataOffset = offset + 10
                offset += 10
                guard offset + rdLength <= response.count else { return records }
                records.append(ParsedResourceRecord(type: type, rdataOffset: rdataOffset, rdLength: rdLength))
                offset += rdLength
            }
        }
        return records
    }

    private static func skipSection(_ response: Data, offset: Int, count: Int) -> Int {
        var cursor = offset
        for _ in 0..<count {
            guard skipDomainName(response, offset: &cursor), cursor + 10 <= response.count else { return cursor }
            let rdLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10 + rdLength
        }
        return cursor
    }

    private static func readDomainName(_ data: Data, offset start: Int, end: Int) -> String? {
        var offset = start
        var labels: [String] = []
        var jumped = false
        var resumeOffset = 0
        var guardCount = 0
        while offset < end, offset < data.count, guardCount < 128 {
            guardCount += 1
            let len = Int(data[offset])
            if len == 0 {
                offset += 1
                break
            }
            if len & 0xc0 == 0xc0 {
                guard offset + 1 < data.count else { return nil }
                let pointer = Int((UInt16(data[offset] & 0x3f) << 8) | UInt16(data[offset + 1]))
                if !jumped {
                    resumeOffset = offset + 2
                    jumped = true
                }
                offset = pointer
                continue
            }
            guard len < 64, offset + 1 + len <= data.count else { return nil }
            offset += 1
            guard let label = String(data: data.subdata(in: offset ..< (offset + len)), encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            offset += len
        }
        if jumped { offset = resumeOffset }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ".")
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
