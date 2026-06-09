import Foundation

/// Multi-phase recovery when the tunnel is up but the connectivity probe fails.
@MainActor
enum NoInternetRecoveryController {
    private struct PhasePlan {
        let phase: SmartRecoveryPhase
        let detail: String
        let mutate: (inout AppSettings) -> Void
        let useChain: Bool
        let reconnects: Int
    }

    private static let egressPriority = ["GB", "DE", "NL", "US", "FR", "CA", "SG", "JP", "SE", "AU"]
    private static let maxEgressRotations = 6

    static func recover(vpn: VPNController) async -> Bool {
        let settings = SharedSettingsStore.shared.appSettings
        guard settings.autoRetryOnNoInternet else { return false }

        let original = settings
        let tunnelProtocol = TunnelStatisticsStore.load().connectedTunnelProtocol
        let plans = buildPlans(original: original)
        guard !plans.isEmpty else { return false }

        var state = SmartRecoveryState(isActive: true, totalAttempts: plans.count)
        ConnectionDiagnosticsStore.saveSmartRecovery(state)
        SharedLogger.shared.logRaw(
            "SMART_RECOVERY_STARTED",
            detail: "phases=\(plans.count) protocol_selection=\(original.protocolSelection.rawValue) tunnel=\(tunnelProtocol)"
        )

        var winningSettings: AppSettings?
        defer {
            state.isActive = false
            if winningSettings == nil {
                state.exhausted = true
            }
            ConnectionDiagnosticsStore.saveSmartRecovery(state)
            if let winningSettings {
                SharedSettingsStore.shared.updateAppSettings(winningSettings, logKey: "smart_recovery_saved")
                SharedLogger.shared.logRaw(
                    "SMART_RECOVERY_SUCCESS",
                    detail: "phase=\(state.succeededPhase?.rawValue ?? "unknown")"
                )
            } else {
                SharedSettingsStore.shared.updateAppSettings(original, logKey: "smart_recovery_restore")
                SharedLogger.shared.logRaw("SMART_RECOVERY_FAILED", detail: "all_phases_exhausted")
            }
        }

        await vpn.disconnect()
        try? await TaskSleep.seconds(1)

        for (index, plan) in plans.enumerated() {
            state.attemptIndex = index + 1
            state.currentPhase = plan.phase
            state.lastFailureReason = ""
            ConnectionDiagnosticsStore.saveSmartRecovery(state)

            SharedLogger.shared.logRaw(
                "SMART_RECOVERY_PHASE",
                detail: "phase=\(plan.phase.rawValue) step=\(index + 1)/\(plans.count) \(plan.detail)"
            )

            if let won = await runPhase(plan: plan, vpn: vpn, baseline: original) {
                winningSettings = won
                state.succeededPhase = plan.phase
                state.currentPhase = nil
                await vpn.runPostConnectDiagnostics()
                if SharedSettingsStore.shared.lastInternetTestOK {
                    return true
                }
                winningSettings = nil
                state.lastFailureReason = "internet_probe_failed_after_phase"
                await vpn.disconnect()
                try? await TaskSleep.seconds(1)
                continue
            }

            state.lastFailureReason = vpn.lastError ?? "phase_failed"
            SharedLogger.shared.logRaw(
                "SMART_RECOVERY_PHASE_FAILED",
                detail: "phase=\(plan.phase.rawValue) reason=\(state.lastFailureReason)"
            )
            await vpn.disconnect()
            try? await TaskSleep.seconds(1)
        }

        return false
    }

