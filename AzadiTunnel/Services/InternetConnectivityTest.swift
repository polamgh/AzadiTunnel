import Foundation

/// Reads connectivity result from the extension probe (main app cannot reach 127.0.0.1 Psiphon proxy).
enum InternetConnectivityTest {
    static func waitForExtensionResult(timeoutSeconds: TimeInterval = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if SharedSettingsStore.shared.vpnStatus != .connected {
                return false
            }
            if SharedSettingsStore.shared.lastInternetTestOK {
                SharedLogger.shared.log(.internetTestPassed, detail: "source=extension_probe")
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        SharedLogger.shared.log(.internetTestFailed, detail: "source=extension_probe_timeout")
        return false
    }

    /// Waits until the tunnel is connected and the extension connectivity probe succeeds.
    static func waitForConnectedTunnel(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if SharedSettingsStore.shared.vpnStatus == .connected,
               SharedSettingsStore.shared.lastInternetTestOK {
                return true
            }
            if SharedSettingsStore.shared.psiphonTunnelEstablished {
                if await waitForExtensionResult(timeoutSeconds: min(30, timeoutSeconds)) {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return SharedSettingsStore.shared.vpnStatus == .connected
            && SharedSettingsStore.shared.lastInternetTestOK
    }
}
