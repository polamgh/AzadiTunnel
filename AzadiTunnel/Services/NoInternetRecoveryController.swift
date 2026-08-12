import Foundation

/// Bounded recovery when the tunnel is up but the connectivity probe fails.
@MainActor
enum NoInternetRecoveryController {
    struct AttemptPlan {
        let phase: SmartRecoveryPhase
        let detail: String
        let fallbackStep: FallbackStep?
        let attempt: RecoveryAttemptRunner.Attempt
    }

    static func recover(
        vpn: VPNController,
        budget: RecoveryBudget? = nil
    ) async -> Bool {
        let original = SharedSettingsStore.shared.appSettings
        guard original.autoRetryOnNoInternet else { return false }

        let networkSnapshot = await IOSNetworkProfileProvider.current()
        let best = ConnectionDiagnosticsStore.loadBestServer(for: networkSnapshot)
        let telemetryRegion = TunnelStatisticsStore.load().connectedServerRegion
        let plans = buildAttemptPlans(
            original: original,
            best: best,
            telemetryRegion: telemetryRegion
        )
        guard !plans.isEmpty else { return false }

        let gate = RecoverySessionGate.shared
        guard let session = gate.acquire() else {
            SharedLogger.shared.logRaw("SMART_RECOVERY_SKIPPED", detail: "reason=overlapping_recovery")
            return false
        }

        let runBudget = budget ?? RecoveryBudget()
        var state = SmartRecoveryState(
            isActive: true,
            totalAttempts: min(plans.count, RecoveryTimingDefaults.maxRecoveryAttempts)
        )
        ConnectionDiagnosticsStore.saveSmartRecovery(state)
        SharedLogger.shared.logRaw(
            "SMART_RECOVERY_STARTED",
            detail: "phases=\(state.totalAttempts) budget=\(Int(runBudget.remaining)) protocol_selection=\(original.protocolSelection.rawValue)"
        )

        defer {
            // Commit the terminal snapshot exactly once. Reloading here would
            // discard state.exhausted/currentPhase updates made by this run.
            state.isActive = false
            ConnectionDiagnosticsStore.saveSmartRecovery(state)
            gate.release(session)
        }

        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { trial in
                var next = trial
                next.egressRegion = SharedSettingsStore.shared.appSettings.egressRegion
                SharedSettingsStore.shared.applyRecoveryTrialSettings(next)
            },
            restoreBaseline: { _ in
                SharedSettingsStore.shared.clearRecoveryTrialSettings()
            },
            disconnect: {
                await vpn.disconnect(cancelRecovery: false)
            },
            connect: {
                await vpn.connect(skipFallbackChain: true, recoverySessionID: session)
            },
            verify: { _, timeout, budget in
                await InternetConnectivityTest.waitForConnectedTunnel(
                    timeoutSeconds: timeout,
                    budget: budget,
                    clock: budget.clock,
                    isCancellationRequested: {
                        gate.isCancellationRequested(for: session)
                    }
                )
            },
            persistWinner: { trial in
                // The candidate stays in the runtime overlay for the tunnel's
                // current session. Durable AppSettings is never changed by a
                // recovery trial; winner metadata is recorded separately.
                guard let plan = plans.first(where: { $0.attempt.settings == trial }),
                      let transport = plan.fallbackStep ?? fallbackStep(for: trial) else {
                    return
                }
                FallbackChainController.persistBestServerSelection(
                    transport: transport,
                    tunnelProtocol: TunnelStatisticsStore.load().connectedTunnelProtocol,
                    networkSnapshot: networkSnapshot
                )
            },
            isCancellationRequested: {
                gate.isCancellationRequested(for: session)
            },
            attemptStarted: { index, attempt in
                guard let plan = plans.first(where: { $0.attempt.id == attempt.id }) else { return }
                state.attemptIndex = index
                state.currentPhase = plan.phase
                state.lastFailureReason = ""
                ConnectionDiagnosticsStore.saveSmartRecovery(state)
                SharedLogger.shared.logRaw(
                    "SMART_RECOVERY_PHASE",
                    detail: "phase=\(plan.phase.rawValue) step=\(index)/\(state.totalAttempts) \(plan.detail) remaining=\(Int(runBudget.remaining))"
                )
            },
            attemptFinished: { _, attempt, verified in
                guard let plan = plans.first(where: { $0.attempt.id == attempt.id }) else { return }
                if verified {
                    state.succeededPhase = plan.phase
                    state.currentPhase = nil
                } else {
                    state.lastFailureReason = vpn.lastError ?? "timeout_or_no_tunnel"
                    SharedLogger.shared.logRaw(
                        "SMART_RECOVERY_PHASE_FAILED",
                        detail: "phase=\(plan.phase.rawValue) reason=\(state.lastFailureReason)"
                    )
                }
                ConnectionDiagnosticsStore.saveSmartRecovery(state)
            }
        ))

        let result = await runner.run(
            attempts: plans.map(\.attempt),
            baseline: original,
            budget: runBudget,
            maxAttempts: RecoveryTimingDefaults.maxRecoveryAttempts
        )

        switch result {
        case .succeeded:
            state.currentPhase = nil
            SharedLogger.shared.logRaw(
                "SMART_RECOVERY_SUCCESS",
                detail: "phase=\(state.succeededPhase?.rawValue ?? "unknown")"
            )
            await vpn.runPostConnectDiagnostics(alreadyVerified: true)
            return true
        case .cancelled:
            state.currentPhase = nil
            state.lastFailureReason = "cancelled"
            SharedLogger.shared.logRaw("SMART_RECOVERY_CANCELLED", detail: "remaining=\(Int(runBudget.remaining))")
            return false
        case .exhausted:
            state.exhausted = true
            state.currentPhase = nil
            SharedLogger.shared.logRaw("SMART_RECOVERY_FAILED", detail: "all_phases_exhausted")
            return false
        }
    }

    /// Egress candidates must come from a saved successful selection or the
    /// latest observed server region. There is intentionally no country-priority
    /// list: a region with no profile/telemetry is not a recovery trial.
    static func egressRegionsToTry(
        current: String,
        best: BestServerSelection?,
        telemetryRegion: String?
    ) -> [String] {
        let currentRegion = normalizedRegion(current)
        var candidates: [String] = []

        func append(_ raw: String?) {
            guard let normalized = normalizedRegion(raw),
                  normalized != currentRegion,
                  !candidates.contains(normalized) else { return }
            candidates.append(normalized)
        }

        append(best?.egressRegion)
        append(telemetryRegion)
        return Array(candidates.prefix(RecoveryTimingDefaults.maxEgressCandidates))
    }

    static func buildAttemptPlans(
        original: AppSettings,
        best: BestServerSelection?,
        telemetryRegion: String?
    ) -> [AttemptPlan] {
        var plans: [AttemptPlan] = []

        func append(
            phase: SmartRecoveryPhase,
            detail: String,
            settings: AppSettings,
            fallbackStep: FallbackStep? = nil,
            timeoutSeconds: TimeInterval? = nil,
            minimumTimeoutSeconds: TimeInterval = RecoveryTimingDefaults.minimumAttemptBudget
        ) {
            guard !plans.contains(where: { $0.attempt.settings == settings }) else { return }
            let id = "\(phase.rawValue)#\(plans.count)"
            plans.append(AttemptPlan(
                phase: phase,
                detail: detail,
                fallbackStep: fallbackStep,
                attempt: RecoveryAttemptRunner.Attempt(
                    id: id,
                    settings: settings,
                    timeoutSeconds: timeoutSeconds ?? settings.fallbackTimeoutDirect,
                    minimumTimeoutSeconds: minimumTimeoutSeconds
                )
            ))
        }

        if let best,
           let mutated = settingsApplyingBestServer(from: original, best: best),
           mutated != original {
            append(
                phase: .savedBest,
                detail: "transport=\(best.transport) egress=\(best.egressRegion ?? "auto")",
                settings: mutated
            )
        }

        if !original.egressRegion.isEmpty {
            var cleared = original
            cleared.egressRegion = ""
            append(phase: .clearEgress, detail: "egress=auto", settings: cleared)
        }

        for region in egressRegionsToTry(
            current: original.egressRegion,
            best: best,
            telemetryRegion: telemetryRegion
        ) {
            var regional = original
            regional.egressRegion = region
            append(phase: .egressRegion, detail: "egress=\(region)", settings: regional)
        }

        if original.protocolSelection != .conduit {
            for step in FallbackChainController.steps(for: original.protocolSelection, settings: original) {
                var trial = original
                trial.protocolSelection = step.protocolSelection
                trial.beastModeEnabled = step.beast
                trial.cdnFrontingAttemptStrategy = step.cdnAttemptStrategy
                if let conduitMode = step.conduitMode {
                    trial.conduitMode = conduitMode
                    trial.conduitFallbackToPublic = true
                }
                append(
                    phase: .transportChain,
                    detail: "transport=\(step.transport.rawValue)",
                    settings: trial,
                    fallbackStep: step.transport,
                    timeoutSeconds: step.timeoutSeconds,
                    minimumTimeoutSeconds: step.minimumTimeoutSeconds
                )
            }

            if !original.beastModeEnabled || original.protocolSelection != .auto {
                var beast = original
                beast.protocolSelection = .auto
                beast.beastModeEnabled = true
                append(phase: .beastAuto, detail: "protocol=auto beast=true", settings: beast)
            }

            var direct = original
            direct.protocolSelection = .direct
            direct.beastModeEnabled = false
            append(phase: .directReconnect, detail: "protocol=direct", settings: direct)
        } else {
            if original.conduitMode != .publicOnly {
                var publicConduit = original
                publicConduit.conduitMode = .publicOnly
                publicConduit.conduitFallbackToPublic = true
                append(
                    phase: .conduitPublic,
                    detail: "conduit=public",
                    settings: publicConduit
                )
            }
            if original.rejectCensoredCountryProxies {
                var uncensored = original
                uncensored.rejectCensoredCountryProxies = false
                append(
                    phase: .conduitUncensor,
                    detail: "reject_censored=false",
                    settings: uncensored
                )
            }
        }

        return plans
    }

    private static func normalizedRegion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 2,
              normalized.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return normalized
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
        case FallbackStep.conduitPublic.rawValue:
            trial.protocolSelection = .conduit
            trial.conduitMode = .publicOnly
            trial.conduitFallbackToPublic = true
            trial.beastModeEnabled = false
        default:
            return nil
        }
        if let egress = normalizedRegion(best.egressRegion) {
            trial.egressRegion = egress
        }
        return trial == base ? nil : trial
    }

    private static func fallbackStep(for settings: AppSettings) -> FallbackStep? {
        switch settings.protocolSelection {
        case .cdnFronting:
            return .cdn
        case .auto where settings.beastModeEnabled:
            return .autoBeast
        case .direct:
            return .direct
        case .auto, .conduit:
            return nil
        }
    }
}
