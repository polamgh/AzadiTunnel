import Foundation

private enum RecoveryVerificationResult {
    case completed(Bool)
    case timedOut
    case cancelled
}

/// A cancellation-safe first-result latch for the verifier/deadline race.
private final class RecoveryVerificationRace: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var result: RecoveryVerificationResult?
    nonisolated(unsafe) private var continuation: CheckedContinuation<RecoveryVerificationResult, Never>?

    nonisolated func wait() async -> RecoveryVerificationResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    nonisolated func resolve(_ result: RecoveryVerificationResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    nonisolated var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }
}

/// Runs recovery candidates serially. Psiphon owns process-wide resources, so
/// this intentionally never starts a second engine while an attempt is pending.
@MainActor
struct RecoveryAttemptRunner {
    struct Attempt: Equatable {
        let id: String
        let settings: AppSettings
        let timeoutSeconds: TimeInterval
        let minimumTimeoutSeconds: TimeInterval

        init(
            id: String,
            settings: AppSettings,
            timeoutSeconds: TimeInterval,
            minimumTimeoutSeconds: TimeInterval = RecoveryTimingDefaults.minimumAttemptBudget
        ) {
            self.id = id
            self.settings = settings
            self.timeoutSeconds = timeoutSeconds
            self.minimumTimeoutSeconds = minimumTimeoutSeconds
        }
    }

    enum Result {
        case succeeded(Attempt)
        case exhausted
        case cancelled
    }

    struct Operations {
        let applyTrial: (AppSettings) -> Void
        let restoreBaseline: (AppSettings) -> Void
        let disconnect: () async -> Void
        let connect: () async -> Void
        let verify: (Attempt, TimeInterval, RecoveryBudget) async throws -> Bool
        let persistWinner: (AppSettings) -> Void
        var isCancellationRequested: () -> Bool = { false }

        var attemptStarted: (Int, Attempt) -> Void = { _, _ in }
        var attemptFinished: (Int, Attempt, Bool) -> Void = { _, _, _ in }
    }

    private let operations: Operations

    init(operations: Operations) {
        self.operations = operations
    }

