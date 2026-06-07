import Darwin
import Foundation
import Network
import NetworkExtension

#if canImport(tun2socks)
import tun2socks
#endif

/// Owns tunnel DNS interception. Secure DNS modes resolve raw DNS wire queries before packets reach tun2socks.
enum TunnelDnsForwarder {
    private static var dnsOkLogCount = 0
    private static var queue: DispatchQueue {
#if canImport(tun2socks)
        TSIPStack.stack.processQueue
#else
        DispatchQueue(label: "com.polamgh.ali.AzadiTunnel.dns", qos: .userInitiated)
#endif
    }

    static func handleIfDnsQuery(
        packet: Data,
        protocolNumber: NSNumber,
        packetFlow: NEPacketTunnelFlow,
        socksHost: String,
        socksPort: Int,
        httpPort: Int
    ) -> Bool {
        let settings = SharedSettingsStore.shared.appSettings
        guard let parsed = parseDnsQuery(packet: packet) else { return false }
        let queryId = SecureDNSResolver.queryId(from: parsed.dnsPayload)
        guard let question = parseQuestion(parsed.dnsPayload) else {
            if settings.secureDNSMode == .doh {
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_BYPASS_DETECTED",
                    detail: "id=\(queryId) reason=unparseable_dns_payload mode=doh"
                )
                if let formerr = buildMalformedDnsErrorResponse(query: parsed.dnsPayload, rcode: 1) {
                    queue.async {
                        let out = buildUdpResponsePacket(from: parsed, dnsPayload: formerr)
                        packetFlow.writePackets([out], withProtocols: [protocolNumber])
                        SharedLogger.shared.logRaw(
                            "DNS_RESPONSE_SENT",
                            detail: "id=\(queryId) secure=false formerr=unparseable_dns_payload"
                        )
                    }
                    return true
                }
            }
            return false
        }

        let dstIP = parsed.dstIP.map(String.init).joined(separator: ".")
        SharedLogger.shared.logRaw(
            "DNS_QUERY_RECEIVED",
            detail: "id=\(queryId) qname=\(question.qname) type=\(dnsTypeName(question.qtype)) qtype=\(question.qtype) dst=\(dstIP):\(parsed.dstPort)"
        )
        SharedLogger.shared.logRaw(
            "DNS_PACKET_RECEIVED",
            detail: "id=\(queryId) qname=\(question.qname) qtype=\(question.qtype) dst=\(dstIP):\(parsed.dstPort)"
        )
        if question.qtype == 28, !SecureDNSConfiguration.isActive(settings) {
            queue.async {
                let empty = buildEmptyNoErrorResponse(query: parsed.dnsPayload, question: question)
                let out = buildUdpResponsePacket(from: parsed, dnsPayload: empty)
                packetFlow.writePackets([out], withProtocols: [protocolNumber])
                SharedLogger.shared.logRaw(
                    "DNS_RESPONSE_SENT",
                    detail: "id=\(queryId) secure=false qtype=AAAA_empty qname=\(question.qname)"
                )
            }
            return true
        }

        if !SecureDNSConfiguration.isActive(settings), question.qtype != 1 {
            return false
        }

