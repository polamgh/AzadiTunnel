import Foundation

/// Standalone wire/cache tests so the resolver core can be exercised without a live VPN or a
/// Psiphon framework. `Scripts/secure-dns-tests.sh` compiles and runs this file on macOS.
@main
struct SecureDNSResolverTests {
    static func main() async {
        testAllSupportedQuestionTypes()
        testMalformedAndMismatchedResponses()
        testNXDOMAINAndTTLExtraction()
        testBootstrapPlan()
        await testCacheExpiryAndBounds()
        await testFailoverBehavior()
        await testCoalescingAndCancellation()
        print("SecureDNSResolverTests: PASS")
    }

    private static func testAllSupportedQuestionTypes() {
        let types: [UInt16] = [1, 28, 5, 15, 16, 64, 65]
        for (index, type) in types.enumerated() {
            let query = makeQuery(id: UInt16(index + 1), type: type)
            let response = makeAnswerResponse(query: query, type: type, ttl: 30, rdata: rdata(for: type))
            let parsed = tryOrFail { try SecureDNSWire.validateResponse(response, for: query) }
            precondition(parsed.answers.count == 1, "typed answer was not retained")
            precondition(parsed.answers[0].type == type, "qtype (type) was rewritten")
            precondition(parsed.answers[0].rdata == rdata(for: type), "qtype (type) RDATA changed")
        }

        let original = makeAnswerResponse(
            query: makeQuery(id: 0x1111, type: 16),
            type: 16,
            ttl: 10,
            rdata: rdata(for: 16)
        )
        let patched = tryOrFail { try SecureDNSWire.responseWithID(original, id: 0x2222) }
        let patchedQuery = makeQuery(id: 0x2222, type: 16)
        _ = tryOrFail { try SecureDNSWire.validateResponse(patched, for: patchedQuery) }
    }

    private static func testMalformedAndMismatchedResponses() {
        let query = makeQuery(id: 7, type: 1)
        let valid = makeAnswerResponse(query: query, type: 1, ttl: 20, rdata: Data([1, 2, 3, 4]))

        expectWireError(.responseIDMismatch) {
            let wrongID = try SecureDNSWire.responseWithID(valid, id: 8)
            _ = try SecureDNSWire.validateResponse(wrongID, for: query)
        }
        expectWireError(.responseIsNotAResponse) {
            var notResponse = valid
            notResponse[2] &= 0x7f
            _ = try SecureDNSWire.validateResponse(notResponse, for: query)
        }
        expectWireError(.responseQuestionMismatch) {
            let wrongQuestion = makeAnswerResponse(
                query: makeQuery(id: 7, type: 28),
                type: 28,
                ttl: 20,
                rdata: Data(repeating: 0, count: 16)
            )
            _ = try SecureDNSWire.validateResponse(wrongQuestion, for: query)
        }
        expectWireError(.invalidRecord) {
            var truncated = valid
            truncated.removeLast()
            _ = try SecureDNSWire.validateResponse(truncated, for: query)
        }

        for code in [UInt8(0), 1, 2, 3, 4, 5, 15] {
            let response = makeRcodeResponse(query: query, rcode: code)
            let parsed = tryOrFail { try SecureDNSWire.validateResponse(response, for: query) }
            precondition(parsed.rcode == code, "rcode was not preserved")
            if code == 0 || code == 3 {
                precondition(SecureDNSWire.responsePolicy(for: parsed) == .negative)
            } else {
                precondition(SecureDNSWire.responsePolicy(for: parsed) == .passThrough)
            }
        }

        let ednsQuery = makeQueryWithEDNS(id: 0x1234, type: 65)
        let parsedEDNSQuery = tryOrFail { try SecureDNSWire.parse(ednsQuery) }
        precondition(parsedEDNSQuery.questionEnd < ednsQuery.count)
        let ednsError = tryOrFail {
            try unwrap(SecureDNSWire.errorResponse(for: ednsQuery, rcode: 2))
        }
        precondition(ednsError.count == parsedEDNSQuery.questionEnd, "error copied EDNS bytes")
        let parsedError = tryOrFail { try SecureDNSWire.parse(ednsError) }
        precondition(parsedError.answers.isEmpty && parsedError.authorities.isEmpty && parsedError.additionals.isEmpty)
        precondition(SecureDNSWire.errorResponse(for: ednsQuery, rcode: 16) == nil)
    }