    private static func buildPlans(original: AppSettings) -> [PhasePlan] {
        var plans: [PhasePlan] = []

        if let best = ConnectionDiagnosticsStore.loadBestServer(),
           let mutated = settingsApplyingBestServer(from: original, best: best),
           mutated != original {
            plans.append(PhasePlan(
                phase: .savedBest,
                detail: "transport=\(best.transport)",
                mutate: { settings in
                    if let applied = settingsApplyingBestServer(from: original, best: best) {
                        settings = applied
                    }
                },
                useChain: false,
                reconnects: 1
            ))
        }

        if original.protocolSelection != .conduit {
            plans.append(PhasePlan(
                phase: .transportChain,
                detail: "forced_fallback_chain",
                mutate: { _ in },
                useChain: true,
                reconnects: 0
            ))
        }

        if !original.egressRegion.isEmpty {
            plans.append(PhasePlan(
                phase: .clearEgress,
                detail: "egress=auto",
                mutate: { $0.egressRegion = "" },
                useChain: original.protocolSelection != .conduit,
                reconnects: original.protocolSelection == .conduit ? 2 : 0
            ))
        }

        for region in egressRegionsToTry(current: original.egressRegion) {
            plans.append(PhasePlan(
                phase: .egressRegion,
                detail: "egress=\(region)",
                mutate: { $0.egressRegion = region },
                useChain: original.protocolSelection != .conduit,
                reconnects: original.protocolSelection == .conduit ? 2 : 0
            ))
        }

        if original.protocolSelection != .conduit,
           !original.beastModeEnabled || original.protocolSelection != .auto {
            plans.append(PhasePlan(
                phase: .beastAuto,
                detail: "protocol=auto beast=true",
                mutate: {
                    $0.protocolSelection = .auto
                    $0.beastModeEnabled = true
                },
                useChain: true,
                reconnects: 0
            ))
        }

        if original.protocolSelection != .conduit,
           !original.messagingAppsCompatibilityModeEnabled {
            plans.append(PhasePlan(
                phase: .messagingCompat,
                detail: "messaging_compat=true",
                mutate: { $0.messagingAppsCompatibilityModeEnabled = true },
                useChain: true,
                reconnects: 0
            ))
        }

        if original.secureDNSMode != .off {
            plans.append(PhasePlan(
                phase: .secureDnsOff,
                detail: "secure_dns=off",
                mutate: {
                    $0.secureDNSMode = .off
                    $0.blockCleartextDNS = false
                },
                useChain: original.protocolSelection != .conduit,
                reconnects: original.protocolSelection == .conduit ? 2 : 0
            ))
        }

        if original.protocolSelection == .conduit {
            if original.conduitMode != .publicOnly {
                plans.append(PhasePlan(
                    phase: .conduitPublic,
                    detail: "conduit=public",
                    mutate: {
                        $0.conduitMode = .publicOnly
                        $0.conduitFallbackToPublic = true
                    },
                    useChain: false,
                    reconnects: 2
                ))
            }
            if original.rejectCensoredCountryProxies {
                plans.append(PhasePlan(
                    phase: .conduitUncensor,
                    detail: "reject_censored=false",
                    mutate: { $0.rejectCensoredCountryProxies = false },
                    useChain: false,
                    reconnects: 2
                ))
            }
        }

        if original.protocolSelection != .conduit {
            plans.append(PhasePlan(
                phase: .directReconnect,
                detail: "protocol=direct",
                mutate: {
                    $0.protocolSelection = .direct
                    $0.beastModeEnabled = false
                },
                useChain: false,
                reconnects: 2
            ))
        }

        return plans
    }

    private static func egressRegionsToTry(current: String) -> [String] {
        let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return egressPriority
            .filter { $0 != normalized }
            .prefix(maxEgressRotations)
            .map { $0 }
    }

    private static func settingsApplyingBestServer(
        from base: AppSettings,
        best: BestServerSelection
    ) -> AppSettings? {
        var trial = base
        switch best.transport {
        case FallbackStep.cdn.rawValue:
            trial.protocolSelection = .cdnFronting
            trial.beastModeEnabled = true
        case FallbackStep.autoBeast.rawValue:
            trial.protocolSelection = .auto
            trial.beastModeEnabled = true
        case FallbackStep.direct.rawValue:
            trial.protocolSelection = .direct
            trial.beastModeEnabled = false
        default:
            return nil
        }
        return trial == base ? nil : trial
    }

    private static func runPhase(
        plan: PhasePlan,
        vpn: VPNController,
        baseline: AppSettings
    ) async -> AppSettings? {
        var trial = baseline
        plan.mutate(&trial)
        SharedSettingsStore.shared.updateAppSettings(trial, logKey: "smart_recovery_\(plan.phase.rawValue)")
        try? SharedSettingsStore.shared.recomposeEffectiveConfig()

        if plan.useChain {
            let ok = await FallbackChainController.connectWithChain(
                vpn: vpn,
                baseSettings: trial,
                force: true,
                runDiagnosticsOnSuccess: false
            )
            return ok ? SharedSettingsStore.shared.appSettings : nil
        }

        let timeout = max(trial.fallbackTimeoutDirect, 60)
        for attempt in 1...max(plan.reconnects, 1) {
            SharedLogger.shared.logRaw(
                "SMART_RECOVERY_RECONNECT",
                detail: "phase=\(plan.phase.rawValue) attempt=\(attempt)"
            )
            SharedSettingsStore.shared.lastInternetTestOK = false
            await vpn.connect(skipFallbackChain: true)
            if await InternetConnectivityTest.waitForConnectedTunnel(timeoutSeconds: timeout) {
                return SharedSettingsStore.shared.appSettings
            }
            await vpn.disconnect()
            try? await TaskSleep.seconds(1)
        }
        return nil
    }
}
