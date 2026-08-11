import Foundation

@MainActor
enum FallbackChainController {
    struct Step: Equatable {
        let attemptID: String
        let transport: FallbackStep
        let protocolSelection: AppSettings.ProtocolSelection
        let beast: Bool
        let timeoutSeconds: TimeInterval
        let minimumTimeoutSeconds: TimeInterval
        let conduitMode: AppSettings.ConduitMode?
        let cdnAttemptStrategy: AppSettings.CDNFrontingAttemptStrategy?

        init(
            attemptID: String? = nil,
            transport: FallbackStep,
            protocolSelection: AppSettings.ProtocolSelection,
            beast: Bool,
            timeoutSeconds: TimeInterval,
            minimumTimeoutSeconds: TimeInterval = RecoveryTimingDefaults.minimumAttemptBudget,
            conduitMode: AppSettings.ConduitMode? = nil,
            cdnAttemptStrategy: AppSettings.CDNFrontingAttemptStrategy? = nil
        ) {
            self.attemptID = attemptID ?? transport.rawValue
            self.transport = transport
            self.protocolSelection = protocolSelection
            self.beast = beast
            self.timeoutSeconds = timeoutSeconds
            self.minimumTimeoutSeconds = minimumTimeoutSeconds
            self.conduitMode = conduitMode
            self.cdnAttemptStrategy = cdnAttemptStrategy
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
        let standardSteps = candidates.map { candidate in
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

        guard selection == .cdnFronting,
              let first = standardSteps.first,
              first.transport == .cdn else {
            return standardSteps
        }

        // A fixed edge can complete TLS/SSH and still fail Psiphon's activation handshake, as
        // seen on restrictive networks. Rotate the route strategy automatically instead of
        // requiring the user to toggle Region to perturb candidate ordering.
        let dynamicTimeout = min(max(1, effectiveSettings.fallbackTimeoutCDN), 12)
        let staticTimeout = min(max(1, effectiveSettings.fallbackTimeoutCDN), 18)
        let cdnSteps = [
            Step(
                attemptID: "cdn_dynamic_tcp",
                transport: .cdn,
                protocolSelection: .cdnFronting,
                beast: true,
                timeoutSeconds: dynamicTimeout,
                minimumTimeoutSeconds: dynamicTimeout,
                cdnAttemptStrategy: .dynamicTCP
            ),
            Step(
                attemptID: "cdn_static_tcp",
                transport: .cdn,
                protocolSelection: .cdnFronting,
                beast: true,
                timeoutSeconds: staticTimeout,
                minimumTimeoutSeconds: staticTimeout,
                cdnAttemptStrategy: .staticTCP
            ),
            Step(
                attemptID: "cdn_static_all",
                transport: .cdn,
                protocolSelection: .cdnFronting,
                beast: true,
                timeoutSeconds: first.timeoutSeconds,
                minimumTimeoutSeconds: first.minimumTimeoutSeconds,
                cdnAttemptStrategy: .staticAll
            )
        ]
        return cdnSteps + Array(standardSteps.dropFirst())
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
        runDiagnosticsOnSuccess: Bool = true,
        budget: RecoveryBudget? = nil,
        sessionID: UUID? = nil
    ) async -> Bool {
        let original = baseSettings ?? SharedSettingsStore.shared.appSettings
        if !force, !shouldUseChain(for: original.protocolSelection) {
            return false
        }
        let chainSteps = steps(for: original.protocolSelection, settings: original)
        guard !chainSteps.isEmpty else { return false }

        let gate = RecoverySessionGate.shared
        let session: UUID
        let ownsSession: Bool
        if let sessionID {
            guard gate.owns(sessionID) else {
                SharedLogger.shared.logRaw("FALLBACK_CHAIN_SKIPPED", detail: "reason=overlapping_recovery")
                return false
            }
            session = sessionID
            ownsSession = false
        } else {
            guard let acquired = gate.acquire() else {
                SharedLogger.shared.logRaw("FALLBACK_CHAIN_SKIPPED", detail: "reason=overlapping_recovery")
                return false
            }
            session = acquired
            ownsSession = true
        }

        let networkSnapshot = await IOSNetworkProfileProvider.current()

        let runBudget = budget ?? RecoveryBudget()
        var state = FallbackChainState(isActive: true)
        ConnectionDiagnosticsStore.saveFallback(state)
        SharedLogger.shared.logRaw(
            "FALLBACK_CHAIN_STARTED",
            detail: "steps=\(chainSteps.count) budget=\(Int(runBudget.remaining))"
        )

        defer {
            // Commit the terminal snapshot exactly once. In particular, do
            // not reload the previous persisted value here: the exhausted,
            // cancelled, and successful fields are updated in this run.
            state.isActive = false
            ConnectionDiagnosticsStore.saveFallback(state)
            if ownsSession {
                gate.release(session)
            }
        }

        let attempts = chainSteps.map { step -> RecoveryAttemptRunner.Attempt in
            var trial = original
            trial.protocolSelection = step.protocolSelection
            trial.beastModeEnabled = step.beast
            trial.cdnFrontingAttemptStrategy = step.cdnAttemptStrategy
            if let conduitMode = step.conduitMode {
                trial.conduitMode = conduitMode
                trial.conduitFallbackToPublic = true
            }
            return RecoveryAttemptRunner.Attempt(
                id: step.attemptID,
                settings: trial,
                timeoutSeconds: step.timeoutSeconds,
                minimumTimeoutSeconds: step.minimumTimeoutSeconds
            )
        }

        let runner = RecoveryAttemptRunner(operations: .init(
            applyTrial: { trial in
                SharedSettingsStore.shared.applyRecoveryTrialSettings(trial)
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
            verify: { attempt, timeout, budget in
                let step = chainSteps.first(where: { $0.attemptID == attempt.id })
                let forceFailCDN = ProcessInfo.processInfo.arguments.contains("-UITestForceFallbackFailCDN")
                    && step?.transport == .cdn
                if forceFailCDN {
                    return false
                }
                return await InternetConnectivityTest.waitForConnectedTunnel(
                    timeoutSeconds: timeout,
                    budget: budget,
                    clock: budget.clock,
                    isCancellationRequested: {
                        gate.isCancellationRequested(for: session)
                    }
                )
            },
            persistWinner: { _ in
                // Record only path-scoped winner metadata. The winning overlay
                // remains active for this tunnel, while durable AppSettings is
                // never changed by a fallback trial.
                persistBestServerSelection(
                    transport: state.succeededStep ?? .direct,
                    tunnelProtocol: state.succeededProtocol,
                    networkSnapshot: networkSnapshot
                )
            },
            isCancellationRequested: {
                gate.isCancellationRequested(for: session)
            },
            attemptStarted: { index, attempt in
                guard let step = chainSteps.first(where: { $0.attemptID == attempt.id }) else { return }
                state.currentStep = step.transport
                ConnectionDiagnosticsStore.saveFallback(state)
                SharedLogger.shared.logRaw(
                    "FALLBACK_ATTEMPT",
                    detail: "transport=\(step.transport.rawValue) variant=\(step.attemptID) step=\(index)/\(chainSteps.count) remaining=\(Int(runBudget.remaining))"
                )
            },
            attemptFinished: { _, attempt, verified in
                guard let step = chainSteps.first(where: { $0.attemptID == attempt.id }) else { return }
                if verified {
                    state.succeededStep = step.transport
                    state.succeededProtocol = TunnelStatisticsStore.load().connectedTunnelProtocol
                    state.currentStep = step.transport
                    ConnectionDiagnosticsStore.saveFallback(state)
                    SharedLogger.shared.logRaw(
                        "FALLBACK_SUCCESS",
                        detail: "transport=\(step.transport.rawValue) variant=\(step.attemptID) protocol=\(state.succeededProtocol)"
                    )
                } else {
                    state.lastFailedStep = step.transport
                    state.lastFailureReason = vpn.lastError ?? "timeout_or_no_tunnel"
                    ConnectionDiagnosticsStore.saveFallback(state)
                    SharedLogger.shared.logRaw(
                        "FALLBACK_FAILED",
                        detail: "transport=\(step.transport.rawValue) variant=\(step.attemptID) reason=\(state.lastFailureReason)"
                    )
                }
            }
        ))

        let result = await runner.run(
            attempts: attempts,
            baseline: original,
            budget: runBudget,
            maxAttempts: chainSteps.count
        )

        switch result {
        case .succeeded:
            if runDiagnosticsOnSuccess {
                await vpn.runPostConnectDiagnostics(alreadyVerified: true)
            }
            return true
        case .cancelled:
            state.currentStep = nil
            state.lastFailureReason = "cancelled"
            SharedLogger.shared.logRaw("FALLBACK_CANCELLED", detail: "remaining=\(Int(runBudget.remaining))")
            return false
        case .exhausted:
            state.exhausted = true
            state.currentStep = nil
            SharedLogger.shared.logRaw("FALLBACK_EXHAUSTED", detail: "all_steps_failed")
            let tried = chainSteps.reduce(into: [String]()) { values, step in
                let transport = step.transport.rawValue
                if !values.contains(transport) { values.append(transport) }
            }.joined(separator: ", ")
            vpn.setFallbackFailureMessage("Could not connect. Tried \(tried). See Logs for FALLBACK_* lines.")
            return false
        }
    }

    static func persistBestServerSelection(
        transport: FallbackStep,
        tunnelProtocol: String,
        networkSnapshot: NetworkPathSnapshot
    ) {
        let quality = ConnectionDiagnosticsStore.loadQuality()
        let statistics = TunnelStatisticsStore.load()
        let latency = quality?.latencyMs ?? -1
        let egress = statistics.connectedServerRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = BestServerSelection(
            transport: transport.rawValue,
            tunnelProtocol: tunnelProtocol,
            egressRegion: egress.isEmpty ? nil : egress,
            latencyMs: latency,
            cdnEdgeIP: quality?.cdnEdgeIP ?? "",
            cdnSNI: quality?.cdnSNI ?? "",
            selectedAt: Date()
        )
        ConnectionDiagnosticsStore.saveBestServer(selection, for: networkSnapshot)
        var detail = "transport=\(transport.rawValue) protocol=\(tunnelProtocol)"
        if let egress = selection.egressRegion, !egress.isEmpty { detail += " egress=\(egress)" }
        if latency >= 0 { detail += " latency_ms=\(latency)" }
        if !selection.cdnEdgeIP.isEmpty { detail += " fronting_ip=\(selection.cdnEdgeIP)" }
        if !selection.cdnSNI.isEmpty { detail += " fronting_sni=\(selection.cdnSNI)" }
        SharedLogger.shared.logRaw("BEST_SERVER_SELECTED", detail: detail)
        SharedLogger.shared.logRaw("BEST_SERVER_SAVED", detail: detail)
    }
}
