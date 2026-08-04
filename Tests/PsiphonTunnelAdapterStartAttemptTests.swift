import Foundation

private enum AttemptTestError: Error, Equatable {
    case failed(String)
    case cancelled
}

private func XCTAssertTrue(_ condition: @autoclosure () -> Bool) {
    precondition(condition(), "Expected condition to be true")
}

private func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T) {
    precondition(lhs() == rhs(), "Expected values to be equal")
}

private func resolve(
    _ continuation: CheckedContinuation<Void, Error>,
    with outcome: PsiphonStartAttemptCoordinator.Outcome
) {
    switch outcome {
    case .started:
        continuation.resume()
    case .failed(let reason):
        continuation.resume(throwing: AttemptTestError.failed(reason))
    case .cancelled:
        continuation.resume(throwing: AttemptTestError.cancelled)
    }
}

@discardableResult
private func deliver(
    _ outcome: PsiphonStartAttemptCoordinator.Outcome,
    generation: UInt64,
    to coordinator: PsiphonStartAttemptCoordinator
) -> Bool {
    guard let continuation = coordinator.claim(outcome, generation: generation) else {
        return false
    }
    resolve(continuation, with: outcome)
    return true
}

/// Exercises the adapter's actual continuation ownership primitive. Each scenario arms a real
/// CheckedContinuation, then delivers readiness, timeout, stop, or exiting callbacks through the
/// same coordinator the adapter uses. A duplicate resume would fail the checked continuation at
/// runtime, so these tests cover the continuation race rather than only state-machine events.
final class PsiphonTunnelAdapterStartAttemptTests {

    private func settle(
        coordinator: PsiphonStartAttemptCoordinator,
        generation: UInt64,
        callbacks: (PsiphonStartAttemptCoordinator) -> Void
    ) async -> Result<Bool, AttemptTestError> {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                coordinator.arm(generation: generation, continuation: continuation)
                callbacks(coordinator)
            }
            return .success(true)
        } catch let error as AttemptTestError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected test error: \(error)")
        }
    }

    func testDuplicateReadinessCompletesExactlyOnce() async {
        let coordinator = PsiphonStartAttemptCoordinator()
        let result = await settle(coordinator: coordinator, generation: 1) { coordinator in
            XCTAssertTrue(deliver(.started, generation: 1, to: coordinator))
            XCTAssertTrue(!deliver(.started, generation: 1, to: coordinator))
            XCTAssertTrue(!deliver(.failed("late_timeout"), generation: 1, to: coordinator))
        }

        XCTAssertEqual(result, .success(true))
        XCTAssertEqual(coordinator.lastTerminalOutcome, .started)
    }

    func testTimeoutWinsOverStopAndExiting() async {
        let coordinator = PsiphonStartAttemptCoordinator()
        let result = await settle(coordinator: coordinator, generation: 2) { coordinator in
            XCTAssertTrue(deliver(.failed("timeout"), generation: 2, to: coordinator))
            XCTAssertTrue(!deliver(.cancelled, generation: 2, to: coordinator))
            XCTAssertTrue(!deliver(.failed("psiphon_exiting"), generation: 2, to: coordinator))
        }

        XCTAssertEqual(result, .failure(.failed("timeout")))
        XCTAssertEqual(coordinator.lastTerminalOutcome, .failed("timeout"))
    }

    func testStopWinsOverExitingAndLateReadiness() async {
        let coordinator = PsiphonStartAttemptCoordinator()
        let result = await settle(coordinator: coordinator, generation: 3) { coordinator in
            XCTAssertTrue(deliver(.cancelled, generation: 3, to: coordinator))
            XCTAssertTrue(!deliver(.failed("psiphon_exiting"), generation: 3, to: coordinator))
            XCTAssertTrue(!deliver(.started, generation: 3, to: coordinator))
        }

        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(coordinator.lastTerminalOutcome, .cancelled)
    }

    func testOlderGenerationCannotCompleteNewAttempt() async {
        let coordinator = PsiphonStartAttemptCoordinator()
        let oldResult = await settle(coordinator: coordinator, generation: 4) { coordinator in
            DispatchQueue.global(qos: .utility).async {
                guard let continuation = coordinator.invalidate(generation: 4) else {
                    preconditionFailure("Old continuation was not armed")
                }
                continuation.resume(throwing: AttemptTestError.cancelled)
            }
        }
        XCTAssertEqual(oldResult, .failure(.cancelled))

        let newResult = await settle(coordinator: coordinator, generation: 5) { coordinator in
            XCTAssertTrue(!deliver(.started, generation: 4, to: coordinator))
            XCTAssertTrue(deliver(.started, generation: 5, to: coordinator))
        }
        XCTAssertEqual(newResult, .success(true))
        XCTAssertEqual(coordinator.lastTerminalOutcome, .started)
    }

    func testConcurrentTerminalCallbacksClaimOnlyOnce() async {
        let coordinator = PsiphonStartAttemptCoordinator()
        let claimLock = NSLock()
        var claims = 0
        let result = await settle(coordinator: coordinator, generation: 6) { coordinator in
            DispatchQueue.concurrentPerform(iterations: 120) { index in
                let outcome: PsiphonStartAttemptCoordinator.Outcome
                switch index % 3 {
                case 0: outcome = .started
                case 1: outcome = .failed("timeout")
                default: outcome = .cancelled
                }
                if deliver(outcome, generation: 6, to: coordinator) {
                    claimLock.lock()
                    claims += 1
                    claimLock.unlock()
                }
            }
        }

        XCTAssertEqual(claims, 1)
        if case .success = result {
            XCTAssertEqual(coordinator.lastTerminalOutcome, .started)
        } else if case .failure = result {
            XCTAssertTrue(coordinator.lastTerminalOutcome != nil)
        } else {
            preconditionFailure("Unexpected result")
        }
    }
}

@main
private enum PsiphonTunnelAdapterStartAttemptTestRunner {
    static func main() async {
        let test = PsiphonTunnelAdapterStartAttemptTests()
        let tests: [(String, () async -> Void)] = [
            ("duplicate-readiness", test.testDuplicateReadinessCompletesExactlyOnce),
            ("timeout-wins", test.testTimeoutWinsOverStopAndExiting),
            ("stop-wins", test.testStopWinsOverExitingAndLateReadiness),
            ("old-generation", test.testOlderGenerationCannotCompleteNewAttempt),
            ("concurrent-terminal-callbacks", test.testConcurrentTerminalCallbacksClaimOnlyOnce)
        ]
        for (name, body) in tests {
            await body()
            print("PASS \(name)")
        }
    }
}
