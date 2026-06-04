import Foundation

/// Logs FEATURE_OK / FEATURE_FAIL lines for device UI-test runs (`-UITestVerifyFeatures`).
enum UITestFeatureVerifier {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-UITestVerifyFeatures") else { return }

        SharedLogger.shared.logRaw("FEATURE_RUN", detail: "start")

        check("bundled_config") {
            SharedSettingsStore.shared.hasActivePsiphonConfig
        }

        let connected = await waitForVPN(timeout: 180)
        check("vpn_connected") { connected }
        guard connected else { return }

        let internet = await InternetConnectivityTest.waitForExtensionResult(timeoutSeconds: 90)
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let appInternet = await verifyMainAppHTTP()
        let stats = TunnelStatisticsStore.load()
        let hasTcpRelay = stats.tcpRelaySessions > 0
        let hasTraffic = stats.bytesDown > 1000 || stats.bytesUp > 200
        check("internet_probe") { internet && appInternet }
        if appInternet {
            SharedLogger.shared.logRaw("FEATURE_OK", detail: "main_app_http")
        } else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: "main_app_http")
        }
        check("stats_readable") { hasTraffic || hasTcpRelay || !stats.lastPublicIP.isEmpty }

        check("logs_non_empty") {
            !SharedLogger.shared.allLines().isEmpty
        }

        check("settings_roundtrip") {
            var s = SharedSettingsStore.shared.appSettings
            let prior = s.autoReconnect
            s.autoReconnect = !prior
            SharedSettingsStore.shared.updateAppSettings(s, logKey: "uitest_toggle")
            let read = SharedSettingsStore.shared.appSettings.autoReconnect
            s.autoReconnect = prior
            SharedSettingsStore.shared.updateAppSettings(s, logKey: "uitest_restore")
            return read == !prior
        }

        check("app_settings_load") {
            _ = SharedSettingsStore.shared.appSettings.connectOnLaunch
            return true
        }

        SharedLogger.shared.logRaw("FEATURE_RUN", detail: "end")
    }

    private static func check(_ name: String, _ block: () -> Bool) {
        if block() {
            SharedLogger.shared.logRaw("FEATURE_OK", detail: name)
        } else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: name)
        }
    }

    private static func verifyMainAppHTTP() async -> Bool {
        guard let url = URL(string: "https://connectivitycheck.gstatic.com/generate_204") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...399).contains(http.statusCode)
        } catch {
            SharedLogger.shared.logRaw("MAIN_APP_HTTP_FAIL", detail: error.localizedDescription)
            return false
        }
    }

    private static func waitForVPN(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SharedSettingsStore.shared.vpnStatus == .connected {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
