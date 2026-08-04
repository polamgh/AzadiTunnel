import Foundation

/// Coordinates the asynchronous Psiphon callbacks that make the local proxy usable.
///
/// Psiphon can report the connected state and its local proxy ports in any order. A
/// generation is assigned to each start attempt so callbacks and grace timers from a
/// stopped or superseded attempt cannot complete the current attempt. All mutable
/// state is protected by `lock`; event handlers are always called after releasing it.
final class PsiphonReadinessStateMachine: @unchecked Sendable {
    enum Event: Equatable {
        case started(generation: UInt64, endpoints: PsiphonLocalProxyEndpoints)
        case endpointsChanged(generation: UInt64, endpoints: PsiphonLocalProxyEndpoints)
        case failed(generation: UInt64, reason: String)
        case cancelled(generation: UInt64)
    }

    private enum Phase {
        case idle
        case waiting
        case started
        case failed
        case cancelled
    }

    static let defaultHTTPGracePeriod: TimeInterval = 2.5

    private let lock = NSLock()
    private let host: String
    private let httpGracePeriod: TimeInterval
    private let eventHandler: @Sendable (Event) -> Void
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var coreConnected = false
    private var socksPort = 0
    private var httpPort = 0
    private var publishedEndpoints: PsiphonLocalProxyEndpoints?
    private var graceTimer: DispatchWorkItem?

    init(
        host: String = "127.0.0.1",
        httpGracePeriod: TimeInterval = PsiphonReadinessStateMachine.defaultHTTPGracePeriod,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.host = host
        self.httpGracePeriod = max(0, min(httpGracePeriod.isFinite ? httpGracePeriod : 0, 10))
        self.eventHandler = eventHandler
    }

    /// Starts a new callback generation and invalidates the previous one.
    @discardableResult
    func begin() -> UInt64 {
        lock.lock()
        graceTimer?.cancel()
        graceTimer = nil
        generation = generation == UInt64.max ? 1 : generation + 1
        phase = .waiting
        coreConnected = false
        socksPort = 0
        httpPort = 0
        publishedEndpoints = nil
        let currentGeneration = generation
        lock.unlock()
        return currentGeneration
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var currentEndpoints: PsiphonLocalProxyEndpoints {
        lock.lock()
        defer { lock.unlock() }
        return endpointsLocked()
    }

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .started && coreConnected && socksPort > 0
    }

    func markCoreConnected(generation callbackGeneration: UInt64) {
        var events: [Event] = []
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration),
              (phase == .waiting || phase == .started) else {
            lock.unlock()
            return
        }
        coreConnected = true
        if phase == .waiting {
            events = readyEventsIfPossibleLocked()
        } else if phase == .started {
            events = endpointChangeEventsIfNeededLocked()
        }
        lock.unlock()
        emit(events)
    }

    func markCoreDisconnected(generation callbackGeneration: UInt64) {
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration),
              (phase == .waiting || phase == .started) else {
            lock.unlock()
            return
        }
        coreConnected = false
        if phase == .waiting {
            graceTimer?.cancel()
            graceTimer = nil
        }
        lock.unlock()
    }

    func markSocksReady(port: Int, generation callbackGeneration: UInt64) {
        guard port > 0 else { return }
        var events: [Event] = []
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration),
              (phase == .waiting || phase == .started) else {
            lock.unlock()
            return
        }
        let changed = socksPort != port
        socksPort = port
        if phase == .waiting {
            events = readyEventsIfPossibleLocked()
        } else if changed, coreConnected {
            events = endpointChangeEventsIfNeededLocked()
        }
        lock.unlock()
        emit(events)
    }

    func markHTTPReady(port: Int, generation callbackGeneration: UInt64) {
        guard port > 0 else { return }
        var events: [Event] = []
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration),
              (phase == .waiting || phase == .started) else {
            lock.unlock()
            return
        }
        let changed = httpPort != port
        httpPort = port
        if phase == .waiting {
            events = readyEventsIfPossibleLocked()
        } else if changed, coreConnected, socksPort > 0 {
            events = endpointChangeEventsIfNeededLocked()
        }
        lock.unlock()
        emit(events)
    }

    /// Handles the bounded SOCKS-only grace deadline. This method is internal so tests can
    /// deterministically fire the timer without sleeping; production uses the scheduled work item.
    func graceDeadlineFired(generation callbackGeneration: UInt64) {
        var events: [Event] = []
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration),
              phase == .waiting,
              coreConnected,
              socksPort > 0,
              httpPort == 0 else {
            lock.unlock()
            return
        }
        graceTimer?.cancel()
        graceTimer = nil
        phase = .started
        publishedEndpoints = endpointsLocked()
        events = [.started(generation: generation, endpoints: endpointsLocked())]
        lock.unlock()
        emit(events)
    }

    func fail(reason: String, generation callbackGeneration: UInt64) {
        var events: [Event] = []
        lock.lock()
        guard isCurrentGenerationLocked(callbackGeneration), phase == .waiting else {
            lock.unlock()
            return
        }
        graceTimer?.cancel()
        graceTimer = nil
        phase = .failed
        events = [.failed(generation: generation, reason: reason)]
        lock.unlock()
        emit(events)
    }

    /// Stops the active generation and invalidates its callbacks and timer.
    func cancel(generation callbackGeneration: UInt64? = nil) {
        var events: [Event] = []
        lock.lock()
        let targetGeneration = callbackGeneration ?? generation
        guard targetGeneration == generation,
              (phase == .waiting || phase == .started) else {
            lock.unlock()
            return
        }
        graceTimer?.cancel()
        graceTimer = nil
        phase = .cancelled
        events = [.cancelled(generation: generation)]
        lock.unlock()
        emit(events)
    }

    private func isCurrentGenerationLocked(_ callbackGeneration: UInt64) -> Bool {
        callbackGeneration == generation
    }

    private func readyEventsIfPossibleLocked() -> [Event] {
        guard phase == .waiting, coreConnected, socksPort > 0 else { return [] }
        if httpPort > 0 {
            graceTimer?.cancel()
            graceTimer = nil
            phase = .started
            publishedEndpoints = endpointsLocked()
            return [.started(generation: generation, endpoints: endpointsLocked())]
        }

        guard graceTimer == nil else { return [] }
        let callbackGeneration = generation
        let timer = DispatchWorkItem { [weak self] in
            self?.graceDeadlineFired(generation: callbackGeneration)
        }
        graceTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + httpGracePeriod,
            execute: timer
        )
        return []
    }

    private func endpointChangeEventsIfNeededLocked() -> [Event] {
        guard phase == .started, coreConnected, socksPort > 0 else { return [] }
        let endpoints = endpointsLocked()
        guard publishedEndpoints != endpoints else { return [] }
        publishedEndpoints = endpoints
        return [.endpointsChanged(generation: generation, endpoints: endpoints)]
    }

    private func endpointsLocked() -> PsiphonLocalProxyEndpoints {
        PsiphonLocalProxyEndpoints(host: host, socksPort: socksPort, httpPort: httpPort)
    }

    private func emit(_ events: [Event]) {
        for event in events {
            eventHandler(event)
        }
    }
}
