import Foundation
import PsiphonTunnel

private final class PsiphonPacketTunnelProviderAdapter: NSObject, PsiphonPacketTunnelProvider {
    private let io: PsiphonPacketTunnelIO
    private let transportStateHandler: @Sendable (String) -> Void

    init(
        io: PsiphonPacketTunnelIO,
        transportStateHandler: @escaping @Sendable (String) -> Void
    ) {
        self.io = io
        self.transportStateHandler = transportStateHandler
    }

    func packetTunnelMTU() -> Int { io.mtu }

    func readPacket() throws -> Data {
        try io.readPacket()
    }

    func writePacket(_ packet: Data) throws {
        try io.writePacket(packet)
    }

    func closePacketTunnel() {
        io.close()
    }

    func packetTunnelTransportState(_ state: String) {
        transportStateHandler(state)
    }

    func packetTunnelDiagnostic(_ stage: String, packetCount: Int64, byteCount: Int64) {
        SharedLogger.shared.logRaw(
            "PSIPHON_PACKET_DATA_PLANE",
            detail: "stage=\(stage) packets=\(packetCount) bytes=\(byteCount)"
        )
    }

    func fail(_ error: NSError) {
        io.failPacketTunnel(error)
    }
}

/// Bridges PsiphonTunnel Objective-C API — **packet tunnel target only** (links PsiphonTunnel.framework).
final class PsiphonTunnelAdapter: NSObject, PsiphonTunnelCoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tunnel: PsiphonTunnel?
    private var configJSON: String = ""
    private var serverEntriesPath: String = ""
    private var _lastError: String?
    private var activeGeneration: UInt64 = 0
    private var callbacksActive = false
    private var packetMode = false
    private var packetTransportReady = false
    private var packetProviderAdapter: PsiphonPacketTunnelProviderAdapter?
    private var startTimeoutTask: Task<Void, Never>?
    private var connectionPollTask: Task<Void, Never>?
    private var conduitFallbackTask: Task<Void, Never>?
    private var conduitFallbackTimerStarted = false
    private var psiphonDataDirectory: URL?
    private var callbackProxy: PsiphonTunnelCallbackProxy?
    private var endpointChangeHandler: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)?
    private let startAttemptCoordinator = PsiphonStartAttemptCoordinator()

    private lazy var readiness = PsiphonReadinessStateMachine { [weak self] event in
        self?.handleReadinessEvent(event)
    }

    private var connectWaitSeconds: TimeInterval {
        let settings = SharedSettingsStore.shared.effectiveAppSettings
        if settings.protocolSelection == .conduit { return 120 }
        if settings.beastModeEnabled { return 120 }
        return 90
    }
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        let endpoints = readiness.currentEndpoints
        return PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: packetMode,
            hasPacketProvider: packetProviderAdapter != nil,
            packetTransportReady: packetTransportReady,
            hasSocks: endpoints.hasSocks,
            coreConnected: readiness.isStarted
        )
    }

    var localProxyHost: String { "127.0.0.1" }

    var localProxyPort: Int {
        readiness.currentEndpoints.socksPort
    }

    var localProxyType: PsiphonLocalProxyType {
        let endpoints = readiness.currentEndpoints
        if endpoints.hasSocks && endpoints.hasHttp { return .dual }
        if endpoints.hasSocks { return .socks }
        if endpoints.hasHttp { return .http }
        return .unknown
    }

    var localProxyEndpoints: PsiphonLocalProxyEndpoints {
        readiness.currentEndpoints
    }

    var onLocalProxyEndpointsChanged: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return endpointChangeHandler
        }
        set {
            lock.lock()
            endpointChangeHandler = newValue
            lock.unlock()
        }
    }

    /// The pinned Psiphon callback transport accepts complete IPv4 and IPv6 packets and relays
    /// both families through the native packet engine.
    var packetEngineCapabilities: PacketEngineCapabilities {
        .ipv4AndIPv6
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    func start(
        configJSON: String,
        serverEntriesPath: String?,
        dataDir: URL,
        packetTunnel: PsiphonPacketTunnelIO?
    ) async throws {
        try Task.checkCancellation()
        Self.diagLogCount = 0
        let hasEntries = !(serverEntriesPath ?? "").isEmpty
            && FileManager.default.fileExists(atPath: serverEntriesPath ?? "")
        let configWithStore = try Self.configJSON(
            configJSON,
            dataStoreDirectory: dataDir,
            hasEmbeddedServerEntries: hasEntries,
            packetMode: packetTunnel != nil
        )
        try PsiphonConfigValidator.validate(configWithStore, hasEmbeddedServerEntries: hasEntries)
        SharedLogger.shared.log(.psiphonConfigValid)
        SharedLogger.shared.log(.psiphonStartRequested)

        let generation: UInt64
        let callbackDelegate: PsiphonTunnelCallbackProxy
        let previousGeneration: UInt64
        let previousTunnel: PsiphonTunnel?
        let previousContinuation: CheckedContinuation<Void, Error>?
        let newPacketProviderAdapter: PsiphonPacketTunnelProviderAdapter?

        lock.lock()
        previousGeneration = activeGeneration
        previousContinuation = previousGeneration == 0
            ? nil
            : startAttemptCoordinator.invalidate(generation: previousGeneration)
        previousTunnel = tunnel
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        connectionPollTask?.cancel()
        connectionPollTask = nil
        conduitFallbackTask?.cancel()
        conduitFallbackTask = nil
        conduitFallbackTimerStarted = false
        // Close the old callback gate before resetting readiness. A queued callback from the
        // previous singleton session must not mutate the new attempt while its generation is
        // being installed.
        callbacksActive = false
        generation = readiness.begin()
        activeGeneration = generation
        tunnel = nil
        packetMode = packetTunnel != nil
        packetTransportReady = false
        newPacketProviderAdapter = packetTunnel.map { packetTunnel in
            PsiphonPacketTunnelProviderAdapter(
                io: packetTunnel,
                transportStateHandler: { [weak self] state in
                    self?.handlePacketTransportState(state, generation: generation)
                }
            )
        }
        packetProviderAdapter = newPacketProviderAdapter
        _lastError = nil
        self.configJSON = configWithStore
        self.serverEntriesPath = serverEntriesPath ?? ""
        psiphonDataDirectory = dataDir
        callbackDelegate = PsiphonTunnelCallbackProxy(adapter: self, generation: generation)
        callbackProxy = callbackDelegate
        lock.unlock()

        previousContinuation?.resume(throwing: CancellationError())
        previousTunnel?.setPacketTunnelProvider(nil)
        previousTunnel?.stop()

        if hasEntries {
            SharedLogger.shared.logRaw("PSIPHON_ENTRIES_FILE", detail: serverEntriesPath ?? "")
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        SharedSettingsStore.shared.psiphonTunnelEstablished = false

        let newTunnel = PsiphonTunnel.newPsiphonTunnel(callbackDelegate)
        if let newPacketProviderAdapter {
            newTunnel.setPacketTunnelProvider(newPacketProviderAdapter)
        }
        lock.lock()
        let stillCurrent = activeGeneration == generation
        if stillCurrent {
            tunnel = newTunnel
        }
        lock.unlock()
        guard stillCurrent else {
            newTunnel.stop()
            throw CancellationError()
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((self?.connectWaitSeconds ?? 90) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.failStartIfStillWaiting(
                        reason: self?.startTimeoutReason(generation: generation)
                            ?? "psiphon_connect_timeout",
                        generation: generation
                    )
                }

                self.lock.lock()
                guard self.activeGeneration == generation else {
                    self.lock.unlock()
                    timeoutTask.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.startAttemptCoordinator.arm(
                    generation: generation,
                    continuation: continuation
                )
                self.startTimeoutTask = timeoutTask
                self.lock.unlock()

                let ok = newTunnel.start(false)
                if !ok {
                    self.failStartIfStillWaiting(
                        reason: "PsiphonTunnel.start returned false",
                        generation: generation
                    )
                } else {
                    self.activateCallbacksAndSeedReadiness(
                        generation: generation,
                        tunnel: newTunnel
                    )
                    // Shiro: start conduit auto→public timer right after startTunneling (not only onConnecting).
                    self.startConduitFallbackTimerIfNeeded(generation: generation)
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelStart(generation: generation, reason: "psiphon_start_cancelled")
        })
    }

    func stop() async {
        SharedLogger.shared.log(.psiphonStopRequested)

        let previousGeneration: UInt64
        let tunnelToStop: PsiphonTunnel?
        let continuation: CheckedContinuation<Void, Error>?
        let timeoutTask: Task<Void, Never>?
        let pollTask: Task<Void, Never>?
        let fallbackTask: Task<Void, Never>?
        lock.lock()
        previousGeneration = activeGeneration
        continuation = previousGeneration == 0
            ? nil
            : startAttemptCoordinator.claim(.cancelled, generation: previousGeneration)
        activeGeneration = 0
        callbacksActive = false
        tunnelToStop = tunnel
        timeoutTask = startTimeoutTask
        startTimeoutTask = nil
        pollTask = connectionPollTask
        connectionPollTask = nil
        fallbackTask = conduitFallbackTask
        conduitFallbackTask = nil
        packetMode = false
        packetTransportReady = false
        packetProviderAdapter = nil
        tunnel = nil
        callbackProxy = nil
        lock.unlock()

        timeoutTask?.cancel()
        pollTask?.cancel()
        fallbackTask?.cancel()
        readiness.cancel(generation: previousGeneration)
        tunnelToStop?.setPacketTunnelProvider(nil)
        tunnelToStop?.stop()
        continuation?.resume(throwing: CancellationError())
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
        SharedLogger.shared.log(.psiphonStopped)
    }

    private static func configJSON(
        _ jsonText: String,
        dataStoreDirectory: URL,
        hasEmbeddedServerEntries: Bool,
        packetMode: Bool = false
    ) throws -> String {
        let normalized = try PsiphonConfigValidator.normalizedJSON(
            jsonText,
            hasEmbeddedServerEntries: hasEmbeddedServerEntries
        )
        guard let data = normalized.data(using: .utf8),
              var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        dict["DataStoreDirectory"] = dataStoreDirectory.path
        let remoteListFile = dataStoreDirectory.appendingPathComponent("remote_server_list").path
        dict["MigrateRemoteServerListDownloadFilename"] = remoteListFile
        dict["EmitDiagnosticNotices"] = true
        dict["EmitBytesTransferred"] = true
        if packetMode {
            // These addresses are consumed by Psiphon's native packet tunnel
            // transport for transparent DNS rewriting. The Swift flow bridge
            // remains responsible for Secure DNS interception when enabled.
            dict["PacketTunnelTransparentDNSIPv4Address"] = "10.0.0.1"
            dict["PacketTunnelTransparentDNSIPv6Address"] = "fd00::1"
        }
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        return text
    }

    private func failStartIfStillWaiting(reason: String, generation callbackGeneration: UInt64) {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>?
        let pollTask: Task<Void, Never>?
        let fallbackTask: Task<Void, Never>?
        let tunnelToStop: PsiphonTunnel?
        lock.lock()
        guard activeGeneration == callbackGeneration,
              let claimedContinuation = startAttemptCoordinator.claim(
                .failed(reason),
                generation: callbackGeneration
              ) else {
            lock.unlock()
            return
        }
        continuation = claimedContinuation
        activeGeneration = 0
        callbacksActive = false
        _lastError = reason
        timeoutTask = startTimeoutTask
        startTimeoutTask = nil
        pollTask = connectionPollTask
        connectionPollTask = nil
        fallbackTask = conduitFallbackTask
        conduitFallbackTask = nil
        tunnelToStop = tunnel
        packetMode = false
        packetTransportReady = false
        packetProviderAdapter = nil
        tunnel = nil
        callbackProxy = nil
        lock.unlock()
        timeoutTask?.cancel()
        pollTask?.cancel()
        fallbackTask?.cancel()
        readiness.fail(reason: reason, generation: callbackGeneration)
        tunnelToStop?.setPacketTunnelProvider(nil)
        tunnelToStop?.stop()
        SharedLogger.shared.log(.psiphonStartFailed, detail: reason)
        continuation.resume(throwing: PsiphonTunnelCoreError.startFailed(reason))
    }

    private func cancelStart(generation callbackGeneration: UInt64, reason: String) {
        let continuation: CheckedContinuation<Void, Error>?
        let tunnelToStop: PsiphonTunnel?
        let timeoutTask: Task<Void, Never>?
        let pollTask: Task<Void, Never>?
        let fallbackTask: Task<Void, Never>?
        lock.lock()
        guard activeGeneration == callbackGeneration else {
            lock.unlock()
            return
        }
        activeGeneration = 0
        callbacksActive = false
        continuation = startAttemptCoordinator.claim(.cancelled, generation: callbackGeneration)
        tunnelToStop = tunnel
        tunnel = nil
        callbackProxy = nil
        timeoutTask = startTimeoutTask
        startTimeoutTask = nil
        pollTask = connectionPollTask
        connectionPollTask = nil
        fallbackTask = conduitFallbackTask
        conduitFallbackTask = nil
        packetMode = false
        packetTransportReady = false
        packetProviderAdapter = nil
        lock.unlock()

        timeoutTask?.cancel()
        pollTask?.cancel()
        fallbackTask?.cancel()
        readiness.cancel(generation: callbackGeneration)
        tunnelToStop?.setPacketTunnelProvider(nil)
        tunnelToStop?.stop()
        SharedLogger.shared.log(.psiphonStartFailed, detail: reason)
        continuation?.resume(throwing: CancellationError())
    }

    private func startTimeoutReason(generation callbackGeneration: UInt64) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == callbackGeneration else {
            return "psiphon_connect_timeout"
        }
        if packetMode && !packetTransportReady {
            return "psiphon_packet_transport_timeout"
        }
        return "psiphon_connect_timeout"
    }

    private func handlePacketTransportState(_ state: String, generation callbackGeneration: UInt64) {
        lock.lock()
        guard activeGeneration == callbackGeneration,
              packetMode,
              packetProviderAdapter != nil else {
            lock.unlock()
            return
        }
        packetTransportReady = state == "ready"
        lock.unlock()

        SharedLogger.shared.logRaw(
            "PSIPHON_PACKET_TRANSPORT_STATE",
            detail: "generation=\(callbackGeneration) state=\(state)"
        )
        guard state == "ready" else { return }
        finishStartIfReady(
            generation: callbackGeneration,
            endpoints: readiness.currentEndpoints
        )
    }

    private func logProxyMode(endpoints: PsiphonLocalProxyEndpoints) {
        guard endpoints.hasSocks else { return }
        SharedLogger.shared.logRaw(
            "PSIPHON_PROXY_MODE",
            detail: "forward=socks:\(endpoints.socksPort) system_http=\(endpoints.hasHttp ? String(endpoints.httpPort) : "off")"
        )
    }

    private func handleReadinessEvent(_ event: PsiphonReadinessStateMachine.Event) {
        switch event {
        case .started(let generation, let endpoints):
            finishStartIfReady(generation: generation, endpoints: endpoints)

        case .endpointsChanged(let generation, let endpoints):
            let handler: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)?
            lock.lock()
            guard activeGeneration == generation else {
                lock.unlock()
                return
            }
            handler = endpointChangeHandler
            lock.unlock()

            SharedLogger.shared.log(
                .psiphonLocalProxy,
                detail: "endpoint_changed socks=\(endpoints.socksPort) http=\(endpoints.httpPort)"
            )
            handler?(endpoints)

        case .failed(let generation, let reason):
            failStartIfStillWaiting(reason: reason, generation: generation)

        case .cancelled:
            break
        }
    }

    /// Full packet mode requires the generation-safe proxy readiness used by
    /// mandatory in-tunnel DoH and the independently established packet
    /// transport channel. Either signal may arrive first.
    private func finishStartIfReady(
        generation callbackGeneration: UInt64,
        endpoints: PsiphonLocalProxyEndpoints
    ) {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>?
        let nativePacketMode: Bool
        let packetReady: Bool
        lock.lock()
        guard activeGeneration == callbackGeneration else {
            lock.unlock()
            return
        }
        nativePacketMode = packetMode
        packetReady = packetTransportReady
        let ready = PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: nativePacketMode,
            hasPacketProvider: packetProviderAdapter != nil,
            packetTransportReady: packetReady,
            hasSocks: endpoints.hasSocks,
            coreConnected: readiness.isStarted
        )
        guard ready,
              let claimedContinuation = startAttemptCoordinator.claim(
                .started,
                generation: callbackGeneration
              ) else {
            lock.unlock()
            return
        }
        continuation = claimedContinuation
        timeoutTask = startTimeoutTask
        startTimeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        SharedLogger.shared.log(.psiphonStarted)
        logProxyMode(endpoints: endpoints)
        SharedLogger.shared.log(
            .psiphonLocalProxy,
            detail: "socks=\(endpoints.socksPort) http=\(endpoints.httpPort) packet_mode=\(nativePacketMode) packet_transport=\(packetReady)"
        )
        continuation.resume()
    }

    private func isCurrentGeneration(_ callbackGeneration: UInt64) -> Bool {
        lock.lock()
        let current = activeGeneration == callbackGeneration
        lock.unlock()
        return current
    }

    private func isCurrentCallbackGeneration(_ callbackGeneration: UInt64) -> Bool {
        lock.lock()
        let current = activeGeneration == callbackGeneration && callbacksActive
        lock.unlock()
        return current
    }

    /// The official iOS wrapper reuses a singleton, synchronously stops it in
    /// `newPsiphonTunnel`, and serializes delegate callbacks. Keep the new generation's
    /// readiness callbacks gated until `start` returns; then seed from the wrapper's atomic
    /// getters. This makes the stop/start callback-queue barrier explicit and prevents a queued
    /// callback from the stopped session from being relabeled as the new session.
    private func activateCallbacksAndSeedReadiness(
        generation callbackGeneration: UInt64,
        tunnel: PsiphonTunnel
    ) {
        lock.lock()
        guard activeGeneration == callbackGeneration else {
            lock.unlock()
            return
        }
        callbacksActive = true
        lock.unlock()

        let socksPort = tunnel.getLocalSocksProxyPort()
        if socksPort > 0 {
            handleListeningSocksProxyPort(socksPort, generation: callbackGeneration)
        }
        let httpPort = tunnel.getLocalHttpProxyPort()
        if httpPort > 0 {
            handleListeningHttpProxyPort(httpPort, generation: callbackGeneration)
        }
        if tunnel.getConnectionState() == .connected {
            handleConnected(generation: callbackGeneration)
        }
    }

    private func markEstablished(generation callbackGeneration: UInt64) {
        let fallbackTask: Task<Void, Never>?
        let state: Int?
        lock.lock()
        guard activeGeneration == callbackGeneration, callbacksActive else {
            lock.unlock()
            return
        }
        fallbackTask = conduitFallbackTask
        conduitFallbackTask = nil
        state = tunnel?.getConnectionState().rawValue
        lock.unlock()
        fallbackTask?.cancel()

        guard !SharedSettingsStore.shared.psiphonTunnelEstablished else {
            readiness.markCoreConnected(generation: callbackGeneration)
            return
        }
        SharedSettingsStore.shared.psiphonTunnelEstablished = true
        SharedLogger.shared.log(.psiphonTunnelEstablished, detail: "state=\(state ?? -1)")
        readiness.markCoreConnected(generation: callbackGeneration)
    }
}

