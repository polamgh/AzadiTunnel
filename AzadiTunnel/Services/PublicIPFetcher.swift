import Foundation

enum PublicIPFetcher {
    private static let endpoint = URL(string: "https://api64.ipify.org?format=text")!

    /// Only after internet test passes — avoids noisy timeouts while DNS is still settling.
    static func fetchIfNeeded() async {
        guard SharedSettingsStore.shared.lastInternetTestOK else { return }
        if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
            await fetchProxyOnly()
        } else {
            await fetchDirect()
        }
    }

    private static func fetchDirect() async {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = parseIP(from: data) else { return }
            TunnelStatisticsStore.setPublicIP(text)
            await EgressGeoLookup.refreshIfNeeded()
        } catch {
            // Intentionally silent — IP display is optional in full VPN mode.
        }
    }

    private static func fetchProxyOnly() async {
        if let ip = await fetchViaProxyBridge(), !ip.isEmpty {
            TunnelStatisticsStore.setPublicIP(ip)
            await EgressGeoLookup.refreshIfNeeded()
            return
        }
        if TunnelStatisticsStore.load().lastPublicIP.isEmpty {
            TunnelStatisticsStore.setPublicIP("")
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_PUBLIC_IP_FAILED",
                detail: "reason=app_bridge_failed_extension_may_retry"
            )
        }
    }

    /// Main app → Wi-Fi IP HTTP bridge → Psiphon (same path as manual HTTP proxy).
    private static func fetchViaProxyBridge() async -> String? {
        guard let host = SameDeviceProxyAddress.reachableHost(
            boundHost: SharedSettingsStore.shared.lanProxyBoundHost
        ) ?? LocalNetworkAddress.wifiIPv4() else {
            return nil
        }
        let settings = SharedSettingsStore.shared.appSettings
        let port = SharedSettingsStore.shared.lanProxyActiveHttpPort > 0
            ? SharedSettingsStore.shared.lanProxyActiveHttpPort
            : settings.lanHttpProxyPort

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 25

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = parseIP(from: data) else { return nil }
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_PUBLIC_IP",
                detail: "source=app_http_proxy_bridge host=\(host) port=\(port)"
            )
            return text
        } catch {
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_PUBLIC_IP_FAILED",
                detail: "source=app_http_proxy_bridge error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func parseIP(from data: Data) -> String? {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