    func run(
        attempts: [Attempt],
        baseline: AppSettings,
        budget: RecoveryBudget,
        maxAttempts: Int = RecoveryTimingDefaults.maxRecoveryAttempts
    ) async -> Result {
        guard !attempts.isEmpty, maxAttempts > 0 else {
            return .exhausted
        }

        var hasRequestedDisconnect = false
        var attemptNumber = 0
        var trialIsActive = false

        func restoreActiveTrial() async {
            guard trialIsActive else { return }
            // NetworkExtension start/stop calls are request-style control calls:
            // they return after enqueueing the state change, while the status
            // transition is observed asynchronously. Keep the call serialized,
            // then restore the session cache exactly once and check cancellation
            // and the monotonic budget immediately around it.
            await operations.disconnect()
            if isCancelled || budget.isExpired {
                operations.restoreBaseline(baseline)
                trialIsActive = false
                return
            }
            operations.restoreBaseline(baseline)
            trialIsActive = false
        }

        for attempt in attempts.prefix(maxAttempts) {
            if isCancelled {
                return .cancelled
            }
            if budget.isExpired {
                return .exhausted
            }

            attemptNumber += 1
            operations.attemptStarted(attemptNumber, attempt)

            if !hasRequestedDisconnect {
                // NEVPNConnection stopVPNTunnel returns immediately after
                // starting the disconnect request. VPNController performs no
                // recovery work in this internal call; the budget/cancellation
                // checks below bound the handoff before another trial starts.
                await operations.disconnect()
                hasRequestedDisconnect = true
                guard await settleAfterDisconnect(using: budget) else {
                    return isCancelled ? .cancelled : .exhausted
                }
            }

            if isCancelled {
                return .cancelled
            }
            if budget.isExpired {
                return .exhausted
            }

            operations.applyTrial(attempt.settings)
            trialIsActive = true

            guard !isCancelled, !budget.isExpired else {
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                return isCancelled ? .cancelled : .exhausted
            }

            // startVPNTunnel has the same request-style NetworkExtension
            // contract. Verify immediately after the controller returns so a
            // cancelled/expired session cannot enqueue another candidate.
            await operations.connect()

            guard !isCancelled, !budget.isExpired else {
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                return isCancelled ? .cancelled : .exhausted
            }

            // Honor the step's configured timeout (Android ≈120s). Only the
            // remaining overall budget may shorten it — never a hard per-attempt
            // ceiling below the settings value.
            let configured = max(attempt.minimumTimeoutSeconds, attempt.timeoutSeconds)
            let timeout = min(configured, budget.remaining)
            guard timeout > 0 else {
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                return isCancelled ? .cancelled : .exhausted
            }

            let verification = await verifyWithinBudget(
                attempt: attempt,
                timeout: timeout,
                budget: budget
            )
            if case .cancelled = verification {
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                return .cancelled
            }

            if case .timedOut = verification {
                // A verifier deadline only rejects this candidate. The overall
                // budget remains available for the next serial candidate.
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                hasRequestedDisconnect = true
                guard !isCancelled else { return .cancelled }
                if budget.isExpired { return .exhausted }
                guard await settleAfterDisconnect(using: budget) else {
                    return isCancelled ? .cancelled : .exhausted
                }
                continue
            }

            guard case .completed(let verified) = verification else { return .cancelled }

            guard !isCancelled else {
                operations.attemptFinished(attemptNumber, attempt, false)
                await restoreActiveTrial()
                return .cancelled
            }

            if verified, !budget.isExpired {
                operations.attemptFinished(attemptNumber, attempt, true)
                operations.persistWinner(attempt.settings)
                return .succeeded(attempt)
            }

            operations.attemptFinished(attemptNumber, attempt, false)
            await restoreActiveTrial()
            hasRequestedDisconnect = true

            guard !isCancelled else { return .cancelled }
            if budget.isExpired { return .exhausted }
            guard await settleAfterDisconnect(using: budget) else {
                return isCancelled ? .cancelled : .exhausted
            }
        }

        return isCancelled ? .cancelled : .exhausted
    }

    private func verifyWithinBudget(
        attempt: Attempt,
        timeout: TimeInterval,
        budget: RecoveryBudget
    ) async -> RecoveryVerificationResult {
        let race = RecoveryVerificationRace()
        let verifier = Task { @MainActor in
            do {
                let result = try await operations.verify(attempt, timeout, budget)
                race.resolve(.completed(result))
            } catch {
                race.resolve(.cancelled)
            }
        }
        // Give a fast verifier its first scheduling turn before installing the
        // deadline task. This keeps injected clock tests deterministic without
        // weakening the deadline race for a verifier that actually suspends.
        await Task.yield()
        let deadline: Task<Void, Never>? = race.isResolved ? nil : Task { @MainActor in
            if !Task.isCancelled, !race.isResolved {
                do {
                    try await budget.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    race.resolve(.timedOut)
                } catch {
                    // The timer is cancelled when the verifier wins.
                }
            }
        }
        let cancellationWatcher = Task { @MainActor in
            while !Task.isCancelled {
                if operations.isCancellationRequested() {
                    race.resolve(.cancelled)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }
        }

        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            verifier.cancel()
            deadline?.cancel()
            cancellationWatcher.cancel()
            race.resolve(.cancelled)
        }

        verifier.cancel()
        deadline?.cancel()
        cancellationWatcher.cancel()
        return result
    }

    private func settleAfterDisconnect(using budget: RecoveryBudget) async -> Bool {
        do {
            try await budget.sleep(RecoveryTimingDefaults.disconnectSettle)
            return !isCancelled
        } catch {
            return false
        }
    }

    private var isCancelled: Bool {
        Task.isCancelled || operations.isCancellationRequested()
    }
}
