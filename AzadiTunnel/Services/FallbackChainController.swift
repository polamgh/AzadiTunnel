import Foundation

@MainActor
enum FallbackChainController {
    struct Step: Equatable {
        let transport: FallbackStep
        let protocolSelection: AppSettings.ProtocolSelection
        let beast: Bool
        let timeoutSeconds: TimeInterval
    }

    static func steps(for selection: AppSettings.ProtocolSelection) -> [Step] {
        let settings = SharedSettingsStore.shared.appSettings
        let cdn = Step(transport: .cdn, protocolSelection: .cdnFronting, beast: true, timeoutSeconds: settings.fallbackTimeoutCDN)
        let auto = Step(transport: .autoBeast, protocolSelection: .auto, beast: true, timeoutSeconds: settings.fallbackTimeoutAutoBeast)
        let direct = Step(transport: .direct, protocolSelection: .direct, beast: false, timeoutSeconds: settings.fallbackTimeoutDirect)
        if settings.messagingAppsCompatibilityModeEnabled {
            switch selection {
            case .cdnFronting: return [cdn, auto, direct]
            case .auto: return [cdn, auto, direct]
            case .direct: return [cdn, direct]
            case .conduit: return []
            }
        }
        switch selection {
        case .cdnFronting: return [cdn, auto, direct]
        case .auto: return [cdn, direct]
        case .direct: return [direct]
        case .conduit: return []
        }
    }

    static func shouldUseChain(for selection: AppSettings.ProtocolSelection) -> Bool {
        let settings = SharedSettingsStore.shared.appSettings
        if settings.messagingAppsCompatibilityModeEnabled, selection != .conduit {
            return !steps(for: selection).isEmpty
        }
        guard settings.smartFallbackChainEnabled else { return false }
        guard selection != .conduit else { return false }
        return !steps(for: selection).isEmpty
    }

    static func connectWithChain(
        vpn: VPNController,
        baseSettings: AppSettings? = nil,
        force: Bool = false,
        runDiagnosticsOnSuccess: Bool = true
    ) async -> Bool {
        let original = baseSettings ?? SharedSettingsStore.shared.appSettings
        if !force, !shouldUseChain(for: original.protocolSelection) {
            return false
        }
        let chainSteps = steps(for: original.protocolSelection)
        guard !chainSteps.isEmpty else { return false }
        var state = FallbackChainState(isActive: true)
        var winningSettings: AppSettings?
        ConnectionDiagnosticsStore.saveFallback(state)
        SharedLogger.shared.logRaw("FALLBACK_CHAIN_STARTED", detail: "steps=\(chainSteps.count)")
        defer {
            if let winningSettings {
                SharedSettingsStore.shared.updateAppSettings(winningSettings, logKey: "best_server_saved")
            } else {
                SharedSettingsStore.shared.updateAppSettings(original, logKey: "fallback_restore_settings")
            }
            var done = ConnectionDiagnosticsStore.loadFallback()
            done.isActive = false
            ConnectionDiagnosticsStore.saveFallback(done)
        }

        for step in chainSteps {
            state.currentStep = step.transport
            ConnectionDiagnosticsStore.saveFallback(state)
            SharedLogger.shared.logRaw("FALLBACK_ATTEMPT", detail: "transport=\(step.transport.rawValue)")

            var trial = original
            trial.protocolSelection = step.protocolSelection
            trial.beastModeEnabled = step.beast
            SharedSettingsStore.shared.updateAppSettings(trial, logKey: "fallback_trial_\(step.transport.rawValue)")
            try? SharedSettingsStore.shared.recomposeEffectiveConfig()

            await vpn.disconnect()
            try? await TaskSleep.seconds(1)
            await vpn.connect(skipFallbackChain: true)

            let forceFailCDN = ProcessInfo.processInfo.arguments.contains("-UITestForceFallbackFailCDN")
                && step.transport == .cdn
            let success = forceFailCDN ? false : await waitForConnected(step.timeoutSeconds)
            if success {
                let protocolRaw = TunnelStatisticsStore.load().connectedTunnelProtocol
                state.succeededStep = step.transport
                state.succeededProtocol = protocolRaw
                state.currentStep = step.transport
                ConnectionDiagnosticsStore.saveFallback(state)
                winningSettings = trial
                SharedLogger.shared.logRaw(
                    "FALLBACK_SUCCESS",
                    detail: "transport=\(step.transport.rawValue) protocol=\(protocolRaw)"
                )
                if runDiagnosticsOnSuccess {
                    await vpn.runPostConnectDiagnostics()
                }
                persistBestServerSelection(transport: step.transport, tunnelProtocol: protocolRaw)
                return true
            }

            let reason = vpn.lastError ?? "timeout_or_no_tunnel"
            state.lastFailedStep = step.transport
            state.lastFailureReason = reason
            ConnectionDiagnosticsStore.saveFallback(state)
            SharedLogger.shared.logRaw(
                "FALLBACK_FAILED",
                detail: "transport=\(step.transport.rawValue) reason=\(reason)"
            )
        }

        state.exhausted = true
        state.isActive = false
        ConnectionDiagnosticsStore.saveFallback(state)
        SharedLogger.shared.logRaw("FALLBACK_EXHAUSTED", detail: "all_steps_failed")
        let tried = chainSteps.map(\.transport.rawValue).joined(separator: ", ")
        vpn.setFallbackFailureMessage("Could not connect. Tried \(tried). See Logs for FALLBACK_* lines.")
        return false
    }

    private static func waitForConnected(_ timeout: TimeInterval) async -> Bool {
        await InternetConnectivityTest.waitForConnectedTunnel(timeoutSeconds: timeout)
    }

    private static func persistBestServerSelection(transport: FallbackStep, tunnelProtocol: String) {
        let quality = ConnectionDiagnosticsStore.loadQuality()
        let latency = quality?.latencyMs ?? -1
        let selection = BestServerSelection(
            transport: transport.rawValue,
            tunnelProtocol: tunnelProtocol,
            latencyMs: latency,
            cdnEdgeIP: quality?.cdnEdgeIP ?? "",
            cdnSNI: quality?.cdnSNI ?? "",
            selectedAt: Date()
        )
        ConnectionDiagnosticsStore.saveBestServer(selection)
        var detail = "transport=\(transport.rawValue) protocol=\(tunnelProtocol)"
        if latency >= 0 { detail += " latency_ms=\(latency)" }
        if !selection.cdnEdgeIP.isEmpty { detail += " fronting_ip=\(selection.cdnEdgeIP)" }
        if !selection.cdnSNI.isEmpty { detail += " fronting_sni=\(selection.cdnSNI)" }
        SharedLogger.shared.logRaw("BEST_SERVER_SELECTED", detail: detail)
        SharedLogger.shared.logRaw("BEST_SERVER_SAVED", detail: detail)
    }
}
