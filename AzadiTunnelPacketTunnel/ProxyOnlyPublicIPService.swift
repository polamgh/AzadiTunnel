import Foundation

/// Fetches the egress public IP through Psiphon's local proxy before the
/// Network Extension is allowed to report a completed connection.
enum TunnelPublicIPService {
    private struct Endpoint {
        let host: String
        let path: String

        var url: String { "http://\(host)\(path)" }
    }

    private static let endpoints = [
        Endpoint(host: "api.ipify.org", path: "/?format=text"),
        Endpoint(host: "checkip.amazonaws.com", path: "/"),
        Endpoint(host: "icanhazip.com", path: "/"),
    ]

    static func fetch(endpoints: PsiphonLocalProxyEndpoints) async -> String {
        guard endpoints.hasHttp || endpoints.hasSocks else {
            SharedLogger.shared.logRaw("TUNNEL_PUBLIC_IP_FAILED", detail: "reason=no_local_proxy")
            return ""
        }

        for endpoint in Self.endpoints where !Task.isCancelled {
            if endpoints.hasHttp {
                do {
                    let data = try await TunnelHttpProxyClient.get(
                        url: endpoint.url,
                        proxyPort: endpoints.httpPort,
                        retries: 1
                    )
                    if let ip = parse(data) {
                        SharedLogger.shared.logRaw(
                            "TUNNEL_PUBLIC_IP_OK",
                            detail: "source=extension_http_proxy provider=\(endpoint.host)"
                        )
                        return ip
                    }
                } catch {
                    SharedLogger.shared.logRaw(
                        "TUNNEL_PUBLIC_IP_RETRY",
                        detail: "source=extension_http_proxy provider=\(endpoint.host)"
                    )
                }
            }

            if endpoints.hasSocks {
                do {
                    let data = try await Socks5TCPClient.httpGet(
                        path: endpoint.path,
                        host: endpoint.host,
                        proxyPort: endpoints.socksPort
                    )
                    if let ip = parse(data) {
                        SharedLogger.shared.logRaw(
                            "TUNNEL_PUBLIC_IP_OK",
                            detail: "source=extension_socks_proxy provider=\(endpoint.host)"
                        )
                        return ip
                    }
                } catch {
                    SharedLogger.shared.logRaw(
                        "TUNNEL_PUBLIC_IP_RETRY",
                        detail: "source=extension_socks_proxy provider=\(endpoint.host)"
                    )
                }
            }
        }

        SharedLogger.shared.logRaw("TUNNEL_PUBLIC_IP_FAILED", detail: "reason=all_providers_failed")
        return ""
    }

    private static func parse(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        if let ip = PublicIPAddress.normalized(value) { return ip }
        // Handles a small chunked HTTP body without accepting arbitrary HTML.
        for line in value.components(separatedBy: .newlines) {
            if let ip = PublicIPAddress.normalized(line) { return ip }
        }
        return nil
    }
}
