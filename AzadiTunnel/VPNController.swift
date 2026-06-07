import Foundation
import Combine
import NetworkExtension

enum VPNBannerKind: Equatable {
    case none
    case noConfig
    case conduitBlocked
    case vpnPermission
    case otherVpnBlocking
    case psiphonFailed
    case internetTestFailed
}

@MainActor
final class VPNController: ObservableObject {
    static let shared = VPNController()

    @Published private(set) var status: VPNStatusDisplay = .disconnected
    @Published private(set) var statusMessage: String = "Disconnected"
    @Published private(set) var lastError: String?
    @Published private(set) var banner: VPNBannerKind = .none
    @Published private(set) var statistics: TunnelStatistics = TunnelStatistics()
    @Published private(set) var vpnOnDemandEnabledOnDevice: Bool = false

    private var manager: NETunnelProviderManager?
    private let providerBundleID = "com.polamgh.ali.AzadiTunnel.PacketTunnel"
    private var reconnectTask: Task<Void, Never>?
    /// User tapped Disconnect — keep UI on Disconnected while iOS tears down the tunnel.
    private var optimisticDisconnect = false

    init() {
        Task { await refreshStatusFromSystem() }
    }

    func refreshStatusFromSystem() async {
        do {
            manager = try await VPNProfileCoordinator.loadManager()
            if let manager {
                vpnOnDemandEnabledOnDevice = manager.isOnDemandEnabled
            }
            updateFromManager()
        } catch {
            lastError = error.localizedDescription
            banner = .vpnPermission
        }
    }

    /// Refresh NE status before Connect/Disconnect so UI matches iOS when the tunnel died externally.
    func prepareForUserToggle() async {
        await refreshStatusFromSystem()
    }

    func refreshStatistics() {
        statistics = TunnelStatisticsStore.load()
    }

    func connect(skipFallbackChain: Bool = false) async {
        lastError = nil
        banner = .none

        guard SharedSettingsStore.shared.appSettings.hasAcceptedConnectionDisclaimer else {
            SharedLogger.shared.logRaw("CONNECT_BLOCKED_PENDING_DISCLAIMER", detail: "source=vpn_controller")
            lastError = "Accept the connection disclaimer before connecting."
            return
        }

        if !SharedSettingsStore.shared.hasActivePsiphonConfig {
            if !PsiphonBootstrap.installBundledConfigIfNeeded() {
                lastError = PsiphonBootstrap.setupHintForUser
                status = .error
                statusMessage = "Setup required"
                banner = .noConfig
                return
            }
        }

        guard SharedSettingsStore.shared.hasActivePsiphonConfig else {
            lastError = PsiphonBootstrap.setupHintForUser
            status = .error
            statusMessage = "Setup required"
            banner = .noConfig
            return
        }

        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit,
           !SharedSettingsStore.shared.conduitConnectAllowed {
            let readiness = SharedSettingsStore.shared.conduitDistributorReadiness
            SharedLogger.shared.logRaw("CONDUIT_BLOCKED", detail: "missing_distributor_keys \(readiness.logDetail)")
            lastError = PsiphonDistributorKeys.conduitBlockedStatusLine
            status = .error
            statusMessage = PsiphonDistributorKeys.conduitBlockedStatusLine
            banner = .conduitBlocked
            TunnelStatisticsStore.clearConduitStatus()
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: true)
            refreshStatistics()
            return
        }

        let selection = SharedSettingsStore.shared.appSettings.protocolSelection
        if !skipFallbackChain, FallbackChainController.shouldUseChain(for: selection) {
            let ok = await FallbackChainController.connectWithChain(vpn: self)
            if !ok, lastError == nil {
                setFallbackFailureMessage("Could not connect. See Logs for FALLBACK_* lines.")
            }
            return
        }

