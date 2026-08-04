import Foundation

@MainActor
enum FallbackChainController {
    struct Step: Equatable {
        let transport: FallbackStep
        let protocolSelection: AppSettings.ProtocolSelection
        let beast: Bool
        let timeoutSeconds: TimeInterval
        let conduitMode: AppSettings.ConduitMode?

        init(
            transport: FallbackStep,
            protocolSelection: AppSettings.ProtocolSelection,
            beast: Bool,
            timeoutSeconds: TimeInterval,
            conduitMode: AppSettings.ConduitMode? = nil
        ) {
            self.transport = transport
            self.protocolSelection = protocolSelection
            self.beast = beast
            self.timeoutSeconds = timeoutSeconds
            self.conduitMode = conduitMode
        }
    }

    static func steps(
        for selection: AppSettings.ProtocolSelection,
        settings: AppSettings? = nil
    ) -> [Step] {
        let effectiveSettings = settings ?? SharedSettingsStore.shared.appSettings
        guard let policySelection = AdaptiveTransportPolicy.selection(for: selection.rawValue) else {
            return []
        }
        let candidates = AdaptiveTransportPolicy.candidates(
            for: policySelection,
            includePublicConduit: SharedSettingsStore.shared.conduitConnectAllowed
        )
        return candidates.map { candidate in
            let timeout: TimeInterval
            switch candidate.transport {
            case .cdn:
                timeout = effectiveSettings.fallbackTimeoutCDN
            case .autoBeast:
                timeout = effectiveSettings.fallbackTimeoutAutoBeast
            case .direct:
                timeout = effectiveSettings.fallbackTimeoutDirect
            case .conduitPublic:
                timeout = max(
                    TimeInterval(effectiveSettings.conduitTimeoutSeconds),
                    effectiveSettings.fallbackTimeoutDirect
                )
            }
            return Step(
                transport: candidate.transport,
                protocolSelection: AppSettings.ProtocolSelection(rawValue: candidate.selection.rawValue) ?? .auto,
                beast: candidate.beast,
                timeoutSeconds: timeout,
                conduitMode: candidate.transport == .conduitPublic ? .publicOnly : nil
            )
        }
    }

    static func shouldUseChain(for selection: AppSettings.ProtocolSelection) -> Bool {
        let settings = SharedSettingsStore.shared.appSettings
        guard settings.smartFallbackChainEnabled else { return false }
        guard selection != .conduit else { return false }
        return !steps(for: selection, settings: settings).isEmpty
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
        let chainSteps = steps(for: original.protocolSelection, settings: original)
        guard !chainSteps.isEmpty else { return false }
        var state = FallbackChainState(isActive: true)
        ConnectionDiagnosticsStore.saveFallback(state)
        SharedLogger.shared.logRaw("FALLBACK_CHAIN_STARTED", detail: "steps=\(chainSteps.count)")
        defer {
            // A fallback trial is runtime state, not a replacement for the user's explicit choice.
            // Restore the original settings after every chain, while the active tunnel continues
            // using the trial already handed to the extension.
            SharedSettingsStore.shared.updateAppSettings(original, logKey: "fallback_restore_settings")
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
            if let conduitMode = step.conduitMode {
                trial.conduitMode = conduitMode
                trial.conduitFallbackToPublic = true
            }
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
                SharedLogger.shared.logRaw(
                    "FALLBACK_SUCCESS",
                    detail: "transport=\(step.transport.rawValue) protocol=\(protocolRaw)"
                )
                if runDiagnosticsOnSuccess {
                    await vpn.runPostConnectDiagnostics()
                }
                let networkSnapshot = await IOSNetworkProfileProvider.current()
                persistBestServerSelection(
                    transport: step.transport,
                    tunnelProtocol: protocolRaw,
                    networkSnapshot: networkSnapshot
                )
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

    private static func persistBestServerSelection(
        transport: FallbackStep,
        tunnelProtocol: String,
        networkSnapshot: NetworkPathSnapshot
    ) {
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
        ConnectionDiagnosticsStore.saveBestServer(selection, for: networkSnapshot)
        var detail = "transport=\(transport.rawValue) protocol=\(tunnelProtocol)"
        if latency >= 0 { detail += " latency_ms=\(latency)" }
        if !selection.cdnEdgeIP.isEmpty { detail += " fronting_ip=\(selection.cdnEdgeIP)" }
        if !selection.cdnSNI.isEmpty { detail += " fronting_sni=\(selection.cdnSNI)" }
        SharedLogger.shared.logRaw("BEST_SERVER_SELECTED", detail: detail)
        SharedLogger.shared.logRaw("BEST_SERVER_SAVED", detail: detail)
    }
}
