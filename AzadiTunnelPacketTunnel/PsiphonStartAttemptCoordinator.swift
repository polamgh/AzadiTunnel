import Foundation

/// Exactly-once terminal arbitration for one Psiphon start continuation.
///
/// The adapter calls this while holding its lifecycle lock; the coordinator has its own lock so
/// its behavior is also directly race-testable without constructing the Objective-C framework.
final class PsiphonStartAttemptCoordinator: @unchecked Sendable {
    enum Outcome: Equatable {
        case started
        case failed(String)
        case cancelled
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var terminalOutcome: Outcome?

    func arm(
        generation: UInt64,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        self.generation = generation
        pending = true
        self.continuation = continuation
        terminalOutcome = nil
        lock.unlock()
    }

    /// Invalidates an attempt that is being superseded and returns its continuation, if it was
    /// already armed. The caller owns resuming the returned continuation with cancellation.
    func invalidate(generation: UInt64) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return nil
        }
        pending = false
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }

    @discardableResult
    func claim(_ outcome: Outcome, generation: UInt64) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        guard pending, self.generation == generation else {
            lock.unlock()
            return nil
        }
        pending = false
        terminalOutcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }

    var lastTerminalOutcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return terminalOutcome
    }
}
