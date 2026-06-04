import Foundation
import PsiphonTunnel

/// Bridges PsiphonTunnel Objective-C API — **packet tunnel target only** (links PsiphonTunnel.framework).
final class PsiphonTunnelAdapter: NSObject, PsiphonTunnelCoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tunnel: PsiphonTunnel?
    private var configJSON: String = ""
    private var serverEntriesPath: String = ""
    private var _lastError: String?
    private var socksPort: Int = 0
    private var httpPort: Int = 0
    private var connected = false
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?
    private var proxySelectionTask: Task<Void, Never>?
    private var connectionPollTask: Task<Void, Never>?
    private var conduitFallbackTask: Task<Void, Never>?
    private var conduitFallbackTimerStarted = false
    private var psiphonDataDirectory: URL?

    private var connectWaitSeconds: TimeInterval {
        let settings = SharedSettingsStore.shared.appSettings
        if settings.protocolSelection == .conduit { return 120 }
        if settings.beastModeEnabled { return 120 }
        return 90
    }
    private let httpProxyWaitNs: UInt64 = 2_500_000_000

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected && socksPort > 0
    }

    var localProxyHost: String { "127.0.0.1" }

    var localProxyPort: Int {
        lock.lock()
        defer { lock.unlock() }
        return socksPort
    }

    var localProxyType: PsiphonLocalProxyType {
        lock.lock()
        defer { lock.unlock() }
        if socksPort > 0 && httpPort > 0 { return .dual }
        if socksPort > 0 { return .socks }
        if httpPort > 0 { return .http }
        return .unknown
    }

    var localProxyEndpoints: PsiphonLocalProxyEndpoints {
        lock.lock()
        defer { lock.unlock() }
        return PsiphonLocalProxyEndpoints(host: localProxyHost, socksPort: socksPort, httpPort: httpPort)
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    func start(configJSON: String, serverEntriesPath: String?, dataDir: URL) async throws {
        Self.diagLogCount = 0
        let hasEntries = !(serverEntriesPath ?? "").isEmpty
            && FileManager.default.fileExists(atPath: serverEntriesPath ?? "")
        let configWithStore = try Self.configJSON(
            configJSON,
            dataStoreDirectory: dataDir,
            hasEmbeddedServerEntries: hasEntries
        )
        try PsiphonConfigValidator.validate(configWithStore, hasEmbeddedServerEntries: hasEntries)
        SharedLogger.shared.log(.psiphonConfigValid)
        SharedLogger.shared.log(.psiphonStartRequested)

        self.configJSON = configWithStore
        self.serverEntriesPath = serverEntriesPath ?? ""
        self.psiphonDataDirectory = dataDir
        if hasEntries {
            SharedLogger.shared.logRaw("PSIPHON_ENTRIES_FILE", detail: serverEntriesPath ?? "")
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        socksPort = 0
        httpPort = 0
        proxySelectionTask?.cancel()
        connectionPollTask?.cancel()
        conduitFallbackTask?.cancel()
        conduitFallbackTimerStarted = false
        startTimeoutTask?.cancel()
        SharedSettingsStore.shared.psiphonTunnelEstablished = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuation = continuation
            tunnel = PsiphonTunnel.newPsiphonTunnel(self)
            lock.unlock()

            startTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.connectWaitSeconds ?? 90) * 1_000_000_000))
                self?.failStartIfStillWaiting(reason: "psiphon_connect_timeout")
            }

            let ok = tunnel?.start(false) ?? false
            if !ok {
                failStartIfStillWaiting(reason: "PsiphonTunnel.start returned false")
            } else {
                // Shiro: start conduit auto→public timer right after startTunneling (not only onConnecting).
                startConduitFallbackTimerIfNeeded()
            }
        }
    }

    func stop() async {
        proxySelectionTask?.cancel()
        connectionPollTask?.cancel()
        conduitFallbackTask?.cancel()
        startTimeoutTask?.cancel()
        SharedLogger.shared.log(.psiphonStopRequested)
        lock.lock()
        tunnel?.stop()
        connected = false
        socksPort = 0
        httpPort = 0
        tunnel = nil
        lock.unlock()
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
        SharedLogger.shared.log(.psiphonStopped)
    }

    private static func configJSON(
        _ jsonText: String,
        dataStoreDirectory: URL,
        hasEmbeddedServerEntries: Bool
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
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        return text
    }

    private func failStartIfStillWaiting(reason: String) {
        lock.lock()
        guard let continuation = startContinuation else {
            lock.unlock()
            return
        }
        startContinuation = nil
        _lastError = reason
        lock.unlock()
        startTimeoutTask?.cancel()
        SharedLogger.shared.log(.psiphonStartFailed, detail: reason)
        continuation.resume(throwing: PsiphonTunnelCoreError.startFailed(reason))
    }

    private func scheduleProxySelection() {
        lock.lock()
        let socksReady = socksPort > 0
        lock.unlock()
        guard socksReady else { return }

        proxySelectionTask?.cancel()
        proxySelectionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.httpProxyWaitNs)
            self.logProxyMode()
            self.tryFinishStartIfReady()
        }
    }

    private func logProxyMode() {
        lock.lock()
        let socks = socksPort
        let http = httpPort
        lock.unlock()
        guard socks > 0 else { return }
        SharedLogger.shared.logRaw(
            "PSIPHON_PROXY_MODE",
            detail: "forward=socks:\(socks) system_http=\(http > 0 ? String(http) : "off")"
        )
    }

    /// Resume `start()` only when SOCKS is listening **and** tunnel-core reports connected.
    private func tryFinishStartIfReady() {
        lock.lock()
        guard let continuation = startContinuation, socksPort > 0 else {
            lock.unlock()
            return
        }
        let state = tunnel?.getConnectionState()
        guard state == .connected else {
            lock.unlock()
            return
        }
        startContinuation = nil
        connected = true
        lock.unlock()

        startTimeoutTask?.cancel()
        SharedLogger.shared.log(.psiphonStarted)
        SharedLogger.shared.log(
            .psiphonLocalProxy,
            detail: "socks=\(socksPort) http=\(httpPort)"
        )
        continuation.resume()
    }

    private func markEstablished() {
        guard !SharedSettingsStore.shared.psiphonTunnelEstablished else {
            tryFinishStartIfReady()
            return
        }
        conduitFallbackTask?.cancel()
        SharedSettingsStore.shared.psiphonTunnelEstablished = true
        lock.lock()
        let state = tunnel?.getConnectionState().rawValue
        lock.unlock()
        SharedLogger.shared.log(.psiphonTunnelEstablished, detail: "state=\(state ?? -1)")
        tryFinishStartIfReady()
    }
}

