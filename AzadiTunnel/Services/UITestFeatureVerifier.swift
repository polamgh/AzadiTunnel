import Foundation

/// Logs FEATURE_OK / FEATURE_FAIL lines for device UI-test runs (`-UITestVerifyFeatures`).
enum UITestFeatureVerifier {
    private static var didRun = false

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-UITestVerifyFeatures") else { return }
        guard !didRun else { return }
        didRun = true

        SharedLogger.shared.logRaw("FEATURE_RUN", detail: "start")

        check("bundled_config") {
            SharedSettingsStore.shared.hasActivePsiphonConfig
        }

        let connected = await waitForVPN(timeout: 180)
        check("vpn_connected") { connected }
        guard connected else { return }

        let internet = await InternetConnectivityTest.waitForExtensionResult(timeoutSeconds: 90)
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        let appIPInternet = await verifyMainAppIPHTTPSWithRetry(attempts: 2, delaySeconds: 2)
        let appInternet = await verifyMainAppHTTPWithRetry(attempts: 3, delaySeconds: 3)
        let stats = TunnelStatisticsStore.load()
        let hasTcpRelay = stats.tcpRelaySessions > 0
        let hasTraffic = stats.bytesDown > 1000 || stats.bytesUp > 200
        check("internet_probe") { internet && appIPInternet && appInternet }
        if appIPInternet {
            SharedLogger.shared.logRaw("FEATURE_OK", detail: "main_app_ip_https")
        } else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: "main_app_ip_https")
        }
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

        if ProcessInfo.processInfo.arguments.contains("-UITestVerifySecureDNS") {
            await verifySecureDNS()
        }

        SharedLogger.shared.logRaw("FEATURE_RUN", detail: "end")
    }

    private static func verifySecureDNS() async {
        let settings = SharedSettingsStore.shared.appSettings
        SharedLogger.shared.logRaw(
            "SECURE_DNS_UITEST",
            detail: "mode=\(settings.secureDNSMode.rawValue) provider=\(settings.secureDNSProvider.rawValue)"
        )
        guard await waitForExtensionReady(timeout: 90) else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: "secure_dns_extension_not_ready")
            return
        }

        let test = await sendProviderMessageWithRetry("secure-dns:test", attempts: 6)
        if let test, test.hasPrefix("ok:") {
            SharedLogger.shared.logRaw("FEATURE_OK", detail: "secure_dns_test")
        } else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: "secure_dns_test \(test ?? "nil")")
        }
    }

    private static func waitForExtensionReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await VPNController.shared.refreshStatusFromSystem()
            if VPNController.shared.status == .connected,
               SharedSettingsStore.shared.psiphonTunnelEstablished {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private static func sendProviderMessageWithRetry(_ command: String, attempts: Int) async -> String? {
        for attempt in 0..<attempts {
            if let response = await VPNController.shared.sendProviderMessage(command), !response.isEmpty {
                return response
            }
            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
        }
        return nil
    }

    private static func check(_ name: String, _ block: () -> Bool) {
        if block() {
            SharedLogger.shared.logRaw("FEATURE_OK", detail: name)
        } else {
            SharedLogger.shared.logRaw("FEATURE_FAIL", detail: name)
        }
    }

    private static func verifyMainAppHTTPWithRetry(attempts: Int, delaySeconds: UInt64) async -> Bool {
        for attempt in 0..<attempts {
            if await verifyMainAppHTTP() { return true }
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
        return false
    }

    private static func verifyMainAppHTTP() async -> Bool {
        guard let url = URL(string: "https://connectivitycheck.gstatic.com/generate_204") else { return false }
        return await verifyMainAppURL(url, timeout: 15, failureLabel: "hostname")
    }

    /// Separates raw packet/TCP forwarding from DNS. Cloudflare's certificate includes the
    /// 1.1.1.1 IP SAN, so this remains a fully validated HTTPS request without a resolver lookup.
    private static func verifyMainAppIPHTTPSWithRetry(attempts: Int, delaySeconds: UInt64) async -> Bool {
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else { return false }
        for attempt in 0..<attempts {
            if await verifyMainAppURL(url, timeout: 12, failureLabel: "ip_literal") { return true }
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
        return false
    }

    private static func verifyMainAppURL(
        _ url: URL,
        timeout: TimeInterval,
        failureLabel: String
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...399).contains(http.statusCode)
        } catch {
            SharedLogger.shared.logRaw(
                "MAIN_APP_HTTP_FAIL",
                detail: "path=\(failureLabel) reason=\(error.localizedDescription)"
            )
            return false
        }
    }

    private static func waitForVPN(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await VPNController.shared.refreshStatusFromSystem()
            if VPNController.shared.status == .connected,
               SharedSettingsStore.shared.psiphonTunnelEstablished {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
