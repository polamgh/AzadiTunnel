import Foundation

/// Coalesces identical DNS wire queries while keeping cancellation scoped to the caller that
/// joined the query. The last cancelled waiter cancels the shared producer; one cancelled packet
/// request therefore cannot strand a network operation, while another waiter can still receive it.
actor SecureDNSResolutionCoordinator<Value: Sendable> {
    struct Handle: Hashable, Sendable {
        fileprivate let key: Data
        fileprivate let id: UUID
    }

    private struct Entry {
        let task: Task<Value, Error>
        var waiters: Set<UUID>
    }

    private var inFlight: [Data: Entry] = [:]

    func acquire(
        for key: Data,
        operation: @escaping @Sendable () async throws -> Value
    ) -> Handle {
        let id = UUID()
        if var existing = inFlight[key] {
            existing.waiters.insert(id)
            inFlight[key] = existing
            return Handle(key: key, id: id)
        }

        let task = Task { try await operation() }
        inFlight[key] = Entry(task: task, waiters: [id])
        return Handle(key: key, id: id)
    }

    /// Convenience API for callers that do not need an explicit cancellation hook.
    func value(
        for key: Data,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let handle = acquire(for: key, operation: operation)
        return try await wait(handle)
    }

    func wait(_ handle: Handle) async throws -> Value {
        guard let task = inFlight[handle.key]?.task,
              inFlight[handle.key]?.waiters.contains(handle.id) == true else {
            throw CancellationError()
        }
        defer { finish(handle) }
        return try await task.value
    }

    /// Releases one waiter. The shared operation is cancelled only when no waiter remains.
    func finish(_ handle: Handle) {
        guard var entry = inFlight[handle.key] else { return }
        entry.waiters.remove(handle.id)
        if entry.waiters.isEmpty {
            inFlight.removeValue(forKey: handle.key)
        } else {
            inFlight[handle.key] = entry
        }
    }

    /// Called from a task cancellation handler. It is idempotent and never cancels another
    /// caller's waiter unless this was the final waiter for the same wire query.
    func cancel(_ handle: Handle) {
        guard var entry = inFlight[handle.key], entry.waiters.remove(handle.id) != nil else { return }
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: handle.key)
        } else {
            inFlight[handle.key] = entry
        }
    }

    func cancelAll() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll(keepingCapacity: true)
    }

    var count: Int { inFlight.count }
}
