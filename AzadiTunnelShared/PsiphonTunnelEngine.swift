import Foundation

/// Unified Psiphon lifecycle wrapper (extension uses live core; app uses stub).
final class PsiphonTunnelEngine: @unchecked Sendable {
    private let core: PsiphonTunnelCoreProtocol
    private let endpointHandlerLock = NSLock()
    private var endpointHandler: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)?

    init(core: PsiphonTunnelCoreProtocol) {
        self.core = core
        core.onLocalProxyEndpointsChanged = { [weak self] endpoints in
            Task { @MainActor [weak self] in
                self?.notifyLocalProxyEndpointsChanged(endpoints)
            }
        }
    }

    var isRunning: Bool { core.isRunning }
    var localProxyHost: String { core.localProxyHost }
    var localProxyPort: Int { core.localProxyPort }
    var localProxyType: PsiphonLocalProxyType { core.localProxyType }
    var localProxyEndpoints: PsiphonLocalProxyEndpoints { core.localProxyEndpoints }
    var packetEngineCapabilities: PacketEngineCapabilities { core.packetEngineCapabilities }
    var lastError: String? { core.lastError }

    var onLocalProxyEndpointsChanged: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)? {
        get {
            endpointHandlerLock.lock()
            defer { endpointHandlerLock.unlock() }
            return endpointHandler
        }
        set {
            endpointHandlerLock.lock()
            endpointHandler = newValue
            endpointHandlerLock.unlock()
        }
    }

    func start(
        configJSON: String,
        serverEntriesPath: String?,
        dataDir: URL,
        packetTunnel: PsiphonPacketTunnelIO? = nil
    ) async throws {
        SharedLogger.shared.log(.psiphonConnectRequested)
        do {
            try await core.start(
                configJSON: configJSON,
                serverEntriesPath: serverEntriesPath,
                dataDir: dataDir,
                packetTunnel: packetTunnel
            )
            let ep = core.localProxyEndpoints
            SharedLogger.shared.log(
                .psiphonConnected,
                detail: "socks=\(ep.socksPort) http=\(ep.httpPort)"
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            SharedLogger.shared.log(.psiphonConnectFailed, detail: "reason=\(reason)")
            throw error
        }
    }

    func stop() async {
        SharedLogger.shared.log(.psiphonDisconnected)
        await core.stop()
    }

    /// Stop tunnel-core but do not block shutdown longer than `seconds` (Conduit teardown can be slow).
    func stopWithTimeout(seconds: TimeInterval) async {
        SharedLogger.shared.log(.psiphonDisconnected)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.core.stop()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                return false
            }
            let finishedStop = await group.next() ?? false
            group.cancelAll()
            if !finishedStop {
                SharedLogger.shared.logRaw(
                    "PSIPHON_STOP_TIMEOUT",
                    detail: "timeout_s=\(Int(seconds)) action=proceed_tunnel_teardown"
                )
            }
        }
    }

    private func notifyLocalProxyEndpointsChanged(_ endpoints: PsiphonLocalProxyEndpoints) {
        endpointHandlerLock.lock()
        let handler = endpointHandler
        endpointHandlerLock.unlock()
        handler?(endpoints)
    }
}
