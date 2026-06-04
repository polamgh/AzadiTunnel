import Foundation

/// Runs connectivity checks inside the extension process (127.0.0.1 proxy is reachable here).
enum TunnelConnectivityProbe {
    private static let dnsCheckPath = "/resolve?name=example.com&type=A"

    static func verifyGenerate204(endpoints: PsiphonLocalProxyEndpoints) async -> Bool {
        let probeDeadline = Date().addingTimeInterval(75)
        while Date() < probeDeadline {
#if canImport(tun2socks)
            if endpoints.hasSocks {
                do {
                    let response = try await Socks5TCPClient.tcpDnsQuery(
                        query: Self.exampleComAQuery,
                        proxyPort: endpoints.socksPort
                    )
                    if response.count >= 12 {
                        TunnelStatisticsStore.recordPacketBytes(down: response.count, up: 64)
                        SharedLogger.shared.log(.internetTestPassed, detail: "via=extension_socks_tcp_dns")
                        SharedSettingsStore.shared.lastInternetTestOK = true
                        return true
                    }
                } catch {
                    SharedLogger.shared.log(.internetTestFailed, detail: "tcp_dns=\(error.localizedDescription)")
                }

                let backends: [(String, String)] = [
                    ("www.google.com", "/generate_204"),
                    ("connectivitycheck.gstatic.com", "/generate_204"),
                    ("dns.google", dnsCheckPath),
                    ("one.one.one.one", dnsCheckPath)
                ]
                for backend in backends {
                    do {
                        let body = try await PsiphonSocksHTTPGet.get(
                            path: backend.1,
                            host: backend.0,
                            port: 80,
                            socksPort: endpoints.socksPort
                        )
                        if backend.0 == "www.google.com" || backend.0 == "connectivitycheck.gstatic.com" {
                            TunnelStatisticsStore.recordPacketBytes(down: max(body.count, 1), up: 512)
                            SharedLogger.shared.log(.internetTestPassed, detail: "via=extension_socks_gstatic204")
                            SharedSettingsStore.shared.lastInternetTestOK = true
                            return true
                        }
                        if let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                           (json["Status"] as? Int) == 0 {
                            TunnelStatisticsStore.recordPacketBytes(down: body.count, up: 512)
                            SharedLogger.shared.log(.internetTestPassed, detail: "via=extension_socks_http host=\(backend.0)")
                            SharedSettingsStore.shared.lastInternetTestOK = true
                            return true
                        }
                    } catch {
                        SharedLogger.shared.log(
                            .internetTestFailed,
                            detail: "socks_http=\(error.localizedDescription) host=\(backend.0)"
                        )
                    }
                }
            }
#endif

            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }

        if endpoints.hasHttp {
            if await verifyViaURLSessionProxy(httpPort: endpoints.httpPort) {
                return true
            }

            var components = URLComponents()
            components.scheme = "http"
            components.host = "dns.google"
            components.path = "/resolve"
            components.queryItems = [
                URLQueryItem(name: "name", value: "example.com"),
                URLQueryItem(name: "type", value: "A")
            ]
            if let url = components.url?.absoluteString {
                do {
                    let body = try await TunnelHttpProxyClient.get(
                        url: url,
                        proxyPort: endpoints.httpPort
                    )
                    if let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                       (json["Status"] as? Int) == 0 {
                        TunnelStatisticsStore.recordPacketBytes(down: body.count, up: 512)
                        SharedLogger.shared.log(.internetTestPassed, detail: "via=extension_http_proxy")
                        SharedSettingsStore.shared.lastInternetTestOK = true
                        return true
                    }
                } catch {
                    SharedLogger.shared.log(.internetTestFailed, detail: "http=\(error.localizedDescription)")
                }
            }
        }

        SharedLogger.shared.log(.internetTestFailed, detail: "via=extension_all_proxies_failed")
        SharedSettingsStore.shared.lastInternetTestOK = false
        return false
    }

    private static func verifyViaURLSessionProxy(httpPort: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": httpPort,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": httpPort
        ]
        guard let url = URL(string: "https://www.google.com/generate_204") else { return false }
        do {
            let (_, response) = try await URLSession(configuration: config).data(from: url)
            if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                TunnelStatisticsStore.recordPacketBytes(down: 64, up: 256)
                SharedLogger.shared.log(.internetTestPassed, detail: "via=extension_urlsession_http_proxy")
                SharedSettingsStore.shared.lastInternetTestOK = true
                return true
            }
        } catch {
            SharedLogger.shared.log(.internetTestFailed, detail: "urlsession_proxy=\(error.localizedDescription)")
        }
        return false
    }

    private static let exampleComAQuery = Data([
        0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
        0x00, 0x01, 0x00, 0x01
    ])
}
