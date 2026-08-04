import Foundation

/// Prevents a second fallback/recovery sequence from starting while one is
/// already changing the shared Psiphon configuration.
@MainActor
final class RecoverySessionGate {
    static let shared = RecoverySessionGate()

    private(set) var activeSessionID: UUID?
    private(set) var cancellationRequested = false

    func acquire() -> UUID? {
        guard activeSessionID == nil else { return nil }
        let id = UUID()
        activeSessionID = id
        cancellationRequested = false
        return id
    }

    func owns(_ id: UUID) -> Bool {
        activeSessionID == id
    }

    func isCancellationRequested(for id: UUID) -> Bool {
        activeSessionID == id && cancellationRequested
    }

    func cancelActiveSession() {
        guard activeSessionID != nil else { return }
        cancellationRequested = true
    }

    func release(_ id: UUID) {
        guard activeSessionID == id else { return }
        activeSessionID = nil
        cancellationRequested = false
    }
}
