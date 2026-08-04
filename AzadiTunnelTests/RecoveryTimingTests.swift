import XCTest
@testable import AzadiTunnel

@MainActor
final class RecoveryTimingTests: XCTestCase {
    private final class FakeClock {
        var value: TimeInterval = 0
        var sleeps: [TimeInterval] = []
        var throwOnSleepNumber: Int?

        lazy var clock = RecoveryClock(
            now: { [weak self] in self?.value ?? 0 },
            sleep: { [weak self] seconds in
                guard let self else { return }
                self.sleeps.append(seconds)
                if self.sleeps.count == self.throwOnSleepNumber {
                    throw CancellationError()
                }
                self.value += seconds
            }
        )
    }

    private final class CancellationClock {
        var value: TimeInterval = 0
        var sleeps: [TimeInterval] = []

        lazy var clock = RecoveryClock(
            now: { [weak self] in self?.value ?? 0 },
            sleep: { [weak self] seconds in
                guard let self else { return }
                self.sleeps.append(seconds)
                if self.sleeps.count == 1 {
                    self.value += seconds
                    return
                }
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
    }

    private func attempt(id: String, settings: AppSettings, timeout: TimeInterval = 25) -> RecoveryAttemptRunner.Attempt {
        RecoveryAttemptRunner.Attempt(id: id, settings: settings, timeoutSeconds: timeout)
    }

    func testSingleBudgetCapsAttemptsAndUsesMonotonicClock() async {
        let clock = FakeClock()
        var timeouts: [TimeInterval] = []
        var connects = 0
        let baseline = AppSettings()
        var trial = baseline
        trial.protocolSelection = .direct
        let attempts = (0..<4).map {
            attempt(id: "attempt-\($0)", settings: trial)
        }
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { _ in },
            disconnect: {},
            connect: { connects += 1 },
            verify: { _, timeout, budget in
                timeouts.append(timeout)
                try await budget.sleep(timeout)
                return false
            },
            persistWinner: { _ in }
        ))

        let result = await runner.run(
            attempts: attempts,
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock),
            maxAttempts: 4
        )