    private static func testNXDOMAINAndTTLExtraction() {
        let query = makeQuery(id: 12, type: 65)
        let nxdomain = makeNXDOMAINResponse(query: query, soaTTL: 120, minimumTTL: 17)
        let parsed = tryOrFail { try SecureDNSWire.validateResponse(nxdomain, for: query) }
        precondition(parsed.rcode == 3, "NXDOMAIN was not preserved")
        precondition(SecureDNSWire.cacheLifetime(for: parsed) == 17, "negative TTL was not derived from SOA")

        let positive = makeAnswerResponse(query: query, type: 65, ttl: 9, rdata: rdata(for: 65))
        let positiveMessage = tryOrFail { try SecureDNSWire.validateResponse(positive, for: query) }
        precondition(SecureDNSWire.cacheLifetime(for: positiveMessage) == 9, "positive TTL was not retained")
    }

    private static func testCacheExpiryAndBounds() async {
        let cache = SecureDNSCache(maxEntries: 2, maxBytes: 128)
        let start: TimeInterval = 10_000
        let keyA = Data([0x01])
        let keyB = Data([0x02])
        let keyC = Data([0x03])
        let response = Data(repeating: 0x42, count: 20)

        await cache.insert(response: response, for: keyA, lifetime: 2, now: start)
        let liveValue = await cache.value(for: keyA, now: start + 1)
        precondition(liveValue == response)
        let expiredValue = await cache.value(for: keyA, now: start + 3)
        precondition(expiredValue == nil)

        await cache.insert(response: response, for: keyA, lifetime: 30, now: start)
        await cache.insert(response: response, for: keyB, lifetime: 30, now: start)
        _ = await cache.value(for: keyA, now: start + 1)
        await cache.insert(response: response, for: keyC, lifetime: 30, now: start + 2)
        let entryCount = await cache.count(now: start + 2)
        precondition(entryCount == 2, "entry bound failed")
        let retainedValue = await cache.value(for: keyA, now: start + 2)
        precondition(retainedValue == response, "LRU eviction ignored recency")
        let evictedValue = await cache.value(for: keyB, now: start + 2)
        precondition(evictedValue == nil, "oldest entry was not evicted")
    }

    private static func testBootstrapPlan() {
        let host = "cloudflare-dns.com"
        let targets = SecureDNSBootstrap.targets(
            endpointHost: host,
            bootstrapIPs: ["1.1.1.1", "1.0.0.1", "1.1.1.1"]
        )
        precondition(targets.map(\.connectHost) == [host, "1.1.1.1", "1.0.0.1"])
        precondition(targets.allSatisfy { $0.tlsServerName == host && !$0.usesSystemResolver })

        let custom = SecureDNSBootstrap.targets(endpointHost: "resolver.example", bootstrapIPs: [])
        precondition(custom.map(\.connectHost) == ["resolver.example"])
        precondition(custom[0].tlsServerName == "resolver.example")
    }

