import Foundation

enum ConnectionQualityService {
    private static let generate204 = URL(string: "https://www.google.com/generate_204")!

    static func runAfterConnect() async -> ConnectionQualityReport {
        SharedLogger.shared.logRaw("QUALITY_TEST_STARTED", detail: "source=post_connect")
        var report = ConnectionQualityReport()
        let stats = TunnelStatisticsStore.load()
        let settings = SharedSettingsStore.shared.appSettings

        report.connectedProtocol = stats.connectedTunnelProtocol
        report.publicIP = stats.lastPublicIP
        report.countryRegion = stats.egressLocationSubtitle
        if report.countryRegion.isEmpty, !stats.connectedServerRegion.isEmpty {
            report.countryRegion = RegionDisplayNames.countryName(for: stats.connectedServerRegion)
        }
        report.transportMode = settings.protocolSelection.rawValue
        if settings.beastModeEnabled { report.transportMode += "+beast" }

        if settings.protocolSelection == .cdnFronting {
            for line in SharedLogger.shared.allLines().reversed() {
                guard line.contains("CDN_FRONTING_SCAN_RESULT") else { continue }
                if let ip = parseLogField(line, key: "selected_ip"), !ip.isEmpty, ip != "unknown" {
                    report.cdnEdgeIP = sanitizeCDNField(ip)
                }
                if let sni = parseLogField(line, key: "selected_sni"), !sni.isEmpty, sni != "unknown" {
                    report.cdnSNI = sanitizeCDNField(sni)
                }
                break
            }
        }

        SharedLogger.shared.logRaw("QUALITY_PROTOCOL", detail: "value=\(report.connectedProtocol)")
        if !report.publicIP.isEmpty {
            SharedLogger.shared.logRaw("QUALITY_PUBLIC_IP", detail: "present=true")
        }

        let latency = await measureLatencyMs()
        report.latencyMs = latency
        if latency >= 0 {
            SharedLogger.shared.logRaw("QUALITY_LATENCY_MS", detail: "value=\(latency)")
        }

        report.https204Passed = await verifyHTTPS204()
        if report.https204Passed {
            SharedLogger.shared.logRaw("QUALITY_HTTPS_204_PASSED", detail: "url=generate_204")
        } else {
            SharedLogger.shared.logRaw("QUALITY_HTTPS_204_FAILED", detail: "url=generate_204")
        }

        report.readyAt = Date()
        ConnectionDiagnosticsStore.saveQuality(report)
        SharedLogger.shared.logRaw("QUALITY_REPORT_READY", detail: "protocol=\(report.connectedProtocol)")
        return report
    }

    private static func measureLatencyMs() async -> Int {
        var request = URLRequest(url: generate204)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else { return -1 }
            return Int(Date().timeIntervalSince(start) * 1000)
        } catch {
            return -1
        }
    }

    private static func parseLogField(_ line: String, key: String) -> String? {
        let token = "\(key)="
        guard let range = line.range(of: token) else { return nil }
        let rest = line[range.upperBound...]
        if key == "selected_sni" {
            return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let value = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        return value.map { String($0) }
    }

    private static func sanitizeCDNField(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\\\", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verifyHTTPS204() async -> Bool {
        var request = URLRequest(url: generate204)
        request.timeoutInterval = 20
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 204
        } catch {
            return false
        }
    }
}
