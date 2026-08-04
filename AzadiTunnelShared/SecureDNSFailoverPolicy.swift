import Foundation

/// DoH retry budget. Every endpoint attempt has a short deadline and the whole query has a hard
/// upper bound, so a dead provider cannot stall DNS indefinitely.
enum SecureDNSFailoverPolicy {
    enum Error: Swift.Error, Equatable {
        case noEndpoints
        case attemptTimedOut
        case totalTimeout
    }

    nonisolated static let perAttemptTimeout: TimeInterval = 2.5
    nonisolated static let maxAttempts = 3
    nonisolated static let totalTimeout = perAttemptTimeout * TimeInterval(maxAttempts)

    static func endpointsToTry<T>(_ endpoints: [T]) -> ArraySlice<T> {
        endpoints.prefix(maxAttempts)
    }

    /// Runs bounded, sequential failover with real per-attempt cancellation. The operation gets
    /// the same deadline that the timeout task enforces, so network code can also bound each
    /// protocol stage and close its connection before the next endpoint is tried.
    static func perform<Endpoint, Value: Sendable>(
        endpoints: [Endpoint],
        perAttemptTimeout: TimeInterval = Self.perAttemptTimeout,
        totalTimeout: TimeInterval = Self.totalTimeout,
        operation: @escaping @Sendable (_ endpoint: Endpoint, _ index: Int, _ deadline: SecureDNSDeadline) async throws -> Value
    ) async throws -> Value {
        let candidates = Array(endpoints.prefix(maxAttempts))
        guard !candidates.isEmpty else { throw Error.noEndpoints }

        let perAttempt = max(0.01, min(perAttemptTimeout, 3.0))
        let total = max(0.01, min(totalTimeout, perAttempt * TimeInterval(candidates.count)))
        let overallDeadline = SecureDNSDeadline(after: total)
        var lastError: Swift.Error?

        for (index, endpoint) in candidates.enumerated() {
            try Task.checkCancellation()
            let remaining = overallDeadline.remaining
            guard remaining > 0.01 else { break }
            let deadline = SecureDNSDeadline(after: min(perAttempt, remaining))
            do {
                return try await withAttemptDeadline(deadline) {
                    try await operation(endpoint, index, deadline)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw Error.totalTimeout
    }

    private static func withAttemptDeadline<Value: Sendable>(
        _ deadline: SecureDNSDeadline,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = deadline.remaining
        guard remaining > 0.01 else { throw Error.attemptTimedOut }
        let nanoseconds = UInt64(max(1, remaining * 1_000_000_000))

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw Error.attemptTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw Error.attemptTimedOut
            }
            return result
        }
    }
}