    private static func testFailoverBehavior() async {
        let recorder = AttemptRecorder()
        let start = SecureDNSMonotonicClock.now
        let value: String
        do {
            value = try await SecureDNSFailoverPolicy.perform(
                endpoints: ["timeout", "success"],
                perAttemptTimeout: 0.04,
                totalTimeout: 0.08
            ) { endpoint, _, _ in
                await recorder.record(endpoint)
                if endpoint == "timeout" {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                return "ok"
            }
        } catch {
            preconditionFailure("failover did not reach healthy endpoint: \(error)")
        }
        let elapsed = SecureDNSMonotonicClock.now - start
        precondition(value == "ok")
        let attempts = await recorder.values()
        precondition(attempts == ["timeout", "success"])
        precondition(elapsed < 0.25, "timeout attempt exceeded bounded budget")

        do {
            _ = try await SecureDNSFailoverPolicy.perform(
                endpoints: ["a", "b", "c"],
                perAttemptTimeout: 0.03,
                totalTimeout: 0.06
            ) { _, _, _ in
                try await Task.sleep(nanoseconds: 500_000_000)
                return "unreachable"
            }
            preconditionFailure("all timeout attempts unexpectedly succeeded")
        } catch let error as SecureDNSFailoverPolicy.Error {
            precondition(error == .attemptTimedOut)
        } catch {
            preconditionFailure("unexpected failover error: \(error)")
        }
    }

    private static func testCoalescingAndCancellation() async {
        let coordinator = SecureDNSResolutionCoordinator<Int>()
        let recorder = AttemptRecorder()
        let key = Data([0x55])
        let first = Task<Int, Error> {
            try await coordinator.value(for: key) {
                await recorder.record("producer")
                try await Task.sleep(nanoseconds: 50_000_000)
                return 42
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        let second = Task<Int, Error> {
            try await coordinator.value(for: key) {
                await recorder.record("duplicate")
                return 7
            }
        }
        let firstValue = await tryOrFailAsync { try await first.value }
        let secondValue = await tryOrFailAsync { try await second.value }
        precondition(firstValue == 42 && secondValue == 42, "coalesced callers diverged")
        let calls = await recorder.values()
        precondition(calls == ["producer"], "duplicate resolver work was started")

        let cancelled = Task<Int, Error> {
            try await coordinator.value(for: Data([0x56])) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await coordinator.cancelAll()
        do {
            _ = try await cancelled.value
            preconditionFailure("cancelAll did not cancel the producer")
        } catch {
            precondition(error is CancellationError)
        }
        let inFlightCount = await coordinator.count
        precondition(inFlightCount == 0)
    }
    private static func makeQuery(id: UInt16, type: UInt16) -> Data {
        let data = Data([
            UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
            0x03, 0x63, 0x6f, 0x6d, 0x00,
            UInt8(type >> 8), UInt8(type & 0xff), 0x00, 0x01,
        ])
        return data
    }

    private static func makeAnswerResponse(query: Data, type: UInt16, ttl: UInt32, rdata: Data) -> Data {
        var response = query
        response[2] = 0x81
        response[3] = 0x80
        response[6] = 0
        response[7] = 1
        response.append(contentsOf: [0xc0, 0x0c])
        appendUInt16(type, to: &response)
        response.append(contentsOf: [0x00, 0x01])
        appendUInt32(ttl, to: &response)
        appendUInt16(UInt16(rdata.count), to: &response)
        response.append(rdata)
        return response
    }

    private static func makeRcodeResponse(query: Data, rcode: UInt8) -> Data {
        var response = query
        response[2] = 0x81
        response[3] = 0x80 | (rcode & 0x0f)
        return response
    }

    private static func makeQueryWithEDNS(id: UInt16, type: UInt16) -> Data {
        var query = makeQuery(id: id, type: type)
        query[10] = 0
        query[11] = 1
        query.append(contentsOf: [
            0x00, // root owner name
            0x00, 0x29, // OPT
            0x04, 0xd0, // UDP payload size 1232
            0x00, 0x00, 0x00, 0x00, // extended RCODE/version/flags
            0x00, 0x00 // RDLEN
        ])
        return query
    }

    private static func makeNXDOMAINResponse(query: Data, soaTTL: UInt32, minimumTTL: UInt32) -> Data {
        var soa = Data([0x00]) // MNAME root
        soa.append(0x00) // RNAME root
        appendUInt32(1, to: &soa)
        appendUInt32(2, to: &soa)
        appendUInt32(3, to: &soa)
        appendUInt32(4, to: &soa)
        appendUInt32(minimumTTL, to: &soa)
        var base = query
        base[2] = 0x81
        base[3] = 0x83
        base[6] = 0
        base[7] = 0
        base[8] = 0
        base[9] = 1
        base.append(contentsOf: [0xc0, 0x0c])
        appendUInt16(6, to: &base)
        base.append(contentsOf: [0x00, 0x01])
        appendUInt32(soaTTL, to: &base)
        appendUInt16(UInt16(soa.count), to: &base)
        base.append(soa)
        return base
    }

    private static func rdata(for type: UInt16) -> Data {
        switch type {
        case 1: return Data([192, 0, 2, 1])
        case 28: return Data(repeating: 0x20, count: 16)
        case 5: return Data([0x05, 0x61, 0x6c, 0x69, 0x61, 0x73, 0x00])
        case 15: return Data([0x00, 0x0a, 0x05, 0x6d, 0x61, 0x69, 0x6c, 0x00])
        case 16: return Data([0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
        case 64, 65: return Data([0x00, 0x00, 0x00])
        default: return Data([0x00])
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func tryOrFail<T>(_ body: () throws -> T) -> T {
        do { return try body() }
        catch { preconditionFailure("unexpected error: \(error)") }
    }

    private static func tryOrFailAsync<T>(_ body: () async throws -> T) async -> T {
        do { return try await body() }
        catch { preconditionFailure("unexpected async error: \(error)") }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw SecureDNSWireError.truncated }
        return value
    }

    private static func expectWireError(_ expected: SecureDNSWireError, _ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("expected \(expected)")
        } catch let error as SecureDNSWireError {
            precondition(error == expected, "expected \(expected), got \(error)")
        } catch {
            preconditionFailure("expected \(expected), got \(error)")
        }
    }

    private actor AttemptRecorder {
        private var recorded: [String] = []

        func record(_ value: String) {
            recorded.append(value)
        }

        func values() -> [String] {
            recorded
        }
    }
}
