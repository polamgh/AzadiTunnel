import Foundation
import UIKit

enum DebugReportExporter {
    private static let legalNoticeLine =
        "This debug report is sanitized, but you should review it before sharing."

    private static let forbiddenPatterns: [String] = [
        #""PrivateKey"\s*:\s*"(?!\[redacted\])[^"]{4,}""#,
        #""ServerEntrySignaturePublicKey"\s*:\s*"(?!\[redacted\])[^"]{4,}""#,
        #""ObfuscatedServerEntrySignaturePublicKey"\s*:\s*"(?!\[redacted\])[^"]{4,}""#,
        #""ObfuscationKey"\s*:\s*"(?!\[redacted\])[^"]{4,}""#,
        #"(?i)(access[_-]?token[=:])\s*(?!\[redacted\])\S{8,}"#,
        #"(?i)Authorization:\s*Bearer\s+(?!\[redacted\])\S{8,}"#,
        #"(?i)BEGIN (RSA |EC )?PRIVATE KEY"#
    ]

    static func buildReport() -> String {
        SharedLogger.shared.logRaw("DEBUG_REPORT_EXPORT_STARTED", detail: "source=app")
        let sanitized = sanitize()
        SharedLogger.shared.logRaw("DEBUG_REPORT_SANITIZED", detail: "sections=\(sanitized.keys.count)")

        var lines: [String] = []
        lines.append(legalNoticeLine)
        SharedLogger.shared.logRaw("DEBUG_REPORT_LEGAL_NOTICE_ADDED", detail: "source=app")
        lines.append("AzadiTunnel Debug Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        for key in sanitized.keys.sorted() {
            lines.append("## \(key)")
            lines.append(sanitized[key] ?? "")
            lines.append("")
        }
        let body = lines.joined(separator: "\n")
        verifyNoSecrets(in: body)
        SharedLogger.shared.logRaw("DEBUG_REPORT_EXPORT_READY", detail: "bytes=\(body.utf8.count)")
        return body
    }

    @MainActor
    static func presentShareSheet(from root: UIViewController?) {
        let text = buildReport()
        let item = ReportActivityItem(text: text)
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        let presenter = root ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        presenter?.present(controller, animated: true)
    }

    private static func sanitize() -> [String: String] {
        let settings = SharedSettingsStore.shared.appSettings
        let stats = TunnelStatisticsStore.load()
        let leak = ConnectionDiagnosticsStore.loadLeak()
        let quality = ConnectionDiagnosticsStore.loadQuality()
        let fallback = ConnectionDiagnosticsStore.loadFallback()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let ios = UIDevice.current.systemVersion
        let model = UIDevice.current.model

        var configSummary = "protocol=\(settings.protocolSelection.rawValue) beast=\(settings.beastModeEnabled)"
        if settings.protocolSelection == .cdnFronting {
            configSummary += " cdn_enabled=true"
            configSummary += " cdn_builtin_scan=\(settings.cdnFrontingUseBuiltInScan)"
            configSummary += " cdn_edges_built_in=\(PsiphonShiroCDNFrontingConfig.builtInEdgeIPs.count)"
            configSummary += " cdn_custom_ip_count=\(PsiphonShiroCDNFrontingConfig.parseIPList(settings.cdnFrontingCustomIpList).count)"
            configSummary += " cdn_custom_sni_count=\(PsiphonShiroCDNFrontingConfig.parseSNIList(settings.cdnFrontingCustomSni).count)"
            if let edge = quality?.cdnEdgeIP, !edge.isEmpty {
                configSummary += " cdn_edge=\(redactIP(edge))"
            }
            if let sni = quality?.cdnSNI, !sni.isEmpty {
                configSummary += " cdn_sni=\(sni)"
            }
        } else {
            configSummary += " cdn_enabled=false"
        }
        configSummary += " config_source=\(SharedSettingsStore.shared.usesBundledConfig ? "bundled" : "custom")"
        configSummary += " server_entry_lines=\(SharedSettingsStore.shared.psiphonServerEntriesLineCount)"

        var recent = SharedLogger.shared.allLines().suffix(120).joined(separator: "\n")
        recent = redactSecrets(in: recent)
        recent = redactPaths(in: recent)

        var out: [String: String] = [:]
        out["App"] = "version=\(version) build=\(build)"
        out["Device"] = "model=\(model) ios=\(ios)"
        out["Transport"] = "selection=\(settings.protocolSelection.rawValue) smart_fallback=\(settings.smartFallbackChainEnabled)"
        out["Beast"] = "enabled=\(settings.beastModeEnabled)"
        out["CDN Fronting"] = settings.protocolSelection == .cdnFronting
            ? "enabled=true edge_summary=\(quality.flatMap { $0.cdnEdgeIP.isEmpty ? nil : redactIP($0.cdnEdgeIP) } ?? "n/a") sni=\(quality?.cdnSNI ?? "n/a")"
            : "enabled=false"
        out["Connection"] = "status=\(SharedSettingsStore.shared.vpnStatus.rawValue) protocol=\(stats.connectedTunnelProtocol) internet_ok=\(SharedSettingsStore.shared.lastInternetTestOK)"
        out["Leak test"] = leak.map { "verdict=\($0.verdict.rawValue) ip_after=\(redactIP($0.publicIPAfter)) dns=\($0.dnsSummary)" } ?? "not_run"
        out["Quality"] = quality.map {
            "protocol=\($0.connectedProtocol) https204=\($0.https204Passed) latency_ms=\($0.latencyMs) region=\($0.countryRegion)"
        } ?? "not_run"
        out["Fallback"] = "active=\(fallback.isActive) step=\(fallback.currentStep?.rawValue ?? "-") succeeded=\(fallback.succeededStep?.rawValue ?? "-") exhausted=\(fallback.exhausted)"
        out["Config summary"] = configSummary
        out["Recent logs"] = recent
        return out
    }

    private static func verifyNoSecrets(in body: String) {
        for pattern in forbiddenPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) != nil {
                SharedLogger.shared.logRaw("DEBUG_REPORT_SECRET_REDACTION_FAIL", detail: "pattern=\(pattern.prefix(40))")
                return
            }
        }
        SharedLogger.shared.logRaw("DEBUG_REPORT_SECRET_REDACTION_PASS", detail: "source=app")
    }

    private static func redactSecrets(in text: String) -> String {
        var s = text
        let patterns = [
            #"("(?:Obfuscated|Remote|ServerEntry)SignaturePublicKey"\s*:\s*")[^"]+""#,
            #"("(?:PrivateKey|Password|Token|Secret|ObfuscationKey)"\s*:\s*")[^"]+""#,
            #"(signaturePublicKey=)[^\s]+"#,
            #"(password=)[^\s]+"#,
            #"(?i)(access[_-]?token[=:])\S+"#,
            #"(?i)Authorization:\s*Bearer\s+\S+"#,
            #"("serverEntries"\s*:\s*")[^"]{20,}""#,
            #"("EmbeddedServerEntry"\s*:\s*")[^"]+""#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1[redacted]")
            }
        }
        return redactPaths(in: s)
    }

    private static func redactPaths(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"/Users/[^/\s]+/"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "/Users/[redacted]/")
    }

    private static func redactIP(_ value: String) -> String {
        guard value.contains(".") else { return value.isEmpty ? "n/a" : "redacted" }
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return "redacted" }
        return "\(parts[0]).\(parts[1]).*.*"
    }
}

private final class ReportActivityItem: NSObject, UIActivityItemSource {
    private let text: String
    init(text: String) { self.text = text }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { text }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }
}
