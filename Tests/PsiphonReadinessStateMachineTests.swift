import Foundation

private func XCTAssertTrue(_ condition: @autoclosure () -> Bool) {
    precondition(condition(), "Expected condition to be true")
}

private func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T) {
    precondition(lhs() == rhs(), "Expected values to be equal")
}

final class PsiphonReadinessStateMachineTests {
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [PsiphonReadinessStateMachine.Event] = []

        func append(_ event: PsiphonReadinessStateMachine.Event) {
            lock.lock()
            storedEvents.append(event)
            lock.unlock()
        }

        var events: [PsiphonReadinessStateMachine.Event] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }
    }

    private func makeMachine(
        gracePeriod: TimeInterval = 60
    ) -> (
        machine: PsiphonReadinessStateMachine,
        recorder: EventRecorder
    ) {
        let recorder = EventRecorder()
        let machine = PsiphonReadinessStateMachine(
            httpGracePeriod: gracePeriod,
            eventHandler: { @Sendable event in recorder.append(event) }
        )
        return (machine, recorder)
    }

    func testConnectedFirstWaitsForSOCKSAndGraceDeadline() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()

        machine.markCoreConnected(generation: generation)
        XCTAssertTrue(recorder.events.isEmpty)
        machine.markSocksReady(port: 10_801, generation: generation)
        XCTAssertTrue(recorder.events.isEmpty)

        machine.graceDeadlineFired(generation: generation)
        XCTAssertEqual(
            recorder.events,
            [.started(
                generation: generation,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_801, httpPort: 0)
            )]
        )
    }

    func testSocksFirstWaitsForCoreConnectionAndGraceDeadline() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()

        machine.markSocksReady(port: 10_802, generation: generation)
        machine.markCoreConnected(generation: generation)
        XCTAssertTrue(recorder.events.isEmpty)

        machine.graceDeadlineFired(generation: generation)
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(
            recorder.events.first,
            .started(
                generation: generation,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_802, httpPort: 0)
            )
        )
    }

    func testHTTPFirstCompletesImmediatelyOnceCoreAndSOCKSAreReady() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()

        machine.markHTTPReady(port: 18_080, generation: generation)
        machine.markCoreConnected(generation: generation)
        XCTAssertTrue(recorder.events.isEmpty)
        machine.markSocksReady(port: 10_803, generation: generation)

        XCTAssertEqual(
            recorder.events,
            [.started(
                generation: generation,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_803, httpPort: 18_080)
            )]
        )
    }

    func testHTTPDuringGraceStartsWithDualEndpointsAndCancelsDeadline() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_804, generation: generation)

        machine.markHTTPReady(port: 18_081, generation: generation)
        machine.graceDeadlineFired(generation: generation)

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(
            recorder.events.first,
            .started(
                generation: generation,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_804, httpPort: 18_081)
            )
        )
    }

    func testHTTPAfterSOCKSOnlyStartupPublishesEndpointChange() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_805, generation: generation)
        machine.graceDeadlineFired(generation: generation)
        machine.markHTTPReady(port: 18_082, generation: generation)

        XCTAssertEqual(
            recorder.events,
            [
                .started(
                    generation: generation,
                    endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_805, httpPort: 0)
                ),
                .endpointsChanged(
                    generation: generation,
                    endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_805, httpPort: 18_082)
                )
            ]
        )
    }

    func testReconnectCoalescesEndpointChangesUntilCoreReconnects() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_813, generation: generation)
        machine.markHTTPReady(port: 18_086, generation: generation)

        machine.markCoreDisconnected(generation: generation)
        machine.markSocksReady(port: 10_814, generation: generation)
        machine.markHTTPReady(port: 18_087, generation: generation)
        XCTAssertEqual(recorder.events.count, 1)

        machine.markCoreConnected(generation: generation)
        XCTAssertEqual(
            recorder.events,
            [
                .started(
                    generation: generation,
                    endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_813, httpPort: 18_086)
                ),
                .endpointsChanged(
                    generation: generation,
                    endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_814, httpPort: 18_087)
                )
            ]
        )
    }

    func testReconnectWithoutPortChangeDoesNotReapplyEndpoints() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_815, generation: generation)
        machine.markHTTPReady(port: 18_088, generation: generation)

        machine.markCoreDisconnected(generation: generation)
        machine.markSocksReady(port: 10_815, generation: generation)
        machine.markHTTPReady(port: 18_088, generation: generation)
        machine.markCoreConnected(generation: generation)

        XCTAssertEqual(recorder.events.count, 1)
    }

    func testGraceDeadlineTimeoutAllowsSOCKSOnlyWhenHTTPNeverArrives() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_811, generation: generation)

        machine.graceDeadlineFired(generation: generation)

        XCTAssertEqual(recorder.events.count, 1)
        if case .started(_, let endpoints) = recorder.events[0] {
            XCTAssertEqual(endpoints.httpPort, 0)
            XCTAssertEqual(endpoints.socksPort, 10_811)
        } else {
            preconditionFailure("Expected SOCKS-only startup after grace timeout")
        }
    }

    func testFailureCancelsGraceDeadline() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_812, generation: generation)

        machine.fail(reason: "connect_failed", generation: generation)
        machine.graceDeadlineFired(generation: generation)

        XCTAssertEqual(recorder.events, [.failed(generation: generation, reason: "connect_failed")])
    }

    func testDuplicateCallbacksCompleteExactlyOnce() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()

        machine.markCoreConnected(generation: generation)
        machine.markCoreConnected(generation: generation)
        machine.markSocksReady(port: 10_806, generation: generation)
        machine.markSocksReady(port: 10_806, generation: generation)
        machine.markHTTPReady(port: 18_083, generation: generation)
        machine.markHTTPReady(port: 18_083, generation: generation)
        machine.graceDeadlineFired(generation: generation)

        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(
            recorder.events.first,
            .started(
                generation: generation,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_806, httpPort: 18_083)
            )
        )
    }

    func testStopWhileWaitingAndStaleCallbacksCannotCompleteNextGeneration() {
        let (machine, recorder) = makeMachine()
        let oldGeneration = machine.begin()
        machine.markCoreConnected(generation: oldGeneration)
        machine.markSocksReady(port: 10_807, generation: oldGeneration)
        machine.cancel(generation: oldGeneration)

        let newGeneration = machine.begin()
        machine.graceDeadlineFired(generation: oldGeneration)
        machine.markHTTPReady(port: 18_084, generation: oldGeneration)
        machine.markCoreConnected(generation: oldGeneration)
        machine.markSocksReady(port: 10_808, generation: oldGeneration)

        XCTAssertEqual(recorder.events, [.cancelled(generation: oldGeneration)])

        machine.markCoreConnected(generation: newGeneration)
        machine.markSocksReady(port: 10_809, generation: newGeneration)
        machine.graceDeadlineFired(generation: newGeneration)

        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertEqual(
            recorder.events.last,
            .started(
                generation: newGeneration,
                endpoints: PsiphonLocalProxyEndpoints(host: "127.0.0.1", socksPort: 10_809, httpPort: 0)
            )
        )
    }

    func testConcurrentCallbackOrdersStillPublishOneStart() {
        let (machine, recorder) = makeMachine()
        let generation = machine.begin()

        DispatchQueue.concurrentPerform(iterations: 120) { index in
            switch index % 3 {
            case 0:
                machine.markCoreConnected(generation: generation)
            case 1:
                machine.markSocksReady(port: 10_810, generation: generation)
            default:
                machine.markHTTPReady(port: 18_085, generation: generation)
            }
        }
        machine.graceDeadlineFired(generation: generation)

        XCTAssertEqual(
            recorder.events.filter {
                if case .started = $0 { return true }
                return false
            }.count,
            1
        )
    }
}

