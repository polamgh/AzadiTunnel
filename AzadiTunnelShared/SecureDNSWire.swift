import Foundation

/// Errors raised while parsing or validating DNS wire messages.
enum SecureDNSWireError: Error, Equatable, LocalizedError {
    case truncated
    case invalidHeader
    case invalidName
    case invalidQuestion
    case invalidRecord
    case responseIDMismatch
    case responseIsNotAResponse
    case responseQuestionMismatch
    case responseOpcodeMismatch

    var errorDescription: String? {
        switch self {
        case .truncated: return "dns_truncated"
        case .invalidHeader: return "dns_invalid_header"
        case .invalidName: return "dns_invalid_name"
        case .invalidQuestion: return "dns_invalid_question"
        case .invalidRecord: return "dns_invalid_record"
        case .responseIDMismatch: return "dns_response_id_mismatch"
        case .responseIsNotAResponse: return "dns_response_qr_invalid"
        case .responseQuestionMismatch: return "dns_response_question_mismatch"
        case .responseOpcodeMismatch: return "dns_response_opcode_mismatch"
        }
    }
}

/// Small, allocation-bounded DNS wire parser used by the DoH resolver and its cache.
///
/// The resolver never interprets an answer into an A-only model. It forwards the complete
/// validated wire response, so TXT, MX, CNAME, HTTPS/SVCB, and future record types retain their
/// original RDATA and section ordering.
enum SecureDNSWire {
    enum ResponsePolicy: Equatable {
        case positive
        case negative
        case passThrough
    }

    struct Question: Equatable {
        let name: String
        let type: UInt16
        let klass: UInt16
    }

    struct ResourceRecord {
        let name: String
        let type: UInt16
        let klass: UInt16
        let ttl: UInt32
        let rdata: Data
        let rdataRange: Range<Int>
    }

    struct Message {
        let id: UInt16
        let flags: UInt16
        let questionEnd: Int
        let questions: [Question]
        let answers: [ResourceRecord]
        let authorities: [ResourceRecord]
        let additionals: [ResourceRecord]
        let wire: Data

        var isResponse: Bool { flags & 0x8000 != 0 }
        var opcode: UInt8 { UInt8((flags >> 11) & 0x0f) }
        var rcode: UInt8 { UInt8(flags & 0x000f) }
    }

    private static let maxRecords = 8_192
    private static let maxNamePointers = 128

    static func parse(_ data: Data) throws -> Message {
        guard data.count >= 12 else { throw SecureDNSWireError.truncated }

        let id = readUInt16(data, at: 0)
        let flags = readUInt16(data, at: 2)
        let questionCount = Int(readUInt16(data, at: 4))
        let answerCount = Int(readUInt16(data, at: 6))
        let authorityCount = Int(readUInt16(data, at: 8))
        let additionalCount = Int(readUInt16(data, at: 10))
        guard questionCount > 0, questionCount + answerCount + authorityCount + additionalCount <= maxRecords else {
            throw SecureDNSWireError.invalidHeader
        }

        var offset = 12
        var questions: [Question] = []
        questions.reserveCapacity(questionCount)
        for _ in 0..<questionCount {
            let (name, next) = try readName(data, offset: offset)
            guard next + 4 <= data.count else { throw SecureDNSWireError.invalidQuestion }
            let type = readUInt16(data, at: next)
            let klass = readUInt16(data, at: next + 2)
            questions.append(Question(name: canonicalName(name), type: type, klass: klass))
            offset = next + 4
        }

        let questionEnd = offset
        let answers = try readRecords(data, offset: &offset, count: answerCount)
        let authorities = try readRecords(data, offset: &offset, count: authorityCount)
        let additionals = try readRecords(data, offset: &offset, count: additionalCount)
        // A DNS message has no uncounted trailer. Rejecting trailing bytes prevents an HTTP
        // response body from being accepted as a valid wire response with an ignored suffix.
        guard offset == data.count else { throw SecureDNSWireError.invalidRecord }

        return Message(
            id: id,
            flags: flags,
            questionEnd: questionEnd,
            questions: questions,
            answers: answers,
            authorities: authorities,
            additionals: additionals,
            wire: data
        )
    }