extension PsiphonTunnelAdapter: TunneledAppDelegate {
    @objc func getPsiphonConfig() -> Any? {
        configJSON
    }

    @objc func getEmbeddedServerEntriesPath() -> String? {
        guard !serverEntriesPath.isEmpty,
              FileManager.default.isReadableFile(atPath: serverEntriesPath) else {
            return nil
        }
        return serverEntriesPath
    }

    @objc func getEmbeddedServerEntries() -> String? {
        nil
    }

    @objc func onListeningSocksProxyPort(_ port: Int) {
        lock.lock()
        socksPort = Int(port)
        lock.unlock()
        SharedLogger.shared.log(.psiphonProxyReady, detail: "socks=\(port)")
        scheduleProxySelection()
        startConnectionStatePoller()
        tryFinishStartIfReady()
    }

    @objc func onListeningHttpProxyPort(_ port: Int) {
        lock.lock()
        httpPort = Int(port)
        let socks = socksPort
        lock.unlock()
        if socks > 0 {
            logProxyMode()
            tryFinishStartIfReady()
        }
    }

    @objc func onConnected() {
        markEstablished()
    }

    @objc func onConnecting() {
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
        TunnelStatisticsStore.setConnectedTunnelProtocol("")
        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit {
            let missingKeys = !PsiphonDistributorKeys.readiness(
                composedJSON: configJSON,
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

    private func startConduitFallbackTimerIfNeeded() {
        let settings = SharedSettingsStore.shared.appSettings
        guard settings.protocolSelection == .conduit,
              settings.conduitMode == .auto,
              !settings.conduitFallbackToPublic else { return }
        guard !conduitFallbackTimerStarted else { return }
        conduitFallbackTimerStarted = true
        conduitFallbackTask?.cancel()

        let timeoutSec = max(60, settings.conduitTimeoutSeconds)
        conduitFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard !SharedSettingsStore.shared.psiphonTunnelEstablished else { return }

            var appSettings = SharedSettingsStore.shared.appSettings
            appSettings.conduitFallbackToPublic = true
            SharedSettingsStore.shared.updateAppSettings(appSettings, logKey: "conduit_fallback_timeout")
            SharedLogger.shared.logRaw("CONDUIT_PUBLIC_FALLBACK", detail: "timeout_s=\(timeoutSec)")
            PsiphonCommunityDiagnostics.notePublicFallback()
            SharedLogger.shared.logRaw(
                "CONDUIT_FALLBACK",
                detail: "timeout_s=\(timeoutSec) action=public_relays"
            )
            TunnelStatisticsStore.setConduitStatusLine(
                "Community relays timed out — trying public Conduit relays…"
            )

            guard let self else { return }
            do {
                try SharedSettingsStore.shared.recomposeEffectiveConfig()
                guard let base = SharedSettingsStore.shared.psiphonConfigJSON,
                      let dataDir = self.psiphonDataDirectory else { return }
                let hasEntries = !self.serverEntriesPath.isEmpty
                    && FileManager.default.fileExists(atPath: self.serverEntriesPath)
                let merged = try Self.configJSON(
                    base,
                    dataStoreDirectory: dataDir,
                    hasEmbeddedServerEntries: hasEntries
                )
                self.lock.lock()
                self.configJSON = merged
                let ok = self.tunnel?.stopAndReconnectWithCurrentSessionID() ?? false
                self.lock.unlock()
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
    }

    private static var diagLogCount = 0
    private static let diagLogCap = 40

    @objc func onDiagnosticMessage(_ message: String, withTimestamp timestamp: String) {
        let lower = message.lowercased()
        PsiphonRemoteServerListDiagnostics.handleDiagnostic(message)
        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit {
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
        SharedLogger.shared.logRaw(
            "PSIPHON_STATE",
            detail: "from=\(oldState.rawValue) to=\(newState.rawValue)"
        )
        if newState == .connected {
            markEstablished()
        } else if newState == .disconnected {
            SharedSettingsStore.shared.psiphonTunnelEstablished = false
        }
    }

    @objc func onConnectedServerRegion(_ region: String) {
        SharedLogger.shared.logRaw("PSIPHON_REGION", detail: region)
        TunnelStatisticsStore.setConnectedServerRegion(region)
    }

    @objc func onBytesTransferred(_ sent: Int64, _ received: Int64) {
        TunnelStatisticsStore.recordTransferred(sent: sent, received: received)
    }

    private func startConnectionStatePoller() {
        connectionPollTask?.cancel()
        connectionPollTask = Task { [weak self] in
            for _ in 0..<Int((self?.connectWaitSeconds ?? 90) * 2) {
                guard let self else { return }
                self.lock.lock()
                let state = self.tunnel?.getConnectionState()
                self.lock.unlock()
                if state == .connected {
                    self.markEstablished()
                    return
                }
                self.tryFinishStartIfReady()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            self.lock.lock()
            let finalState = self.tunnel?.getConnectionState().rawValue
            self.lock.unlock()
            SharedLogger.shared.logRaw("PSIPHON_STATE_POLL", detail: "timeout last_state=\(finalState ?? -1)")
        }
    }

    @objc func onExiting() {
        lock.lock()
        connected = false
        lock.unlock()
        SharedSettingsStore.shared.psiphonTunnelEstablished = false
    }
}

enum ExtensionPsiphonCore {
    static func make() -> PsiphonTunnelCoreProtocol {
        PsiphonTunnelAdapter()
    }
}