@main
private enum PsiphonReadinessStateMachineTestRunner {
    static func main() {
        let test = PsiphonReadinessStateMachineTests()
        let tests: [(String, () -> Void)] = [
            ("connected-first", test.testConnectedFirstWaitsForSOCKSAndGraceDeadline),
            ("socks-first", test.testSocksFirstWaitsForCoreConnectionAndGraceDeadline),
            ("http-first", test.testHTTPFirstCompletesImmediatelyOnceCoreAndSOCKSAreReady),
            ("http-during-grace", test.testHTTPDuringGraceStartsWithDualEndpointsAndCancelsDeadline),
            ("http-after-grace", test.testHTTPAfterSOCKSOnlyStartupPublishesEndpointChange),
            ("reconnect-coalesced-endpoints", test.testReconnectCoalescesEndpointChangesUntilCoreReconnects),
            ("reconnect-unchanged-endpoints", test.testReconnectWithoutPortChangeDoesNotReapplyEndpoints),
            ("grace-timeout", test.testGraceDeadlineTimeoutAllowsSOCKSOnlyWhenHTTPNeverArrives),
            ("failure-cancels-grace", test.testFailureCancelsGraceDeadline),
            ("duplicates", test.testDuplicateCallbacksCompleteExactlyOnce),
            ("stop-and-stale-generation", test.testStopWhileWaitingAndStaleCallbacksCannotCompleteNextGeneration),
            ("concurrent-callbacks", test.testConcurrentCallbackOrdersStillPublishOneStart)
        ]
        for (name, body) in tests {
            body()
            print("PASS \(name)")
        }
    }
}