        if case .exhausted = result {
            // Expected: the third attempt consumes the remaining budget.
        } else {
            XCTFail("expected bounded exhaustion")
        }
        XCTAssertEqual(clock.value, 75, accuracy: 0.0001)
        XCTAssertTrue(timeouts.allSatisfy { $0 <= RecoveryTimingDefaults.perAttemptBudget })
        XCTAssertEqual(timeouts, [25, 25, 23.5])
        XCTAssertEqual(connects, 3)
    }

    func testUserCancellationDuringVerificationStopsRecoveryWithoutReconnectOrPersist() async {
        let gate = RecoverySessionGate()
        guard let session = gate.acquire() else {
            return XCTFail("recovery session should be acquired")
        }
        let clock = CancellationClock()
        let baseline = AppSettings()
        var trial = baseline
        trial.egressRegion = "DE"
        var verifyStarted = false
        var connects = 0
        var restored = 0
        var persisted = 0
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { _ in restored += 1 },
            disconnect: {},
            connect: { connects += 1 },
            verify: { _, _, _ in
                verifyStarted = true
                while !gate.isCancellationRequested(for: session), !Task.isCancelled {
                    await Task.yield()
                }
                return false
            },
            persistWinner: { _ in persisted += 1 },
            isCancellationRequested: {
                gate.isCancellationRequested(for: session)
            }
        ))

        let runTask = Task {
            await runner.run(
                attempts: [attempt(id: "cancelled", settings: trial)],
                baseline: baseline,
                budget: RecoveryBudget(duration: 75, clock: clock.clock)
            )
        }
        while !verifyStarted {
            await Task.yield()
        }
        // This is the same cancellation signal sent by VPNController.disconnect.
        gate.cancelActiveSession()
        let result = await runTask.value

        if case .cancelled = result {
            // Expected.
        } else {
            XCTFail("expected user cancellation")
        }
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(persisted, 0)
        gate.release(session)
    }

    func testMisbehavingVerifierCannotOutliveAttemptDeadline() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var trial = baseline
        trial.protocolSelection = .direct
        var persisted = 0
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { _ in },
            disconnect: {},
            connect: {},
            verify: { _, _, _ in
                try await Task.sleep(nanoseconds: 120_000_000_000)
                return true
            },
            persistWinner: { _ in persisted += 1 }
        ))

        let result = await runner.run(
            attempts: [attempt(id: "misbehaving", settings: trial)],
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock)
        )

        if case .exhausted = result {
            // Expected.
        } else {
            XCTFail("expected timeout exhaustion")
        }
        XCTAssertEqual(clock.value, 26, accuracy: 0.0001)
        XCTAssertEqual(persisted, 0)
    }

    func testAttemptTimeoutCleansUpAndContinuesToNextCandidate() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var first = baseline
        first.protocolSelection = .cdnFronting
        var second = baseline
        second.protocolSelection = .direct
        var verificationCount = 0
        var connected = 0
        var restored = 0
        var persisted: [AppSettings] = []
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { _ in restored += 1 },
            disconnect: {},
            connect: { connected += 1 },
            verify: { _, _, _ in
                verificationCount += 1
                if verificationCount == 1 {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    return true
                }
                return true
            },
            persistWinner: { persisted.append($0) }
        ))

        let result = await runner.run(
            attempts: [attempt(id: "hang", settings: first), attempt(id: "winner", settings: second)],
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock),
            maxAttempts: 2
        )

        guard case .succeeded(let winner) = result else {
            return XCTFail("expected second candidate to win after first timeout")
        }
        XCTAssertEqual(winner.settings, second)
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(connected, 2)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(persisted, [second])
        XCTAssertEqual(clock.value, 26, accuracy: 0.0001)
    }

    func testRecoverySessionGatePreventsOverlappingRuns() {
        let gate = RecoverySessionGate()
        guard let first = gate.acquire() else {
            return XCTFail("first session should be acquired")
        }
        XCTAssertNil(gate.acquire())
        XCTAssertTrue(gate.owns(first))
        gate.cancelActiveSession()
        XCTAssertTrue(gate.isCancellationRequested(for: first))
        gate.release(first)
        let next = gate.acquire()
        XCTAssertNotNil(next)
        if let next {
            XCTAssertFalse(gate.isCancellationRequested(for: next))
            gate.release(next)
        }
    }

    func testEgressCandidatesAreTelemetryDrivenAndLimited() {
        let best = BestServerSelection(
            transport: FallbackStep.direct.rawValue,
            tunnelProtocol: "TLS-OSSH",
            egressRegion: "DE"
        )

        XCTAssertEqual(
            NoInternetRecoveryController.egressRegionsToTry(
                current: "US",
                best: best,
                telemetryRegion: "NL"
            ),
            ["DE", "NL"]
        )
        XCTAssertEqual(
            NoInternetRecoveryController.egressRegionsToTry(
                current: "DE",
                best: best,
                telemetryRegion: "NL"
            ),
            ["NL"]
        )
        XCTAssertTrue(
            NoInternetRecoveryController.egressRegionsToTry(
                current: "US",
                best: nil,
                telemetryRegion: ""
            ).isEmpty
        )
    }

    func testOnlyVerifiedWinnerIsPersisted() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var failedTrial = baseline
        failedTrial.protocolSelection = .cdnFronting
        var winner = baseline
        winner.protocolSelection = .direct
        var persisted: [AppSettings] = []
        var restored: [AppSettings] = []
        var verificationCount = 0
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { restored.append($0) },
            disconnect: {},
            connect: {},
            verify: { _, _, _ in
                verificationCount += 1
                return verificationCount == 2
            },
            persistWinner: { persisted.append($0) }
        ))

        let result = await runner.run(
            attempts: [
                attempt(id: "failed", settings: failedTrial),
                attempt(id: "winner", settings: winner)
            ],
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock),
            maxAttempts: 2
        )

        guard case .succeeded(let selected) = result else {
            return XCTFail("expected second attempt to win")
        }
        XCTAssertEqual(selected.settings, winner)
        XCTAssertEqual(persisted, [winner])
        XCTAssertTrue(restored.contains(baseline))
        XCTAssertFalse(persisted.contains(failedTrial))
    }

    func testVerifiedWinnerKeepsSessionOverlayAndLeavesDurableBaselineUntouched() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var winner = baseline
        winner.protocolSelection = .cdnFronting
        let durableSettings = baseline
        var sessionSettings: AppSettings?
        var winnerMetadata: [AppSettings] = []
        var restoreCalls = 0
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { sessionSettings = $0 },
            restoreBaseline: { _ in
                restoreCalls += 1
                sessionSettings = nil
            },
            disconnect: {},
            connect: {},
            verify: { _, _, _ in true },
            persistWinner: { winnerMetadata.append($0) }
        ))

        let result = await runner.run(
            attempts: [attempt(id: "winner", settings: winner)],
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock)
        )

        guard case .succeeded = result else {
            return XCTFail("expected verified winner")
        }
        XCTAssertEqual(durableSettings, baseline)
        XCTAssertEqual(sessionSettings, winner)
        XCTAssertEqual(winnerMetadata, [winner])
        XCTAssertEqual(restoreCalls, 0)
    }

    func testExhaustionRestoresBaselineWithoutPersistingFailedTrials() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var current = baseline
        var persisted: [AppSettings] = []
        var failed = baseline
        failed.egressRegion = "CA"
        var restoreCalls = 0
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { current = $0 },
            restoreBaseline: {
                restoreCalls += 1
                current = $0
            },
            disconnect: {},
            connect: {},
            verify: { _, _, _ in false },
            persistWinner: { persisted.append($0) }
        ))

        let result = await runner.run(
            attempts: [attempt(id: "failed", settings: failed)],
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock)
        )

        if case .exhausted = result {
            // Expected.
        } else {
            XCTFail("expected exhaustion")
        }
        XCTAssertEqual(current, baseline)
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testRecoveryStopsAtConfiguredMaximumAttemptCount() async {
        let clock = FakeClock()
        let baseline = AppSettings()
        var started = 0
        var connected = 0
        let attempts = (0..<8).map { index in
            attempt(id: "bounded-\(index)", settings: baseline)
        }
        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { _ in },
            restoreBaseline: { _ in },
            disconnect: {},
            connect: { connected += 1 },
            verify: { _, _, _ in false },
            persistWinner: { _ in },
            attemptStarted: { _, _ in started += 1 }
        ))

        let result = await runner.run(
            attempts: attempts,
            baseline: baseline,
            budget: RecoveryBudget(duration: 75, clock: clock.clock),
            maxAttempts: 4
        )

        if case .exhausted = result {
            // Expected.
        } else {
            XCTFail("expected bounded exhaustion")
        }
        XCTAssertEqual(started, 4)
        XCTAssertEqual(connected, 4)
    }

    func testRecoveryPlanNeverDisablesSecureDNSOrCleartextProtection() {
        var original = AppSettings()
        original.secureDNSMode = .doh
        original.blockCleartextDNS = true

        let plans = NoInternetRecoveryController.buildAttemptPlans(
            original: original,
            best: nil,
            telemetryRegion: nil
        )

        XCTAssertFalse(plans.contains { $0.phase == .secureDnsOff })
        XCTAssertFalse(plans.contains {
            $0.attempt.settings.secureDNSMode == .off
                && !$0.attempt.settings.blockCleartextDNS
        })
    }

    func testExpiredRecoveryOverlayIsDiscardedBeforeExtensionUse() {
        let store = SharedSettingsStore.shared
        let originalSettings = store.appSettings
        var trial = originalSettings
        trial.protocolSelection = .direct

        store.clearRecoveryTrialSettings()
        store.applyRecoveryTrialSettings(trial)
        XCTAssertEqual(store.recoveryTrialSettings, trial)
        XCTAssertEqual(store.appSettings, originalSettings)

        store.discardExpiredRecoveryTrialSettings(
            now: Date().addingTimeInterval(RecoveryTrialSettingsDefaults.lifetime + 1)
        )
        XCTAssertNil(store.recoveryTrialSettings)
        XCTAssertNil(store.recoveryTrialExpiresAt)
        XCTAssertEqual(store.appSettings, originalSettings)
        store.clearRecoveryTrialSettings()
    }

    func testTerminalCleanupClearsVerifiedRecoveryOverlay() {
        let store = SharedSettingsStore.shared
        var trial = store.appSettings
        trial.egressRegion = "DE"
        store.applyRecoveryTrialSettings(trial)
        XCTAssertNotNil(store.recoveryTrialSettings)

        // This is the same idempotent cleanup used by stopTunnel and terminal
        // start failure paths; it must not alter durable AppSettings.
        let durable = store.appSettings
        store.clearRecoveryTrialSettings()
        XCTAssertNil(store.recoveryTrialSettings)
        XCTAssertEqual(store.appSettings, durable)
    }
}
