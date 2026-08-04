import Foundation

/// Reads connectivity result from the extension probe (main app cannot reach 127.0.0.1 Psiphon proxy).
enum InternetConnectivityTest {
    static func waitForExtensionResult(
        timeoutSeconds: TimeInterval = 90,
        budget: RecoveryBudget? = nil,
        clock: RecoveryClock = .monotonic,
        isCancellationRequested: () -> Bool = { false }
    ) async -> Bool {
        let (activeClock, deadline) = deadline(timeoutSeconds: timeoutSeconds, budget: budget, clock: clock)
        while !Task.isCancelled, !isCancellationRequested() {
            guard activeClock.now() < deadline else { break }
            guard SharedSettingsStore.shared.vpnStatus == .connected else { return false }
            if SharedSettingsStore.shared.lastInternetTestOK {
                SharedLogger.shared.log(.internetTestPassed, detail: "source=extension_probe")
                return true
            }
            guard await sleepUntilNextPoll(
                clock: activeClock,
                deadline: deadline,
                isCancellationRequested: isCancellationRequested
            ) else { return false }
        }
        if !Task.isCancelled, !isCancellationRequested() {
            SharedLogger.shared.log(.internetTestFailed, detail: "source=extension_probe_timeout")
        }
        return false
    }

    /// Waits until the tunnel is connected and the extension connectivity probe succeeds.
    /// The probe result is the end-to-end success criterion; a connected VPN alone is not.
    static func waitForConnectedTunnel(
        timeoutSeconds: TimeInterval,
        budget: RecoveryBudget? = nil,
        clock: RecoveryClock = .monotonic,
        isCancellationRequested: () -> Bool = { false }
    ) async -> Bool {
        let (activeClock, deadline) = deadline(timeoutSeconds: timeoutSeconds, budget: budget, clock: clock)
        while !Task.isCancelled, !isCancellationRequested() {
            guard activeClock.now() < deadline else { break }

            switch SharedSettingsStore.shared.vpnStatus {
            case .disconnected, .disconnecting, .error:
                return false
            case .connecting, .connected:
                break
            }

            if SharedSettingsStore.shared.vpnStatus == .connected,
               SharedSettingsStore.shared.lastInternetTestOK {
                SharedLogger.shared.log(.internetTestPassed, detail: "source=connected_tunnel_probe")
                return true
            }

            guard await sleepUntilNextPoll(
                clock: activeClock,
                deadline: deadline,
                isCancellationRequested: isCancellationRequested
            ) else { return false }
        }
        return false
    }

    private static func deadline(
        timeoutSeconds: TimeInterval,
        budget: RecoveryBudget?,
        clock: RecoveryClock
    ) -> (RecoveryClock, TimeInterval) {
        let activeClock = budget?.clock ?? clock
        let requestedDeadline = activeClock.now() + max(0, timeoutSeconds)
        return (activeClock, min(requestedDeadline, budget?.deadline ?? .greatestFiniteMagnitude))
    }

    private static func sleepUntilNextPoll(
        clock: RecoveryClock,
        deadline: TimeInterval,
        isCancellationRequested: () -> Bool
    ) async -> Bool {
        let remaining = deadline - clock.now()
        guard remaining > 0 else { return false }
        guard !Task.isCancelled, !isCancellationRequested() else { return false }
        do {
            try await clock.sleep(min(RecoveryTimingDefaults.connectivityPoll, remaining))
            return !Task.isCancelled && !isCancellationRequested()
        } catch {
            return false
        }
    }
}