extension PsiphonTunnelAdapter: TunneledAppDelegate {
    @objc func getPsiphonConfig() -> Any? {
        lock.lock()
        let config = configJSON
        lock.unlock()
        return config
    }

    @objc func getEmbeddedServerEntriesPath() -> String? {
        lock.lock()
        let path = serverEntriesPath
        lock.unlock()
        guard !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path) else {
            return nil
        }
        return path
    }

    @objc func getEmbeddedServerEntries() -> String? {
        nil
    }

    @objc func onListeningSocksProxyPort(_ port: Int) {
        guard let generation = currentCallbackGeneration else { return }
        handleListeningSocksProxyPort(port, generation: generation)
    }

    fileprivate func handleListeningSocksProxyPort(_ port: Int, generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        SharedLogger.shared.log(.psiphonProxyReady, detail: "socks=\(port)")
        readiness.markSocksReady(port: Int(port), generation: generation)
        startConnectionStatePoller(generation: generation)
    }

    @objc func onListeningHttpProxyPort(_ port: Int) {
        guard let generation = currentCallbackGeneration else { return }
        handleListeningHttpProxyPort(port, generation: generation)
    }

    fileprivate func handleListeningHttpProxyPort(_ port: Int, generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        readiness.markHTTPReady(port: Int(port), generation: generation)
    }

    @objc func onConnected() {
        guard let generation = currentCallbackGeneration else { return }
        handleConnected(generation: generation)
    }

    fileprivate func handleConnected(generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        markEstablished(generation: generation)
    }

    @objc func onConnecting() {
        guard let generation = currentCallbackGeneration else { return }
        handleConnecting(generation: generation)
    }

    fileprivate func handleConnecting(generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        lock.lock()
        if activeGeneration == generation {
            packetTransportReady = false
        }
        lock.unlock()
        readiness.markCoreDisconnected(generation: generation)
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
        TunnelStatisticsStore.setConnectedTunnelProtocol("")
        if SharedSettingsStore.shared.effectiveAppSettings.protocolSelection == .conduit {
            lock.lock()
            let composedJSON = configJSON
            lock.unlock()
            let missingKeys = !PsiphonDistributorKeys.readiness(
                composedJSON: composedJSON,
                embeddedServerEntryLines: SharedSettingsStore.shared.psiphonServerEntriesLineCount
            ).allowsConduit
            if missingKeys {
                SharedLogger.shared.logRaw(
                    "CONDUIT_BLOCKED",
                    detail: "missing_distributor_keys \(SharedSettingsStore.shared.conduitDistributorReadiness.logDetail)"
                )
            }
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: missingKeys)
        }
    }

    private func startConduitFallbackTimerIfNeeded(generation: UInt64) {
        let settings = SharedSettingsStore.shared.effectiveAppSettings
        guard settings.protocolSelection == .conduit,
              settings.conduitMode == .auto,
              !settings.conduitFallbackToPublic else { return }
        let timeoutSec = max(60, settings.conduitTimeoutSeconds)
        let previousTask: Task<Void, Never>?
        let fallbackTask: Task<Void, Never>
        lock.lock()
        guard activeGeneration == generation, !conduitFallbackTimerStarted else {
            lock.unlock()
            return
        }
        conduitFallbackTimerStarted = true
        previousTask = conduitFallbackTask
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isCurrentGeneration(generation) else { return }
            guard !SharedSettingsStore.shared.psiphonTunnelEstablished else { return }

            var appSettings = SharedSettingsStore.shared.effectiveAppSettings
            appSettings.conduitFallbackToPublic = true
            if SharedSettingsStore.shared.recoveryTrialSettings != nil {
                SharedSettingsStore.shared.applyRecoveryTrialSettings(appSettings)
            } else {
                SharedSettingsStore.shared.updateAppSettings(appSettings, logKey: "conduit_fallback_timeout")
            }
            SharedLogger.shared.logRaw("CONDUIT_PUBLIC_FALLBACK", detail: "timeout_s=\(timeoutSec)")
            PsiphonCommunityDiagnostics.notePublicFallback()
            SharedLogger.shared.logRaw(
                "CONDUIT_FALLBACK",
                detail: "timeout_s=\(timeoutSec) action=public_relays"
            )
            TunnelStatisticsStore.setConduitStatusLine(
                "Community relays timed out — trying public Conduit relays…"
            )

            do {
                try SharedSettingsStore.shared.recomposeEffectiveConfig()
                self.lock.lock()
                let base = SharedSettingsStore.shared.psiphonConfigJSON
                let dataDir = self.psiphonDataDirectory
                let entriesPath = self.serverEntriesPath
                let nativePacketMode = self.packetMode
                self.lock.unlock()
                guard let base, let dataDir else { return }
                let hasEntries = !entriesPath.isEmpty
                    && FileManager.default.fileExists(atPath: entriesPath)
                let merged = try Self.configJSON(
                    base,
                    dataStoreDirectory: dataDir,
                    hasEmbeddedServerEntries: hasEntries,
                    packetMode: nativePacketMode
                )
                self.lock.lock()
                guard self.activeGeneration == generation else {
                    self.lock.unlock()
                    return
                }
                self.configJSON = merged
                let currentTunnel = self.tunnel
                self.lock.unlock()
                let ok = currentTunnel?.stopAndReconnectWithCurrentSessionID() ?? false
                if !ok {
                    SharedLogger.shared.logRaw("CONDUIT_FALLBACK", detail: "reconnect_failed")
                }
            } catch {
                SharedLogger.shared.logRaw(
                    "CONDUIT_FALLBACK",
                    detail: "recompose_failed error=\(error.localizedDescription)"
                )
            }
        }
        conduitFallbackTask = fallbackTask
        lock.unlock()
        previousTask?.cancel()
    }

    private static var diagLogCount = 0
    private static let diagLogCap = 40

    @objc func onDiagnosticMessage(_ message: String, withTimestamp timestamp: String) {
        let lower = message.lowercased()
        PsiphonRemoteServerListDiagnostics.handleDiagnostic(message)
        if SharedSettingsStore.shared.effectiveAppSettings.protocolSelection == .conduit {
            PsiphonShiroConduitCompare.logDiagnostic(message)
            PsiphonCommunityDiagnostics.handleDiagnostic(message)
        }
        if let raw = ConnectedTunnelProtocolParser.extractProtocol(from: message) {
            TunnelStatisticsStore.setConnectedTunnelProtocol(raw)
            let display = ConnectedTunnelProtocolParser.displayName(for: raw)
            SharedLogger.shared.logRaw(
                "PSIPHON_CONNECTED_PROTOCOL",
                detail: "raw=\(raw) display=\(display)"
            )
            if raw.hasPrefix("INPROXY-WEBRTC-") {
                SharedLogger.shared.logRaw("CONDUIT_CONNECTED_PROTOCOL", detail: "raw=\(raw)")
            }
        }
        _ = PsiphonShiroCDNFrontingConfig.parseDiagnosticNotice(message)
        if lower.contains("tunnel connected") || lower.contains("beast mode") {
            let snippet = message.count > 240 ? String(message.prefix(240)) : message
            SharedLogger.shared.logRaw("PSIPHON_TUNNEL_PROTOCOL", detail: snippet)
        }
        if lower.contains("failed to make dial parameters") || lower.contains("verifysignature") {
            TunnelStatisticsStore.setConduitStatusLine(message)
            if Self.diagLogCount < Self.diagLogCap {
                let snippet = message.count > 220 ? String(message.prefix(220)) : message
                SharedLogger.shared.logRaw("PSIPHON_CONDUIT_VERIFY", detail: snippet)
                Self.diagLogCount += 1
            }
            return
        }
        if lower.contains("inproxy") || lower.contains("in-proxy") || lower.contains("conduit relay")
            || message.contains("CandidateServers") {
            TunnelStatisticsStore.setConduitStatusLine(message)
            if Self.diagLogCount < Self.diagLogCap {
                let snippet = message.count > 220 ? String(message.prefix(220)) : message
                SharedLogger.shared.logRaw("PSIPHON_INPROXY", detail: snippet)
            }
        }
        guard lower.contains("error") || lower.contains("connect") || lower.contains("fail")
            || lower.contains("established") || lower.contains("protocol") else { return }
        guard Self.diagLogCount < Self.diagLogCap else { return }
        Self.diagLogCount += 1
        let snippet = message.count > 200 ? String(message.prefix(200)) : message
        SharedLogger.shared.logRaw("PSIPHON_DIAG", detail: snippet)
    }

    @objc func onConnectionStateChanged(from oldState: PsiphonConnectionState, to newState: PsiphonConnectionState) {
        guard let generation = currentCallbackGeneration else { return }
        handleConnectionStateChanged(from: oldState, to: newState, generation: generation)
    }

    fileprivate func handleConnectionStateChanged(
        from oldState: PsiphonConnectionState,
        to newState: PsiphonConnectionState,
        generation: UInt64
    ) {
        guard isCurrentCallbackGeneration(generation) else { return }
        SharedLogger.shared.logRaw(
            "PSIPHON_STATE",
            detail: "from=\(oldState.rawValue) to=\(newState.rawValue)"
        )
        if newState == .connected {
            handleConnected(generation: generation)
        } else if newState == .disconnected {
            handleCoreDisconnected(generation: generation)
        }
    }

    @objc func onConnectedServerRegion(_ region: String) {
        SharedLogger.shared.logRaw("PSIPHON_REGION", detail: region)
        TunnelStatisticsStore.setConnectedServerRegion(region)
    }

    @objc func onBytesTransferred(_ sent: Int64, _ received: Int64) {
        TunnelStatisticsStore.recordTransferred(sent: sent, received: received)
    }

    private func startConnectionStatePoller(generation: UInt64) {
        let previousTask: Task<Void, Never>?
        let pollTask: Task<Void, Never>
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        previousTask = connectionPollTask
        pollTask = Task { [weak self] in
            for _ in 0..<Int((self?.connectWaitSeconds ?? 90) * 2) {
                guard let self else { return }
                guard self.isCurrentGeneration(generation) else { return }
                self.lock.lock()
                let currentTunnel = self.tunnel
                self.lock.unlock()
                let state = currentTunnel?.getConnectionState()
                if state == .connected {
                    self.handleConnected(generation: generation)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            guard self.isCurrentGeneration(generation) else { return }
            self.lock.lock()
            let currentTunnel = self.tunnel
            self.lock.unlock()
            let finalState = currentTunnel?.getConnectionState().rawValue
            SharedLogger.shared.logRaw("PSIPHON_STATE_POLL", detail: "timeout last_state=\(finalState ?? -1)")
        }
        connectionPollTask = pollTask
        lock.unlock()
        previousTask?.cancel()
    }

    @objc func onExiting() {
        guard let generation = currentCallbackGeneration else { return }
        handleExiting(generation: generation)
    }

    private func handleCoreDisconnected(generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        lock.lock()
        if activeGeneration == generation {
            packetTransportReady = false
        }
        lock.unlock()
        readiness.markCoreDisconnected(generation: generation)
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
    }

    fileprivate func handleExiting(generation: UInt64) {
        guard isCurrentCallbackGeneration(generation) else { return }
        lock.lock()
        let packetAdapter = activeGeneration == generation && packetMode
            ? packetProviderAdapter
            : nil
        lock.unlock()
        handleCoreDisconnected(generation: generation)
        packetAdapter?.fail(NSError(
            domain: "AzadiTunnel.PsiphonPacketTunnel",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "psiphon_packet_core_exited"]
        ))
        failStartIfStillWaiting(reason: "psiphon_exiting", generation: generation)
    }

    private var currentCallbackGeneration: UInt64? {
        lock.lock()
        let generation = activeGeneration
        let active = callbacksActive
        lock.unlock()
        return generation == 0 || !active ? nil : generation
    }
}