    /// Validates the response envelope and question against the exact query sent to DoH.
    /// NXDOMAIN, NODATA, SERVFAIL, and other valid DNS rcodes are returned intact; they are not
    /// mistaken for transport failures.
    @discardableResult
    static func validateResponse(_ response: Data, for query: Data, expectedID: UInt16? = nil) throws -> Message {
        let queryMessage = try parse(query)
        let responseMessage = try parse(response)
        let expected = expectedID ?? queryMessage.id

        guard responseMessage.id == expected else { throw SecureDNSWireError.responseIDMismatch }
        guard !queryMessage.isResponse, responseMessage.isResponse else {
            throw SecureDNSWireError.responseIsNotAResponse
        }
        guard responseMessage.opcode == queryMessage.opcode else {
            throw SecureDNSWireError.responseOpcodeMismatch
        }
        guard responseMessage.questions == queryMessage.questions else {
            throw SecureDNSWireError.responseQuestionMismatch
        }
        // All four-bit DNS RCODE values are valid wire values. They are intentionally accepted
        // and forwarded intact; only the cache policy below distinguishes positive, negative,
        // and transport/application error responses.
        guard isValidRcode(responseMessage.rcode) else {
            throw SecureDNSWireError.invalidHeader
        }
        return responseMessage
    }

    static func isValidRcode(_ rcode: UInt8) -> Bool {
        rcode <= 0x0f
    }

    static func responsePolicy(for message: Message) -> ResponsePolicy {
        guard message.rcode == 0 else {
            return message.rcode == 3 ? .negative : .passThrough
        }
        return message.answers.isEmpty ? .negative : .positive
    }

    static func cacheKey(for query: Data) throws -> Data {
        _ = try parse(query)
        guard query.count >= 2 else { throw SecureDNSWireError.truncated }
        // Transaction IDs are per-request and must not split otherwise identical cache entries.
        return Data(query.dropFirst(2))
    }

    static func responseWithID(_ response: Data, id: UInt16) throws -> Data {
        guard response.count >= 2 else { throw SecureDNSWireError.truncated }
        var copy = response
        copy[0] = UInt8(id >> 8)
        copy[1] = UInt8(id & 0xff)
        return copy
    }

    /// Builds a DNS error while retaining a valid query's complete question section. If the
    /// incoming payload is malformed, only its transaction ID and the twelve-byte header survive.
    static func errorResponse(for query: Data, rcode: UInt8) -> Data? {
        guard query.count >= 12, isValidRcode(rcode) else { return nil }
        let parsed = try? parse(query)
        let questionEnd = parsed?.questionEnd ?? 12
        var response = Data(query.prefix(questionEnd))
        let queryFlags = readUInt16(query, at: 2)
        // Preserve only the request's opcode, RD, and CD bits. Never echo QR/AA/TC/Z/AD from a
        // malformed or adversarial request into a response assembled with zero record counts.
        var flags = (queryFlags & 0x7910) | 0x8000 | 0x0080
        flags = (flags & 0xfff0) | UInt16(rcode)
        response[2] = UInt8(flags >> 8)
        response[3] = UInt8(flags & 0xff)
        let questionCount = parsed.map { UInt16($0.questions.count) } ?? 0
        response[4] = UInt8(questionCount >> 8)
        response[5] = UInt8(questionCount & 0xff)
        for index in 6..<12 { response[index] = 0 }
        return response
    }

