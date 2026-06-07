import Foundation

/// Fetches egress public IP through Psiphon's in-extension HTTP proxy (Proxy Only mode).
enum ProxyOnlyPublicIPService {
    private static let ipifyURL = "http://api.ipify.org?format=text"

    static func fetch(endpoints: PsiphonLocalProxyEndpoints) async -> String {
        guard endpoints.httpPort > 0 else {
            SharedLogger.shared.logRaw("PROXY_ONLY_PUBLIC_IP_FAILED", detail: "reason=no_http_proxy")
            return ""
        }
        do {
            let data = try await TunnelHttpProxyClient.get(
                url: ipifyURL,
                proxyPort: endpoints.httpPort
            )
            let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !ip.isEmpty else {
                SharedLogger.shared.logRaw("PROXY_ONLY_PUBLIC_IP_FAILED", detail: "reason=empty_body")
                return ""
            }
            SharedLogger.shared.logRaw("PROXY_ONLY_PUBLIC_IP", detail: "source=extension_psiphon_http")
            return ip
        } catch {
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_PUBLIC_IP_FAILED",
                detail: "source=extension_psiphon_http error=\(error.localizedDescription)"
            )
            return ""
        }
    }
}
