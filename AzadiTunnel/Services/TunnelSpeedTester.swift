import Foundation

/// Measures real usable download speed through whatever path `URLSession` currently uses.
///
/// In full-VPN mode `URLSession.shared` traffic goes through the AzadiTunnel tunnel, so this
/// reflects the usable speed of the currently connected protocol/region. Used by
/// ``BestConnectionFinder``; it does not change any connection settings itself.
enum TunnelSpeedTester {
    /// Download targets tried in order. Cloudflare lets us request an exact byte count; the Hetzner
    /// fallback supports HTTP Range so we still cap the transfer if Cloudflare is unreachable.
    private static let payloadBytes = 5_000_000
    private static var targets: [(url: URL, headers: [String: String])] {
        [
            (URL(string: "https://speed.cloudflare.com/__down?bytes=\(payloadBytes)")!, [:]),
            (URL(string: "https://speed.hetzner.de/100MB.bin")!, ["Range": "bytes=0-\(payloadBytes - 1)"]),
        ]
    }

    /// Returns measured Mbps, or 0 if every target failed/timed out (treated as "below threshold").
    static func measureMbps(timeout: TimeInterval = 14) async -> Double {
        for target in targets {
            if Task.isCancelled { return 0 }
            if let mbps = await download(url: target.url, headers: target.headers, timeout: timeout), mbps > 0 {
                return mbps
            }
        }
        return 0
    }

    private static func download(url: URL, headers: [String: String], timeout: TimeInterval) async -> Double? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCache = nil
        let session = URLSession(configuration: config)

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let seconds = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  seconds > 0.05, data.count > 100_000 else {
                return nil
            }
            // Mbps = bits / seconds / 1e6
            return (Double(data.count) * 8.0) / seconds / 1_000_000.0
        } catch {
            return nil
        }
    }
}
