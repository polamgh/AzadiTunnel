import Foundation

/// A testable monotonic clock used by fallback and recovery orchestration.
///
/// `Date` is deliberately not used for deadlines: wall-clock adjustments must not
/// extend a recovery attempt or its overall budget.
struct RecoveryClock {
    let now: () -> TimeInterval
    let sleep: (TimeInterval) async throws -> Void

    nonisolated static let monotonic = RecoveryClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in
            try await TaskSleep.seconds(seconds)
        }
    )
}

struct RecoveryBudget {
    let clock: RecoveryClock
    let deadline: TimeInterval

    init(
        duration: TimeInterval = RecoveryTimingDefaults.overallBudget,
        clock: RecoveryClock = .monotonic
    ) {
        self.clock = clock
        deadline = clock.now() + max(0, duration)
    }

    var remaining: TimeInterval {
        max(0, deadline - clock.now())
    }

    var isExpired: Bool {
        clock.now() >= deadline
    }

    func bounded(_ requested: TimeInterval) -> TimeInterval {
        min(max(0, requested), remaining)
    }

    func sleep(_ requested: TimeInterval) async throws {
        let duration = bounded(requested)
        guard duration > 0 else { return }
        try await clock.sleep(duration)
    }
}

enum RecoveryTimingDefaults {
    nonisolated static let overallBudget: TimeInterval = 75
    nonisolated static let perAttemptBudget: TimeInterval = 25
    nonisolated static let minimumAttemptBudget: TimeInterval = 20
    nonisolated static let disconnectSettle: TimeInterval = 0.5
    nonisolated static let connectivityPoll: TimeInterval = 1
    nonisolated static let maxRecoveryAttempts = 4
    nonisolated static let maxEgressCandidates = 2
}