        await startTunnel()
    }

    private func startTunnel() async {
        SharedLogger.shared.log(.vpnConnectRequested)
        SharedSettingsStore.shared.vpnStatus = .connecting
        status = .connecting
        statusMessage = "Connecting…"
        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit {
            TunnelStatisticsStore.clearConduitStatus()
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: false)
            refreshStatistics()
        }

        do {
            let mgr = try await ensureManager()
            if mgr.connection.status == .connected || mgr.connection.status == .connecting {
                SharedLogger.shared.logRaw(
                    "VPN_START_RESET_STALE",
                    detail: "ne_status=\(mgr.connection.status.rawValue)"
                )
                mgr.connection.stopVPNTunnel()
                try? await TaskSleep.milliseconds(500)
            }
            optimisticDisconnect = false
            SharedLogger.shared.log(.vpnStartRequested)
            try await startVPNTunnel(on: mgr)
            observeConnection(mgr)
        } catch {
            handleConnectFailure(error)
        }
    }

    private func startVPNTunnel(on mgr: NETunnelProviderManager) async throws {
        do {
            try mgr.connection.startVPNTunnel()
        } catch {
            guard VPNProfileCoordinator.isConfigurationDisabledError(error) else { throw error }
            SharedLogger.shared.logRaw("VPN_CONFIG_DISABLED", detail: "action=reenable_and_retry")
            let settings = SharedSettingsStore.shared.appSettings
            let repaired = try await VPNProfileCoordinator.ensureEnabled(manager: mgr, settings: settings)
            manager = repaired
            try repaired.connection.startVPNTunnel()
        }
    }

    private func handleConnectFailure(_ error: Error) {
        if VPNProfileCoordinator.isConfigurationDisabledError(error) {
            lastError = nil
            status = .error
            statusMessage = "Failed"
            banner = .otherVpnBlocking
            SharedSettingsStore.shared.vpnStatus = .error
            SharedLogger.shared.logRaw(
                "VPN_OTHER_ACTIVE",
                detail: "ne_code=2 hint=settings_vpn"
            )
            return
        }
        lastError = error.localizedDescription
        status = .error
        statusMessage = "Failed"
        banner = .psiphonFailed
        SharedSettingsStore.shared.vpnStatus = .error
        SharedLogger.shared.log(.psiphonConnectFailed, detail: "reason=\(error.localizedDescription)")
    }

    func runPostConnectDiagnostics() async {
        await handleConnectedSideEffects()
    }

    func setFallbackFailureMessage(_ message: String) {
        lastError = message
        status = .error
        statusMessage = "Failed"
        banner = .psiphonFailed
        SharedSettingsStore.shared.vpnStatus = .error
    }

    func disconnect() async {
        reconnectTask?.cancel()
        lastError = nil
        banner = .none
        SharedLogger.shared.log(.vpnDisconnectRequested)

        if manager == nil {
            await refreshStatusFromSystem()
        }

        let neStatus = manager?.connection.status
        switch neStatus {
        case .connected, .connecting, .reasserting, .disconnecting:
            optimisticDisconnect = true
            SharedLogger.shared.log(.vpnStopRequested)
            manager?.connection.stopVPNTunnel()
        default:
            optimisticDisconnect = false
            SharedLogger.shared.logRaw(
                "VPN_DISCONNECT_NOOP",
                detail: "ne_status=\(neStatus.map { String($0.rawValue) } ?? "nil") action=clear_local_state"
            )
        }

        if let mgr = manager, !mgr.isEnabled {
            try? await VPNProfileCoordinator.ensureEnabled(
                manager: mgr,
                settings: SharedSettingsStore.shared.appSettings
            )
        }
        applyDisconnectedState()
    }

    private func applyDisconnectedState() {
        TunnelStatisticsStore.markDisconnected()
        TunnelStatisticsStore.clearPublicIP()
        var appSettings = SharedSettingsStore.shared.appSettings
        if appSettings.conduitFallbackToPublic {
            appSettings.conduitFallbackToPublic = false
            SharedSettingsStore.shared.updateAppSettings(appSettings, logKey: "conduit_fallback_reset")
        }
        status = .disconnected
        statusMessage = "Disconnected"
        SharedSettingsStore.shared.vpnStatus = .disconnected
        banner = .none
        refreshStatistics()
    }

    func handleConnectedSideEffects() async {
        refreshStatistics()
        let ok = await InternetConnectivityTest.waitForExtensionResult()
        if ok {
            banner = .none
            await PublicIPFetcher.fetchIfNeeded()
            refreshStatistics()
            _ = await LeakTestService.runAfterConnect()
            _ = await ConnectionQualityService.runAfterConnect()
        } else {
            banner = .internetTestFailed
            lastError = "VPN is up but internet check failed. See Logs for INTERNET_TEST_* and PSIPHON_PROXY_MODE."
        }
        refreshStatistics()
        scheduleAutoReconnectIfNeeded()
    }

    private func scheduleAutoReconnectIfNeeded() {
        reconnectTask?.cancel()
        guard SharedSettingsStore.shared.appSettings.autoReconnect else { return }
        reconnectTask = Task {
            while !Task.isCancelled {
                try? await TaskSleep.seconds(5)
                guard status == .connected else { continue }
                let shared = SharedSettingsStore.shared.vpnStatus
                if shared == .disconnected {
                    await connect()
                }
            }
        }
    }

    func applyOnDemandFromAppSettings() async {
        lastError = nil
        do {
            let mgr = try await ensureManager()
            let settings = SharedSettingsStore.shared.appSettings
            VPNOnDemandConfigurator.apply(to: mgr, settings: settings)
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
            manager = mgr
            vpnOnDemandEnabledOnDevice = mgr.isOnDemandEnabled
            SharedLogger.shared.logRaw(
                "VPN_ON_DEMAND_UPDATED",
                detail: "enabled=\(settings.vpnOnDemandEnabled) mode=\(settings.vpnOnDemandMode.rawValue)"
            )
        } catch {
            lastError = error.localizedDescription
            SharedLogger.shared.logRaw(
                "VPN_ON_DEMAND_FAILED",
                detail: "reason=\(error.localizedDescription)"
            )
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        let settings = SharedSettingsStore.shared.appSettings
        let loaded = try await VPNProfileCoordinator.loadManager()

        let mgr: NETunnelProviderManager
        if let loaded {
            mgr = loaded
        } else {
            mgr = VPNProfileCoordinator.createManager(settings: settings)
            SharedLogger.shared.log(.vpnManagerCreated)
        }

        let ready = try await VPNProfileCoordinator.ensureEnabled(manager: mgr, settings: settings)
        manager = ready
        vpnOnDemandEnabledOnDevice = ready.isOnDemandEnabled
        SharedLogger.shared.log(.vpnManagerSaved)
        return ready
    }

    /// Sends a string command to the running packet-tunnel extension. Returns the response
    /// payload if the extension is up and answered, or `nil` if the VPN is not active.
    @discardableResult
    func sendProviderMessage(_ command: String) async -> String? {
        if manager == nil {
            await refreshStatusFromSystem()
        }
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        guard let data = command.data(using: .utf8) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            do {
                try session.sendProviderMessage(data) { response in
                    if let response, let text = String(data: response, encoding: .utf8) {
                        cont.resume(returning: text)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            } catch {
                SharedLogger.shared.logRaw(
                    "VPN_PROVIDER_MSG_FAILED",
                    detail: "cmd=\(command) err=\(error.localizedDescription)"
                )
                cont.resume(returning: nil)
            }
        }
    }

    private func observeConnection(_ mgr: NETunnelProviderManager) {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: mgr.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFromManager()
            }
        }
        updateFromManager()
    }

    func syncStatusFromSharedStore() {
        refreshStatistics()
        if manager != nil {
            updateFromManager()
            return
        }

        let shared = SharedSettingsStore.shared.vpnStatus
        if status == .connecting || status == .disconnecting || shared == .connected || shared == .error {
            status = shared
            switch shared {
            case .connected:
                statusMessage = "Connected"
                if status != .connected { /* handled below */ }
            case .connecting: statusMessage = "Connecting…"
            case .disconnecting: statusMessage = "Disconnecting…"
            case .disconnected: statusMessage = "Disconnected"
            case .error: statusMessage = "Failed"
            }
        }
    }

    private func updateFromManager() {
        guard let connection = manager?.connection else {
            if optimisticDisconnect {
                applyDisconnectedState()
            } else {
                status = SharedSettingsStore.shared.vpnStatus
            }
            return
        }

        switch connection.status {
        case .disconnected, .invalid:
            optimisticDisconnect = false
            applyDisconnectedState()
            return
        case .disconnecting:
            if optimisticDisconnect {
                applyDisconnectedState()
                return
            }
            status = .disconnecting
            statusMessage = "Disconnecting…"
        case .connected:
            if optimisticDisconnect {
                connection.stopVPNTunnel()
                applyDisconnectedState()
                return
            }
            let previous = status
            status = .connected
            statusMessage = "Connected"
            if previous != .connected {
                Task { await self.handleConnectedSideEffects() }
            }
        case .connecting, .reasserting:
            if optimisticDisconnect {
                connection.stopVPNTunnel()
                applyDisconnectedState()
                return
            }
            status = .connecting
            statusMessage = "Connecting…"
        @unknown default:
            optimisticDisconnect = false
            applyDisconnectedState()
            return
        }
        SharedSettingsStore.shared.vpnStatus = status
        refreshStatistics()
    }
}
