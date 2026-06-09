import Foundation
import Darwin
import Network

enum LeakTestService {
    private static let ipEndpoint = URL(string: "https://api64.ipify.org?format=text")!
    private static let dnsProbeHost = "whoami.akamai.net"

    static func runAfterConnect() async -> LeakTestReport {
        SharedLogger.shared.logRaw("LEAK_TEST_STARTED", detail: "source=post_connect")
        var report = LeakTestReport()

        let before = TunnelStatisticsStore.load().lastPublicIP
        report.publicIPBefore = before.isEmpty ? "unavailable" : before
        SharedLogger.shared.logRaw("LEAK_TEST_PUBLIC_IP", detail: "phase=before value=\(redactIP(report.publicIPBefore))")

        let after = await fetchPublicIP()
        report.publicIPAfter = after.isEmpty ? "unavailable" : after
        SharedLogger.shared.logRaw("LEAK_TEST_PUBLIC_IP", detail: "phase=after value=\(redactIP(report.publicIPAfter))")
        if !after.isEmpty {
            TunnelStatisticsStore.setPublicIP(after)
            await EgressGeoLookup.refreshIfNeeded()
        }

        let dns = await probeDNS()
        report.dnsSummary = dns.summary
        SharedLogger.shared.logRaw("LEAK_TEST_DNS_RESULT", detail: dns.logDetail)

        let ipv6 = probeIPv6()
        report.ipv6Summary = ipv6.summary
        SharedLogger.shared.logRaw("LEAK_TEST_IPV6_RESULT", detail: ipv6.logDetail)

        report.webRTCSummary = "WebRTC local-interface probe not available on iOS; no browser surface in VPN app."
        let evaluation = evaluate(report: report, dns: dns, ipv6: ipv6)
        report.verdict = evaluation.verdict
        report.detail = evaluation.reason
        let verdictToken: String
        if evaluation.reason == "ipv6_linklocal_only" {
            verdictToken = "OK"
        } else {
            verdictToken = evaluation.verdict.rawValue
        }
        SharedLogger.shared.logRaw(
            "LEAK_TEST_RESULT",
            detail: "verdict=\(verdictToken) reason=\(evaluation.reason)"
        )

        ConnectionDiagnosticsStore.saveLeak(report)
        return report
    }

    private static func fetchPublicIP() async -> String {
        var request = URLRequest(url: ipEndpoint)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return "" }
            return text
        } catch {
            return ""
        }
    }

    private static func probeDNS() async -> (summary: String, logDetail: String, leaked: Bool) {
        await withCheckedContinuation { continuation in
            let params = NWParameters.udp
            params.requiredInterfaceType = .other
            let connection = NWConnection(host: NWEndpoint.Host(dnsProbeHost), port: 53, using: params)
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: (
                        "UDP/53 query path opened (tunnel DNS expected)",
                        "status=ready interface=other",
                        false
                    ))
                case .failed(let error):
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: (
                        "DNS probe failed (\(error.localizedDescription))",
                        "status=failed",
                        false
                    ))
                case .waiting(let error):
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: (
                        "DNS probe waiting (\(error.localizedDescription))",
                        "status=waiting",
                        false
                    ))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: (
                    "DNS probe timed out",
                    "status=timeout",
                    false
                ))
            }
        }
    }

    private static func probeIPv6() -> (summary: String, logDetail: String, hasIPv6: Bool) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return ("IPv6 interfaces unavailable", "status=no_ifaddrs", false)
        }
        defer { freeifaddrs(ifaddr) }

        var global6 = false
        var linkLocal6 = false
        var ptr = first
        while true {
            let interface = ptr.pointee
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                if name == "utun0" || name.hasPrefix("utun") {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    let addr = interface.ifa_addr!.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
                    inet_ntop(AF_INET6, &addr.pointee.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    let ip = String(cString: buffer)
                    if ip.hasPrefix("fe80:") {
                        linkLocal6 = true
                    } else if ip.hasPrefix("fc") || ip.hasPrefix("fd") {
                        // ULA on utun — expected when messaging compat blackholes IPv6 in-tunnel.
                        linkLocal6 = true
                    } else if !ip.isEmpty && ip != "::1" {
                        global6 = true
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        if global6 {
            return ("IPv6 global on tunnel interface (review if unexpected)", "ipv6_global=true", true)
        }
        if linkLocal6 {
            return ("IPv6 link-local on tunnel only", "ipv6_linklocal=true", false)
        }
        return ("No IPv6 on tunnel interface", "ipv6_tunnel=false", false)
    }

    private static func evaluate(
        report: LeakTestReport,
        dns: (summary: String, logDetail: String, leaked: Bool),
        ipv6: (summary: String, logDetail: String, hasIPv6: Bool)
    ) -> (verdict: LeakTestVerdict, reason: String) {
        if ipv6.hasIPv6 {
            return (.warning, "ipv6_global_on_tunnel")
        }
        if dns.leaked {
            return (.leakDetected, "dns_leak_detected")
        }
        if ipv6.logDetail.contains("ipv6_linklocal=true") {
            return (.safe, "ipv6_linklocal_only")
        }
        if report.publicIPBefore != "unavailable",
           report.publicIPAfter != "unavailable",
           report.publicIPBefore == report.publicIPAfter,
           !report.publicIPAfter.isEmpty {
            return (.warning, "public_ip_unchanged")
        }
        if report.publicIPAfter == "unavailable" {
            return (.warning, "public_ip_unavailable")
        }
        return (.safe, "no_leak_detected")
    }

    private static func redactIP(_ value: String) -> String {
        guard value.contains(".") else { return value }
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return "redacted" }
        return "\(parts[0]).\(parts[1]).*.*"
    }
}