        queue.async {
            Task {
                let settings = SharedSettingsStore.shared.appSettings
                do {
                    let (responsePayload, secure) = try await resolve(
                        query: parsed.dnsPayload,
                        question: question,
                        socksHost: socksHost,
                        socksPort: socksPort,
                        httpPort: httpPort,
                        settings: settings,
                        queryId: queryId
                    )
                    let out = buildUdpResponsePacket(from: parsed, dnsPayload: responsePayload)
                    packetFlow.writePackets([out], withProtocols: [protocolNumber])
                    TunnelStatisticsStore.recordPacketBytes(down: 0, up: out.count)
                    dnsOkLogCount += 1
                    SharedLogger.shared.logRaw(
                        "DNS_RESPONSE_SENT",
                        detail: "id=\(queryId) secure=\(secure) bytes=\(responsePayload.count) qname=\(question.qname)"
                    )
                    if dnsOkLogCount <= 3 || dnsOkLogCount % 100 == 0 {
                        SharedLogger.shared.log(.dnsForwardOk, detail: "id=\(queryId) bytes=\(responsePayload.count) n=\(dnsOkLogCount) secure=\(secure)")
                    }
                } catch {
                    SharedLogger.shared.log(.dnsForwardFailed, detail: "id=\(queryId) error=\(error.localizedDescription)")
                    if SecureDNSConfiguration.isActive(settings), settings.blockCleartextDNS {
                        let servfail = buildServFailResponse(query: parsed.dnsPayload, question: question)
                        let out = buildUdpResponsePacket(from: parsed, dnsPayload: servfail)
                        packetFlow.writePackets([out], withProtocols: [protocolNumber])
                        SharedLogger.shared.logRaw(
                            "DNS_RESPONSE_SENT",
                            detail: "id=\(queryId) secure=false servfail=blocked_cleartext qname=\(question.qname)"
                        )
                    }
                }
            }
        }
        return true
    }

    static func runTest(
        socksHost: String,
        socksPort: Int,
        httpPort: Int
    ) async -> (ok: Bool, detail: String) {
        let settings = SharedSettingsStore.shared.appSettings
        SharedLogger.shared.log(
            .secureDnsTestStarted,
            detail: "mode=\(settings.secureDNSMode.rawValue) provider=\(settings.secureDNSProvider.rawValue)"
        )
        guard settings.secureDNSMode != .off else {
            let detail = "mode=off"
            SharedLogger.shared.log(.secureDnsTestFailed, detail: detail)
            return (false, detail)
        }

        let query = SecureDNSConfiguration.exampleComWireQuery
        guard let question = parseQuestion(query) else {
            let detail = "reason=bad_test_query"
            SharedLogger.shared.log(.secureDnsTestFailed, detail: detail)
            return (false, detail)
        }

        let queryId = SecureDNSResolver.queryId(from: query)
        SharedLogger.shared.logRaw(
            "DNS_QUERY_RECEIVED",
            detail: "id=\(queryId) qname=\(question.qname) type=\(dnsTypeName(question.qtype)) qtype=\(question.qtype) source=test"
        )

        do {
            let (payload, secure) = try await resolve(
                query: query,
                question: question,
                socksHost: socksHost,
                socksPort: socksPort,
                httpPort: httpPort,
                settings: settings,
                queryId: queryId
            )
            let parsed = ParsedQuery(
                ipHeaderLength: 20,
                srcIP: [10, 0, 0, 2],
                dstIP: [10, 0, 0, 1],
                srcPort: 53_000,
                dstPort: 53,
                dnsPayload: query
            )
            let packet = buildUdpResponsePacket(from: parsed, dnsPayload: payload)
            SharedLogger.shared.logRaw(
                "DNS_RESPONSE_SENT",
                detail: "id=\(queryId) secure=\(secure) bytes=\(payload.count) qname=\(question.qname) source=test packet_bytes=\(packet.count)"
            )

            guard secure else {
                let detail = "legacy_fallback bytes=\(payload.count)"
                SharedLogger.shared.log(.secureDnsTestFailed, detail: detail)
                return (false, detail)
            }
            let detail = "bytes=\(payload.count) secure=true"
            SharedLogger.shared.log(.secureDnsTestOk, detail: detail)
            SharedSettingsStore.shared.secureDNSWarning = nil
            return (true, detail)
        } catch {
            if settings.blockCleartextDNS {
                let servfail = buildServFailResponse(query: query, question: question)
                SharedLogger.shared.logRaw(
                    "DNS_RESPONSE_SENT",
                    detail: "id=\(queryId) secure=false servfail=blocked_cleartext qname=\(question.qname) source=test bytes=\(servfail.count)"
                )
            }
            let detail = "reason=\(error.localizedDescription)"
            SharedLogger.shared.log(.secureDnsTestFailed, detail: detail)
            return (false, detail)
        }
    }

    private struct ParsedQuery {
        let ipHeaderLength: Int
        let srcIP: [UInt8]
        let dstIP: [UInt8]
        let srcPort: UInt16
        let dstPort: UInt16
        let dnsPayload: Data
    }

    private struct ParsedQuestion {
        let questionEnd: Int
        let qtype: UInt16
        let qname: String
    }

    private static func parseDnsQuery(packet: Data) -> ParsedQuery? {
        guard packet.count >= 28, packet[0] >> 4 == 4 else { return nil }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard packet.count >= ihl + 8, packet[9] == 17 else { return nil }
        let udpOffset = ihl
        let dstPort = UInt16(packet[udpOffset + 2]) << 8 | UInt16(packet[udpOffset + 3])
        guard dstPort == 53 else { return nil }
        let udpLen = Int(UInt16(packet[udpOffset + 4]) << 8 | UInt16(packet[udpOffset + 5]))
        let dnsOffset = udpOffset + 8
        guard udpLen >= 8, packet.count >= dnsOffset + (udpLen - 8) else { return nil }
        return ParsedQuery(
            ipHeaderLength: ihl,
            srcIP: Array(packet[12 ..< 16]),
            dstIP: Array(packet[16 ..< 20]),
            srcPort: UInt16(packet[udpOffset]) << 8 | UInt16(packet[udpOffset + 1]),
            dstPort: dstPort,
            dnsPayload: packet.subdata(in: dnsOffset ..< (dnsOffset + udpLen - 8))
        )
    }

    private static func parseQuestion(_ payload: Data) -> ParsedQuestion? {
        guard payload.count >= 12 else { return nil }
        var offset = 12
        guard let name = readDomainName(payload, offset: &offset) else { return nil }
        guard offset + 4 <= payload.count else { return nil }
        let qtype = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
        return ParsedQuestion(questionEnd: offset + 4, qtype: qtype, qname: name)
    }

    private static func readDomainName(_ payload: Data, offset: inout Int) -> String? {
        var labels: [String] = []
        var jumped = false
        var resumeOffset = 0
        var guardCount = 0
        while offset < payload.count, guardCount < 128 {
            guardCount += 1
            let len = Int(payload[offset])
            if len == 0 {
                offset += 1
                break
            }
            if len & 0xc0 == 0xc0 {
                guard offset + 1 < payload.count else { return nil }
                let pointer = Int((UInt16(payload[offset] & 0x3f) << 8) | UInt16(payload[offset + 1]))
                if !jumped {
                    resumeOffset = offset + 2
                    jumped = true
                }
                offset = pointer
                continue
            }
            guard len < 64, offset + 1 + len <= payload.count else { return nil }
            offset += 1
            guard let label = String(data: payload.subdata(in: offset ..< (offset + len)), encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            offset += len
        }
        if jumped { offset = resumeOffset }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ".")
    }

    private static func resolve(
        query: Data,
        question: ParsedQuestion,
        socksHost: String,
        socksPort: Int,
        httpPort: Int,
        settings: AppSettings,
        queryId: UInt16
    ) async throws -> (Data, Bool) {
        if SecureDNSConfiguration.isActive(settings) {
            do {
                let result = try await SecureDNSResolver.resolve(
                    wireQuery: query,
                    queryId: queryId,
                    qname: question.qname,
                    settings: settings,
                    socksPort: socksPort,
                    httpPort: httpPort
                )
                SharedSettingsStore.shared.secureDNSWarning = nil
                return (result.payload, result.usedSecurePath)
            } catch {
                if settings.blockCleartextDNS {
                    SharedLogger.shared.log(.secureDnsCleartextBlocked, detail: "id=\(queryId) reason=\(error.localizedDescription)")
                    SharedSettingsStore.shared.secureDNSWarning = "blocked"
                    throw error
                }
                SharedLogger.shared.logRaw(
                    "DNS_LEGACY_FALLBACK",
                    detail: "id=\(queryId) qname=\(question.qname) reason=\(error.localizedDescription)"
                )
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_FALLBACK_TO_LEGACY",
                    detail: "id=\(queryId) reason=\(error.localizedDescription) qname=\(question.qname)"
                )
                let legacy = try await resolveLegacy(
                    query: query,
                    question: question,
                    socksHost: socksHost,
                    socksPort: socksPort,
                    httpPort: httpPort
                )
                return (legacy, false)
            }
        }
        let legacy = try await resolveLegacy(
            query: query,
            question: question,
            socksHost: socksHost,
            socksPort: socksPort,
            httpPort: httpPort
        )
        return (legacy, false)
    }

    private static func dnsTypeName(_ qtype: UInt16) -> String {
        switch qtype {
        case 1: return "A"
        case 2: return "NS"
        case 5: return "CNAME"
        case 15: return "MX"
        case 16: return "TXT"
        case 28: return "AAAA"
        case 65: return "HTTPS"
        default: return "TYPE\(qtype)"
        }
    }

    private static func resolveLegacy(
        query: Data,
        question: ParsedQuestion,
        socksHost: String,
        socksPort: Int,
        httpPort: Int
    ) async throws -> Data {
        guard question.qtype == 1 || question.qtype == 28 else {
            return buildEmptyNoErrorResponse(query: query, question: question)
        }

        let typeToken = question.qtype == 28 ? "AAAA" : "A"
        var components = URLComponents()
        components.scheme = "http"
        components.host = "dns.google"
        components.path = "/resolve"
        let qname = question.qname.hasSuffix(".") ? String(question.qname.dropLast()) : question.qname
        components.queryItems = [
            URLQueryItem(name: "name", value: qname),
            URLQueryItem(name: "type", value: typeToken)
        ]
        guard let url = components.url else {
            SharedLogger.shared.log(.dnsForwardFailed, detail: "bad_url name=\(qname)")
            throw URLError(.badURL)
        }

        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        let backends: [(host: String, path: String)] = [
            ("dns.google", path)
        ]

        var lastError: Error = URLError(.cannotFindHost)
#if canImport(tun2socks)
        if socksPort > 0 {
            for resolver in ["9.9.9.9", "208.67.222.222"] {
                do {
                    let payload = try await Socks5TCPClient.tcpDnsQuery(
                        query: query,
                        resolverIPv4: resolver,
                        proxyHost: socksHost,
                        proxyPort: socksPort
                    )
                    return payload
                } catch {
                    lastError = error
                }
            }
        }
#endif
        for backend in backends {
#if canImport(tun2socks)
            if socksPort > 0 {
                do {
                    let body = try await PsiphonSocksHTTPGet.get(
                        path: backend.path,
                        host: backend.host,
                        port: 80,
                        socksPort: socksPort
                    )
                    return try buildDnsResponse(query: query, question: question, json: body)
                } catch {
                    lastError = error
                }
            }
#endif
            if httpPort > 0 {
                do {
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = backend.host
                    components.path = url.path
                    components.queryItems = [
                        URLQueryItem(name: "name", value: qname),
                        URLQueryItem(name: "type", value: typeToken)
                    ]
                    if let absolute = components.url?.absoluteString {
                        let body = try await TunnelHttpProxyClient.get(url: absolute, proxyPort: httpPort)
                        return try buildDnsResponse(query: query, question: question, json: body)
                    }
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private static func buildDnsResponse(query: Data, question: ParsedQuestion, json: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let status = object["Status"] as? Int, status == 0,
              let answers = object["Answer"] as? [[String: Any]], !answers.isEmpty else {
            throw URLError(.cannotFindHost)
        }
        var rdataBlocks: [Data] = []
        for answer in answers {
            guard let data = answer["data"] as? String else { continue }
            if question.qtype == 1, let ipv4 = ipv4Data(data) {
                rdataBlocks.append(ipv4)
            } else if question.qtype == 28, let ipv6 = ipv6Data(data) {
                rdataBlocks.append(ipv6)
            }
        }
        guard !rdataBlocks.isEmpty else { throw URLError(.cannotFindHost) }
        return buildDnsResponse(query: query, question: question, rdataBlocks: rdataBlocks)
    }

    private static func ipv4Data(_ string: String) -> Data? {
        var addr = in_addr()
        guard string.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Data($0) }
    }

    private static func ipv6Data(_ string: String) -> Data? {
        var addr = in6_addr()
        guard string.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Data($0) }
    }

    private static func buildServFailResponse(query: Data, question: ParsedQuestion) -> Data {
        var response = Data(query.prefix(question.questionEnd))
        response[2] = 0x81
        response[3] = 0x82 // SERVFAIL
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }

    private static func buildMalformedDnsErrorResponse(query: Data, rcode: UInt8) -> Data? {
        guard query.count >= 12 else { return nil }
        var response = query
        response[2] = 0x81
        response[3] = (response[3] & 0xf0) | (rcode & 0x0f)
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }

    private static func buildEmptyNoErrorResponse(query: Data, question: ParsedQuestion) -> Data {
        var response = Data(query.prefix(question.questionEnd))
        response[2] = 0x81
        // NOERROR, zero answers. For AAAA this nudges Happy Eyeballs to IPv4; for HTTPS/SVCB
        // fallback it avoids emitting invalid typed answers when legacy DNS only has A/AAAA data.
        response[3] = 0x80
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }

    private static func buildDnsResponse(
        query: Data,
        question: ParsedQuestion,
        rdataBlocks: [Data]
    ) -> Data {
        var response = Data(query.prefix(question.questionEnd))
        response[2] = 0x81
        response[3] = 0x80
        response[6] = 0
        response[7] = UInt8(rdataBlocks.count)
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        let ttl: UInt32 = 120
        for rdata in rdataBlocks {
            response.append(contentsOf: [0xc0, 0x0c])
            response.append(UInt8(question.qtype >> 8))
            response.append(UInt8(question.qtype & 0xff))
            response.append(contentsOf: [0x00, 0x01])
            response.append(UInt8(ttl >> 24))
            response.append(UInt8((ttl >> 16) & 0xff))
            response.append(UInt8((ttl >> 8) & 0xff))
            response.append(UInt8(ttl & 0xff))
            let rdlen = UInt16(rdata.count)
            response.append(UInt8(rdlen >> 8))
            response.append(UInt8(rdlen & 0xff))
            response.append(rdata)
        }
        return response
    }

    private static func buildUdpResponsePacket(from query: ParsedQuery, dnsPayload: Data) -> Data {
        let udpLen = 8 + dnsPayload.count
        var packet = Data(count: query.ipHeaderLength + udpLen)
        packet[0] = UInt8(query.ipHeaderLength / 4) << 4 | 0x05
        let totalLen = UInt16(packet.count)
        packet[2] = UInt8(totalLen >> 8)
        packet[3] = UInt8(totalLen & 0xff)
        packet[4] = 64
        packet[8] = 17
        packet[12] = query.dstIP[0]
        packet[13] = query.dstIP[1]
        packet[14] = query.dstIP[2]
        packet[15] = query.dstIP[3]
        packet[16] = query.srcIP[0]
        packet[17] = query.srcIP[1]
        packet[18] = query.srcIP[2]
        packet[19] = query.srcIP[3]
        let ipChecksum = internetChecksum(data: packet, offset: 0, length: query.ipHeaderLength)
        packet[10] = UInt8(ipChecksum >> 8)
        packet[11] = UInt8(ipChecksum & 0xff)
        let u = query.ipHeaderLength
        packet[u] = UInt8(query.dstPort >> 8)
        packet[u + 1] = UInt8(query.dstPort & 0xff)
        packet[u + 2] = UInt8(query.srcPort >> 8)
        packet[u + 3] = UInt8(query.srcPort & 0xff)
        packet[u + 4] = UInt8(udpLen >> 8)
        packet[u + 5] = UInt8(udpLen & 0xff)
        dnsPayload.withUnsafeBytes { raw in
            packet.replaceSubrange((u + 8)..<packet.count, with: raw)
        }
        return packet
    }

    private static func internetChecksum(data: Data, offset: Int, length: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = offset
        let end = offset + length
        while i + 1 < end {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < end { sum += UInt32(data[i]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
}