    /// Returns a bounded positive or negative cache lifetime. A zero TTL is never cached.
    static func cacheLifetime(for message: Message) -> TimeInterval? {
        if responsePolicy(for: message) == .negative {
            guard let negative = negativeTTL(from: message), negative > 0 else { return nil }
            return min(TimeInterval(negative), 60)
        }

        guard responsePolicy(for: message) == .positive else { return nil }
        let ttl = message.answers.map { UInt64($0.ttl) }.min() ?? 0
        guard ttl > 0 else { return nil }
        return min(TimeInterval(ttl), 600)
    }

    static func canonicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "." : trimmed.lowercased()
    }

    private static func negativeTTL(from message: Message) -> UInt32? {
        guard let soa = message.authorities.first(where: { $0.type == 6 && $0.klass == 1 }) else {
            return nil
        }

        let range = soa.rdataRange
        guard let (_, afterMName) = try? readName(message.wire, offset: range.lowerBound),
              let (_, afterRName) = try? readName(message.wire, offset: afterMName),
              afterRName + 20 <= range.upperBound,
              afterRName + 20 <= message.wire.count else {
            return nil
        }
        let minimum = readUInt32(message.wire, at: afterRName + 16)
        return min(soa.ttl, minimum)
    }

    private static func readRecords(
        _ data: Data,
        offset: inout Int,
        count: Int
    ) throws -> [ResourceRecord] {
        var records: [ResourceRecord] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            let (name, next) = try readName(data, offset: offset)
            guard next + 10 <= data.count else { throw SecureDNSWireError.invalidRecord }
            let type = readUInt16(data, at: next)
            let klass = readUInt16(data, at: next + 2)
            let ttl = readUInt32(data, at: next + 4)
            let rdLength = Int(readUInt16(data, at: next + 8))
            let rdataStart = next + 10
            let rdataEnd = rdataStart + rdLength
            guard rdataEnd >= rdataStart, rdataEnd <= data.count else {
                throw SecureDNSWireError.invalidRecord
            }
            records.append(
                ResourceRecord(
                    name: canonicalName(name),
                    type: type,
                    klass: klass,
                    ttl: ttl,
                    rdata: data.subdata(in: rdataStart..<rdataEnd),
                    rdataRange: rdataStart..<rdataEnd
                )
            )
            offset = rdataEnd
        }
        return records
    }

    private static func readName(
        _ data: Data,
        offset start: Int,
        limit: Int? = nil
    ) throws -> (String, Int) {
        guard start >= 0, start < data.count else { throw SecureDNSWireError.invalidName }

        var cursor = start
        var nextOffset = start
        var jumped = false
        var labels: [String] = []
        var visited = Set<Int>()
        var pointerCount = 0
        var cursorLimit = min(limit ?? data.count, data.count)

        while pointerCount < maxNamePointers {
            guard cursor >= 0, cursor < data.count, cursor < cursorLimit else {
                throw SecureDNSWireError.invalidName
            }
            let length = Int(data[cursor])
            if length == 0 {
                if !jumped { nextOffset = cursor + 1 }
                return (labels.isEmpty ? "." : labels.joined(separator: "."), nextOffset)
            }

            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < data.count, cursor + 1 < cursorLimit else {
                    throw SecureDNSWireError.invalidName
                }
                let pointer = Int((UInt16(data[cursor] & 0x3f) << 8) | UInt16(data[cursor + 1]))
                guard pointer < data.count, visited.insert(pointer).inserted else {
                    throw SecureDNSWireError.invalidName
                }
                if !jumped {
                    nextOffset = cursor + 2
                    jumped = true
                }
                cursor = pointer
                cursorLimit = data.count
                pointerCount += 1
                continue
            }

            guard length <= 63, cursor + 1 + length <= data.count, cursor + 1 + length <= cursorLimit else {
                throw SecureDNSWireError.invalidName
            }
            let labelStart = cursor + 1
            let labelEnd = labelStart + length
            guard let label = String(data: data.subdata(in: labelStart..<labelEnd), encoding: .utf8) else {
                throw SecureDNSWireError.invalidName
            }
            labels.append(label)
            cursor = labelEnd
        }

        throw SecureDNSWireError.invalidName
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