/// Gives every PsiphonTunnel start attempt an immutable callback generation. The framework's
/// singleton stop/start callback-queue barrier is paired with the adapter's callback activation
/// gate above, so readiness callbacks cannot be relabeled across generations.
private final class PsiphonTunnelCallbackProxy: NSObject, TunneledAppDelegate {
    weak var adapter: PsiphonTunnelAdapter?
    let generation: UInt64

    init(adapter: PsiphonTunnelAdapter, generation: UInt64) {
        self.adapter = adapter
        self.generation = generation
        super.init()
    }

    @objc func getPsiphonConfig() -> Any? {
        adapter?.getPsiphonConfig()
    }

    @objc func getEmbeddedServerEntriesPath() -> String? {
        adapter?.getEmbeddedServerEntriesPath()
    }

    @objc func getEmbeddedServerEntries() -> String? {
        adapter?.getEmbeddedServerEntries()
    }

    @objc func onConnecting() {
        adapter?.handleConnecting(generation: generation)
    }

    @objc func onConnected() {
        adapter?.handleConnected(generation: generation)
    }

    @objc func onConnectionStateChanged(from oldState: PsiphonConnectionState, to newState: PsiphonConnectionState) {
        adapter?.handleConnectionStateChanged(
            from: oldState,
            to: newState,
            generation: generation
        )
    }

    @objc func onExiting() {
        adapter?.handleExiting(generation: generation)
    }

    @objc func onListeningSocksProxyPort(_ port: Int) {
        adapter?.handleListeningSocksProxyPort(port, generation: generation)
    }

    @objc func onListeningHttpProxyPort(_ port: Int) {
        adapter?.handleListeningHttpProxyPort(port, generation: generation)
    }

    override func responds(to aSelector: Selector) -> Bool {
        if super.responds(to: aSelector) { return true }
        return adapter?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector) -> Any? {
        adapter ?? super.forwardingTarget(for: aSelector)
    }
}

enum ExtensionPsiphonCore {
    static func make() -> PsiphonTunnelCoreProtocol {
        PsiphonTunnelAdapter()
    }
}
