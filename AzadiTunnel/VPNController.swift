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
    @Published var showProxyOnlyNoWiFiPrompt = false

    private var manager: NETunnelProviderManager?
    private let providerBundleID = "com.polamgh.ali.AzadiTunnel.PacketTunnel"
    private var reconnectTask: Task<Void, Never>?
    private var recoveryTask: Task<Bool, Never>?
    private var connectionStatusObserver: NSObjectProtocol?
    /// Non-nil from the moment a new attempt token is published until iOS
    /// acknowledges the start with connecting/reasserting/connected.
    private var pendingStartAttemptID: String?
    private var transientDisconnectLoggedForAttemptID: String?
    /// User tapped Disconnect — keep UI on Disconnected while iOS tears down the tunnel.
    private var optimisticDisconnect = false
    /// Skip haptics until the first system status sync (avoids feedback on cold launch).
    private var statusHapticsEnabled = false

    init() {
        Task { await refreshStatusFromSystem() }
    }

    deinit {
        if let connectionStatusObserver {
            NotificationCenter.default.removeObserver(connectionStatusObserver)
        }
    }

    func refreshStatusFromSystem() async {
        defer { statusHapticsEnabled = true }
        do {
            manager = try await VPNProfileCoordinator.loadManager()
            if let manager {
                vpnOnDemandEnabledOnDevice = manager.isOnDemandEnabled
                observeConnection(manager, synchronizeImmediately: false)
            }
            updateFromManager()
        } catch {
            lastError = error.localizedDescription
            banner = .vpnPermission
        }
    }

    private func playVPNStatusHapticIfNeeded(from previous: VPNStatusDisplay, to new: VPNStatusDisplay) {
        guard statusHapticsEnabled, previous != new else { return }
        switch new {
        case .connected:
            HapticFeedback.vpnConnected()
        case .disconnected:
            switch previous {
            case .connected, .connecting, .disconnecting:
                HapticFeedback.vpnDisconnected()
            case .disconnected, .error:
                break
            }
        case .connecting, .disconnecting, .error:
            break
        }
    }

    /// Refresh NE status before Connect/Disconnect so UI matches iOS when the tunnel died externally.
    func prepareForUserToggle() async {
        await refreshStatusFromSystem()
    }

    /// Gives immediate visual acknowledgement for a Connect tap. The actual
    /// NetworkExtension state remains authoritative and is published separately.
    func beginUserConnectFeedback() {
        guard status == .disconnected || status == .error else { return }
        lastError = nil
        banner = .none
        presentConnectingState()
        SharedLogger.shared.logRaw("VPN_CONNECT_UI_FEEDBACK", detail: "source=power_button")
    }

    private func presentConnectingState() {
        status = .connecting
        statusMessage = "Connecting…"
    }

    /// Keep the dashboard visibly busy while the recovery runner intentionally
    /// stops one serial candidate before starting the next one.
    private var shouldPresentConnectingDuringRecovery: Bool {
        let gate = RecoverySessionGate.shared
        return gate.activeSessionID != nil && !gate.cancellationRequested
    }

    func refreshStatistics() {
        statistics = TunnelStatisticsStore.load()
    }

    func connect(
        skipFallbackChain: Bool = false,
        recoverySessionID: UUID? = nil
    ) async {
        let gate = RecoverySessionGate.shared
        if let recoverySessionID {
            guard gate.owns(recoverySessionID) else {
                SharedLogger.shared.logRaw("CONNECT_BLOCKED_RECOVERY", detail: "reason=invalid_session")
                return
            }
            guard !gate.isCancellationRequested(for: recoverySessionID) else {
                SharedLogger.shared.logRaw("CONNECT_BLOCKED_RECOVERY", detail: "reason=session_cancelled")
                return
            }
        } else if gate.activeSessionID != nil {
            SharedLogger.shared.logRaw("CONNECT_BLOCKED_RECOVERY", detail: "reason=overlapping_recovery")
            return
        }

        if recoverySessionID == nil {
            SharedSettingsStore.shared.discardExpiredRecoveryTrialSettings()
            if SharedSettingsStore.shared.recoveryTrialSettings != nil {
                // A verified recovery winner is session-scoped. A fresh user
                // connect starts from the durable preference, never from a
                // candidate left by an earlier process.
                SharedSettingsStore.shared.clearRecoveryTrialSettings()
            }
        }

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

        if SharedSettingsStore.shared.effectiveAppSettings.protocolSelection == .conduit,
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

        if ProxyOnlyWiFiRequirement.isBlocked {
            SharedLogger.shared.log(.proxyOnlyBlockedNoWifi, detail: "source=vpn_controller")
            SharedLogger.shared.log(.proxyOnlyDisableOffered)
            showProxyOnlyNoWiFiPrompt = true
            applyDisconnectedState()
            return
        }

        presentConnectingState()

        let selection = SharedSettingsStore.shared.appSettings.protocolSelection
        if !skipFallbackChain, FallbackChainController.shouldUseChain(for: selection) {
            let ok = await FallbackChainController.connectWithChain(vpn: self)
            if !ok, lastError == nil {
                setFallbackFailureMessage("Could not connect. See Logs for FALLBACK_* lines.")
            }
            return
        }

        // Ensure the Iran-bypass cache is populated before the extension reads it at startTunnel.
        // Both steps are throttled, so this is usually instant after the first connect.
        await ensureBypassCacheReady()
        await startTunnel()
    }

    /// Refresh the Iran CIDR list + resolve bypass domains into App Group cache (no-op if disabled).
    private func ensureBypassCacheReady() async {
        let settings = SharedSettingsStore.shared.effectiveAppSettings
        guard settings.bypassIranIPsEnabled else { return }
        _ = await IranBypassListService.refresh(force: false)
        let domains = BypassRoutes.tokenize(settings.bypassDomains)
        if !domains.isEmpty {
            _ = await BypassDomainResolver.resolveAndCache(domains: domains)
        }
    }

    func cancelProxyOnlyNoWiFiConnect() {
        SharedLogger.shared.log(.proxyOnlyStartCancelledNoWifi)
        showProxyOnlyNoWiFiPrompt = false
    }

    func disableProxyOnlyModeAndConnect() async {
        SharedLogger.shared.log(.proxyOnlyDisabledByUser)
        showProxyOnlyNoWiFiPrompt = false
        var settings = SharedSettingsStore.shared.appSettings
        settings.proxyOnlyModeEnabled = false
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: "proxy_only_disabled_no_wifi")
        SharedLogger.shared.log(.proxyOnlyModeDisabled)
        await connect()
    }

    private func startTunnel() async {
        let attemptID = UUID().uuidString
        pendingStartAttemptID = attemptID
        transientDisconnectLoggedForAttemptID = nil
        SharedSettingsStore.shared.beginVPNAttempt(attemptID)
        SharedLogger.shared.log(.vpnConnectRequested)
        status = .connecting
        statusMessage = "Connecting…"
        if SharedSettingsStore.shared.effectiveAppSettings.protocolSelection == .conduit {
            TunnelStatisticsStore.clearConduitStatus()
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: false)
            refreshStatistics()
        }

        do {
            let mgr = try await ensureManager()
            switch mgr.connection.status {
            case .connected, .connecting, .reasserting:
                SharedLogger.shared.logRaw(
                    "VPN_START_RESET_STALE",
                    detail: "ne_status=\(mgr.connection.status.rawValue)"
                )
                mgr.connection.stopVPNTunnel()
                guard await waitForDisconnected(on: mgr, attemptID: attemptID) else {
                    throw VPNLifecycleError.stopDidNotSettle
                }
            case .disconnecting:
                guard await waitForDisconnected(on: mgr, attemptID: attemptID) else {
                    throw VPNLifecycleError.stopDidNotSettle
                }
            case .disconnected, .invalid:
                break
            @unknown default:
                throw VPNLifecycleError.stopDidNotSettle
            }

            guard pendingStartAttemptID == attemptID else { return }
            optimisticDisconnect = false
            observeConnection(mgr, synchronizeImmediately: false)
            SharedLogger.shared.log(.vpnStartRequested)
            let startedManager = try await startVPNTunnel(on: mgr, attemptID: attemptID)
            manager = startedManager
            if startedManager !== mgr {
                observeConnection(startedManager, synchronizeImmediately: false)
            }

            let acknowledged = await waitForStartAcknowledgement(
                on: startedManager,
                attemptID: attemptID
            )
            guard pendingStartAttemptID == attemptID || acknowledged else { return }
            guard acknowledged else {
                throw VPNLifecycleError.startNotAcknowledged
            }
            pendingStartAttemptID = nil
            transientDisconnectLoggedForAttemptID = nil
            updateFromManager()
        } catch {
            guard pendingStartAttemptID == attemptID else { return }
            pendingStartAttemptID = nil
            transientDisconnectLoggedForAttemptID = nil
            SharedSettingsStore.shared.endVPNAttempt(ifMatching: attemptID)
            handleConnectFailure(error)
        }
    }

    private func startVPNTunnel(
        on mgr: NETunnelProviderManager,
        attemptID: String
    ) async throws -> NETunnelProviderManager {
        let options: [String: NSObject] = [
            AppGroupConstants.vpnAttemptOptionKey: attemptID as NSString
        ]
        do {
            try mgr.connection.startVPNTunnel(options: options)
            return mgr
        } catch {
            guard VPNProfileCoordinator.isConfigurationDisabledError(error) else { throw error }
            SharedLogger.shared.logRaw("VPN_CONFIG_DISABLED", detail: "action=reenable_and_retry")
            let settings = SharedSettingsStore.shared.appSettings
            let repaired = try await VPNProfileCoordinator.ensureEnabled(manager: mgr, settings: settings)
            manager = repaired
            try repaired.connection.startVPNTunnel(options: options)
            return repaired
        }
    }

    private func waitForDisconnected(
        on mgr: NETunnelProviderManager,
        attemptID: String
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + RecoveryTimingDefaults.networkExtensionStopTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard pendingStartAttemptID == attemptID, !Task.isCancelled else { return false }
            switch mgr.connection.status {
            case .disconnected, .invalid:
                return true
            case .connected, .connecting, .reasserting, .disconnecting:
                break
            @unknown default:
                break
            }
            try? await TaskSleep.milliseconds(100)
        }
        SharedLogger.shared.logRaw(
            "VPN_STOP_SETTLE_TIMEOUT",
            detail: "ne_status=\(mgr.connection.status.rawValue) timeout_s=\(Int(RecoveryTimingDefaults.networkExtensionStopTimeout))"
        )
        return false
    }

    private func waitForStartAcknowledgement(
        on mgr: NETunnelProviderManager,
        attemptID: String
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + RecoveryTimingDefaults.networkExtensionStartAcknowledgement
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard pendingStartAttemptID == attemptID, !Task.isCancelled else {
                return mgr.connection.status == .connecting
                    || mgr.connection.status == .reasserting
                    || mgr.connection.status == .connected
            }
            switch mgr.connection.status {
            case .connecting, .reasserting, .connected:
                SharedLogger.shared.logRaw(
                    "VPN_START_ACKNOWLEDGED",
                    detail: "id=\(String(attemptID.prefix(8))) ne_status=\(mgr.connection.status.rawValue)"
                )
                return true
            case .disconnected, .invalid, .disconnecting:
                break
            @unknown default:
                break
            }
            try? await TaskSleep.milliseconds(100)
        }
        SharedLogger.shared.logRaw(
            "VPN_START_ACK_TIMEOUT",
            detail: "id=\(String(attemptID.prefix(8))) ne_status=\(mgr.connection.status.rawValue) timeout_s=\(Int(RecoveryTimingDefaults.networkExtensionStartAcknowledgement))"
        )
        return false
    }

    private func handleConnectFailure(_ error: Error) {
        SharedSettingsStore.shared.endVPNAttempt()
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

    func runPostConnectDiagnostics(alreadyVerified: Bool = false) async {
        await handleConnectedSideEffects(alreadyVerified: alreadyVerified)
    }

    func setFallbackFailureMessage(_ message: String) {
        pendingStartAttemptID = nil
        transientDisconnectLoggedForAttemptID = nil
        SharedSettingsStore.shared.endVPNAttempt()
        lastError = message
        status = .error
        statusMessage = "Failed"
        banner = .psiphonFailed
        SharedSettingsStore.shared.vpnStatus = .error
    }

    func disconnect(cancelRecovery: Bool = true) async {
        reconnectTask?.cancel()
        pendingStartAttemptID = nil
        transientDisconnectLoggedForAttemptID = nil
        if cancelRecovery {
            RecoverySessionGate.shared.cancelActiveSession()
            recoveryTask?.cancel()
            recoveryTask = nil
        }
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
        if cancelRecovery {
            // Stop has been requested above. Now discard the runtime winner and
            // recompose the durable user settings for the next tunnel session.
            SharedSettingsStore.shared.clearRecoveryTrialSettings()
        }
        // Recovery's internal stop is only a NetworkExtension state change;
        // it must not rewrite the durable baseline while a trial is active.
        applyDisconnectedState(preserveRecoveryBaseline: !cancelRecovery)
    }

    private func applyDisconnectedState(preserveRecoveryBaseline: Bool = false) {
        let previous = status
        TunnelStatisticsStore.markDisconnected()
        TunnelStatisticsStore.clearPublicIP()
        var appSettings = SharedSettingsStore.shared.appSettings
        if !preserveRecoveryBaseline, appSettings.conduitFallbackToPublic {
            appSettings.conduitFallbackToPublic = false
            SharedSettingsStore.shared.updateAppSettings(appSettings, logKey: "conduit_fallback_reset")
        }
        SharedSettingsStore.shared.vpnStatus = .disconnected
        SharedSettingsStore.shared.endVPNAttempt()
        banner = .none
        if shouldPresentConnectingDuringRecovery {
            presentConnectingState()
            refreshStatistics()
            return
        }
        status = .disconnected
        statusMessage = "Disconnected"
        refreshStatistics()
        playVPNStatusHapticIfNeeded(from: previous, to: .disconnected)
    }

    func handleConnectedSideEffects(alreadyVerified: Bool = false) async {
        refreshStatistics()
        let proxyOnly = SharedSettingsStore.shared.effectiveAppSettings.proxyOnlyModeEnabled
        if alreadyVerified {
            guard SharedSettingsStore.shared.vpnStatus == .connected else { return }
            guard SharedSettingsStore.shared.lastInternetTestOK else {
                SharedLogger.shared.logRaw("POST_CONNECT_DIAGNOSTICS_SKIPPED", detail: "reason=probe_state_changed")
                return
            }
        }
        let ok: Bool
        if alreadyVerified {
            ok = true
        } else {
            ok = await InternetConnectivityTest.waitForExtensionResult()
        }
        if ok {
            banner = .none
            if !proxyOnly {
                await PublicIPFetcher.fetchIfNeeded()
                refreshStatistics()
                _ = await LeakTestService.runAfterConnect()
                _ = await ConnectionQualityService.runAfterConnect()
            } else {
                SharedLogger.shared.log(.proxyOnlyWarningNotFullVPN)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await PublicIPFetcher.fetchIfNeeded()
                refreshStatistics()
            }
        } else {
            banner = .internetTestFailed
            lastError = proxyOnly
                ? "Proxy is up but connectivity check failed. See Logs for INTERNET_TEST_*."
                : "VPN is up but internet check failed. See Logs for INTERNET_TEST_* and PSIPHON_PROXY_MODE."

            let settings = SharedSettingsStore.shared.appSettings
            if settings.autoRetryOnNoInternet {
                guard recoveryTask == nil else {
                    SharedLogger.shared.logRaw("SMART_RECOVERY_SKIPPED", detail: "reason=duplicate_side_effects_callback")
                    return
                }
                let task = Task { @MainActor [weak self] in
                    guard let self else { return false }
                    return await NoInternetRecoveryController.recover(vpn: self)
                }
                recoveryTask = task
                _ = await task.value
                recoveryTask = nil
                refreshStatistics()
                // Recovery owns the only reconnect loop. Do not start the
                // background auto-reconnect loop after it exhausts/cancels.
                return
            }
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

    private func observeConnection(
        _ mgr: NETunnelProviderManager,
        synchronizeImmediately: Bool = true
    ) {
        if let connectionStatusObserver {
            NotificationCenter.default.removeObserver(connectionStatusObserver)
        }
        connectionStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: mgr.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFromManager()
            }
        }
        if synchronizeImmediately {
            updateFromManager()
        }
    }

    func syncStatusFromSharedStore() {
        refreshStatistics()
        if manager != nil {
            updateFromManager()
            return
        }

        let shared = SharedSettingsStore.shared.vpnStatus
        if status == .connecting || status == .disconnecting || shared == .connected || shared == .error {
            let previous = status
            status = shared
            switch shared {
            case .connected:
                statusMessage = "Connected"
            case .connecting: statusMessage = "Connecting…"
            case .disconnecting: statusMessage = "Disconnecting…"
            case .disconnected: statusMessage = "Disconnected"
            case .error: statusMessage = "Failed"
            }
            playVPNStatusHapticIfNeeded(from: previous, to: shared)
        }
    }

    private func updateFromManager() {
        guard let connection = manager?.connection else {
            if pendingStartAttemptID != nil {
                return
            }
            if shouldPresentConnectingDuringRecovery {
                presentConnectingState()
                return
            }
            if optimisticDisconnect {
                applyDisconnectedState()
            } else {
                let previous = status
                let shared = SharedSettingsStore.shared.vpnStatus
                status = shared
                playVPNStatusHapticIfNeeded(from: previous, to: shared)
            }
            return
        }

        // NetworkExtension may briefly publish the previous session's state
        // after a new start request. Keep this attempt at `connecting` until
        // iOS has acknowledged startVPNTunnel with an active NE status.
        if let attemptID = pendingStartAttemptID {
            if (connection.status == .disconnected || connection.status == .invalid),
               transientDisconnectLoggedForAttemptID != attemptID {
                transientDisconnectLoggedForAttemptID = attemptID
                SharedLogger.shared.logRaw(
                    "VPN_START_TRANSIENT_DISCONNECTED",
                    detail: "id=\(String(attemptID.prefix(8))) ne_status=\(connection.status.rawValue) action=wait_for_start_ack"
                )
            }
            status = .connecting
            statusMessage = "Connecting…"
            _ = SharedSettingsStore.shared.publishVPNStatus(.connecting, attemptID: attemptID)
            refreshStatistics()
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
            statusMessage = SharedSettingsStore.shared.effectiveAppSettings.proxyOnlyModeEnabled
                ? L10n.t(.proxyOnlyStatusConnected)
                : "Connected"
            if previous != .connected {
                playVPNStatusHapticIfNeeded(from: previous, to: .connected)
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

private enum VPNLifecycleError: LocalizedError {
    case stopDidNotSettle
    case startNotAcknowledged

    var errorDescription: String? {
        switch self {
        case .stopDidNotSettle:
            return "The previous VPN session did not finish stopping. Please try again."
        case .startNotAcknowledged:
            return "iOS did not acknowledge the VPN start request. Please try again."
        }
    }
}
