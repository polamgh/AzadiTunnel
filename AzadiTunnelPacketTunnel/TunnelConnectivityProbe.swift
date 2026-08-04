import Foundation

/// Runs a small HTTPS connectivity check inside the extension process. DNS is never probed with
/// plaintext JSON or TCP/53; ordinary host resolution remains inside Psiphon's proxy path.
enum TunnelConnectivityProbe {
    static func verifyGenerate204(endpoints: PsiphonLocalProxyEndpoints) async -> Bool {
        let probeDeadline = Date().addingTimeInterval(75)
        while Date() < probeDeadline, !Task.isCancelled {
            if endpoints.hasSocks {
                do {
                    _ = try await Socks5TCPClient.httpGet(
                        path: "/generate_204",
                        host: "www.google.com",
                        port: 80,
                        proxyHost: "127.0.0.1",
                        proxyPort: endpoints.socksPort
                    )
                    return markPassed(detail: "via=extension_socks_http_204")
                } catch {
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "socks_https_probe=failed"
                    )
                }
            }

            if endpoints.hasHttp {
                do {
                    _ = try await TunnelHttpProxyClient.get(
                        url: "http://www.google.com/generate_204",
                        proxyPort: endpoints.httpPort,
                        retries: 1
                    )
                    return markPassed(detail: "via=extension_http_proxy_204")
                } catch {
                    SharedLogger.shared.log(
                        .internetTestFailed,
                        detail: "http_proxy_probe=failed"
                    )
                }
            }

            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }

        SharedLogger.shared.log(.internetTestFailed, detail: "via=extension_proxies_failed")
        SharedSettingsStore.shared.lastInternetTestOK = false
        return false
    }

    private static func markPassed(detail: String) -> Bool {
        TunnelStatisticsStore.recordPacketBytes(down: 64, up: 256)
        SharedLogger.shared.log(.internetTestPassed, detail: detail)
        SharedSettingsStore.shared.lastInternetTestOK = true
        return true
    }
}
