import Foundation

/// Bounds distinct DoH network operations. Identical queries are coalesced before reaching this
/// limiter; this actor prevents a burst of unrelated questions from opening an unbounded number
/// of SOCKS and TLS connections through Psiphon.
actor SecureDNSConcurrencyLimiter {
    enum AdmissionError: Error, Equatable, LocalizedError {
        case queueFull
        case deadlineExceeded

        var errorDescription: String? {
            switch self {
            case .queueFull: return "secure_dns_backpressure_queue_full"
            case .deadlineExceeded: return "secure_dns_backpressure_deadline"
            }
        }
    }

    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Permit, Error>
        let timeoutTask: Task<Void, Never>
    }

    static let defaultMaxConcurrentOperations = 4
    static let defaultMaxQueuedOperations = 64

    let maxConcurrentOperations: Int
    let maxQueuedOperations: Int

    private var activePermits = Set<UUID>()
    private var waiters: [UUID: Waiter] = [:]
    private var waiterOrder: [UUID] = []
    private var waiterOrderHead = 0

    init(
        maxConcurrentOperations: Int = defaultMaxConcurrentOperations,
        maxQueuedOperations: Int = defaultMaxQueuedOperations
    ) {
        self.maxConcurrentOperations = max(1, maxConcurrentOperations)
        self.maxQueuedOperations = max(0, maxQueuedOperations)
    }

    /// Runs work outside the actor executor and releases its permit on every success, failure, or
    /// cancellation path. The same absolute deadline covers admission and the network operation.
    nonisolated func withPermit<Value: Sendable>(
        deadline: SecureDNSDeadline,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let permit = try await acquire(deadline: deadline)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await release(permit)
            return value
        } catch {
            await release(permit)
            throw error
        }
    }

    private func acquire(deadline: SecureDNSDeadline) async throws -> Permit {
        try Task.checkCancellation()
        guard deadline.remaining > 0.01 else { throw AdmissionError.deadlineExceeded }

        if activePermits.count < maxConcurrentOperations {
            let permit = Permit(id: UUID())
            activePermits.insert(permit.id)
            return permit
        }

        guard waiters.count < maxQueuedOperations else { throw AdmissionError.queueFull }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let remaining = deadline.remaining
                guard remaining > 0.01 else {
                    continuation.resume(throwing: AdmissionError.deadlineExceeded)
                    return
                }

                let nanoseconds = UInt64(max(1, remaining * 1_000_000_000))
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    await self?.expireWaiter(waiterID)
                }
                waiters[waiterID] = Waiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                waiterOrder.append(waiterID)
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    private func release(_ permit: Permit) {
        guard activePermits.remove(permit.id) != nil else { return }
        guard let (waiterID, waiter) = dequeueWaiter() else { return }

        waiter.timeoutTask.cancel()
        let nextPermit = Permit(id: waiterID)
        activePermits.insert(nextPermit.id)
        waiter.continuation.resume(returning: nextPermit)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        removeWaiterFromOrder(id)
        compactWaiterOrderIfNeeded()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        removeWaiterFromOrder(id)
        compactWaiterOrderIfNeeded()
        waiter.continuation.resume(throwing: AdmissionError.deadlineExceeded)
    }

    /// Tunnel teardown cancels producers separately; this synchronously drains queued admissions
    /// so no continuation waits for its deadline after the tunnel has gone away.
    func cancelQueued() {
        let queued = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        waiterOrder.removeAll(keepingCapacity: true)
        waiterOrderHead = 0
        for waiter in queued {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func dequeueWaiter() -> (UUID, Waiter)? {
        while waiterOrderHead < waiterOrder.count {
            let id = waiterOrder[waiterOrderHead]
            waiterOrderHead += 1
            if let waiter = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                return (id, waiter)
            }
        }
        compactWaiterOrderIfNeeded(force: true)
        return nil
    }

    private func removeWaiterFromOrder(_ id: UUID) {
        guard waiterOrderHead < waiterOrder.count,
              let index = waiterOrder[waiterOrderHead...].firstIndex(of: id) else {
            return
        }
        waiterOrder.remove(at: index)
    }

    private func compactWaiterOrderIfNeeded(force: Bool = false) {
        guard waiterOrderHead > 0 else { return }
        if force || waiterOrderHead >= 64 && waiterOrderHead * 2 >= waiterOrder.count {
            waiterOrder.removeSubrange(0..<waiterOrderHead)
            waiterOrderHead = 0
        }
    }

    var activeCount: Int { activePermits.count }
    var queuedCount: Int { waiters.count }
}
