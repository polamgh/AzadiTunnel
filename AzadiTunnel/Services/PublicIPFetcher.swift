import Foundation

enum PublicIPFetcher {
    private static let endpoint = URL(string: "https://api64.ipify.org?format=text")!

    /// Only after internet test passes — avoids noisy timeouts while DNS is still settling.
    static func fetchIfNeeded() async {
        guard SharedSettingsStore.shared.lastInternetTestOK else { return }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty else { return }
            TunnelStatisticsStore.setPublicIP(ip)
            await EgressGeoLookup.refreshIfNeeded()
        } catch {
            // Intentionally silent — IP display is optional.
        }
    }
}
