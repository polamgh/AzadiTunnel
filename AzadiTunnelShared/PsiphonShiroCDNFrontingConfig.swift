import Foundation

/// Shiro `TunnelManager.putCdnFrontingConfig` / `makeCdnFrontingDialOverrides` / `makeCdnFrontingScanSpec` parity.
enum PsiphonShiroCDNFrontingConfig {
    /// Shiro `CDN_FRONTING_TUNNEL_PROTOCOLS` (cdn_fronting mode only).
    static let cdnFrontingModeProtocols = [
        "FRONTED-MEEK-CDN-OSSH",
        "FRONTED-MEEK-CDN-HTTP-OSSH",
        "FRONTED-MEEK-CDN-QUIC-OSSH"
    ]

    /// Built-in Akamai/Fastly edge IPs from Shiro `TunnelManager.makeCdnFrontingDialOverrides` (public Java).
    static let builtInEdgeIPs: [(id: String, ip: String)] = [
        ("edge-a-1", "23.215.0.206"),
        ("edge-a-2", "23.215.0.203"),
        ("edge-b-1", "23.212.250.91"),
        ("edge-b-2", "23.212.250.78"),
        ("edge-c-1", "23.12.147.13"),
        ("edge-c-2", "23.12.147.29"),
        ("edge-d-1", "23.73.207.8"),
        ("edge-d-2", "23.73.207.15"),
        ("edge-original", "92.123.102.43")
    ]

    private static let bundledBaseName = "cdn-fronting"
    private static let bundledLocalName = "cdn-fronting.local"

    /// Applies CDN fronting when Shiro enables it: auto, direct, or cdnFronting.
    static func apply(to dict: inout [String: Any], settings: AppSettings) {
        guard enablesCdnFrontingBlock(settings.protocolSelection) else {
            removeCdnKeys(from: &dict)
            return
        }

        let customSni = normalizedFirstSNI(settings.cdnFrontingCustomSni)
        dict["FrontedMeekDialOverrides"] = makeDialOverrides(customSni: customSni)
        dict["FrontedMeekDialOverridesProbability"] = 1.0

        if settings.cdnFrontingUseBuiltInScan {
            dict["FrontedMeekCDNScanUseBuiltInSpec"] = true
        } else {
            dict.removeValue(forKey: "FrontedMeekCDNScanUseBuiltInSpec")
        }

        let scanIPs = allCustomIPCandidates(settings: settings)
        if let scanSpec = makeScanSpec(ipCandidates: scanIPs, customSni: settings.cdnFrontingCustomSni) {
            dict["FrontedMeekCDNScanSpec"] = scanSpec
        } else {
            dict.removeValue(forKey: "FrontedMeekCDNScanSpec")
        }

        if settings.protocolSelection == .cdnFronting {
            dict["DisableTactics"] = true
        }
    }

    static func enablesCdnFrontingBlock(_ selection: AppSettings.ProtocolSelection) -> Bool {
        switch selection {
        case .auto, .direct, .cdnFronting:
            return true
        case .conduit:
            return false
        }
    }

    static func logSummary(settings: AppSettings, composedJSON: String) -> String {
        guard settings.protocolSelection == .cdnFronting,
              let data = composedJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "enabled=false"
        }
        let limits = dict["LimitTunnelProtocols"] as? [String] ?? []
        let edgeCount = builtInEdgeIPs.count + parseIPList(settings.cdnFrontingCustomIpList).count
            + loadBundledExtras().extraEdgeIPs.count
        let sniCount = parseSNIList(settings.cdnFrontingCustomSni).count
            + loadBundledExtras().extraSniHostnames.count
        let scanBuiltIn = dict["FrontedMeekCDNScanUseBuiltInSpec"] as? Bool == true
        let hasScanSpec = dict["FrontedMeekCDNScanSpec"] != nil
        return [
            "enabled=true",
            "scan_builtin=\(scanBuiltIn)",
            "scan_spec=\(hasScanSpec)",
            "protocol_limits_count=\(limits.count)",
            "edge_ips_count=\(edgeCount)",
            "sni_hostnames_count=\(sniCount)"
        ].joined(separator: " ")
    }

    // MARK: - Diagnostics (Shiro TunnelManager notice handlers)

    static func parseDiagnosticNotice(_ message: String) -> CDNFrontingDiagnosticEvent? {
        let lower = message.lowercased()
        if lower.contains("cdn fronting scan active") {
            SharedLogger.shared.logRaw("CDN_FRONTING_SCAN_START", detail: truncated(message))
            return .scanStart
        }
        if lower.contains("cdn fronting scan found") {
            if let route = parseScanFoundRoute(message) {
                SharedLogger.shared.logRaw(
                    "CDN_FRONTING_SCAN_RESULT",
                    detail: "selected_ip=\(route.ip) selected_sni=\(route.sni)"
                )
                return .scanResult(ip: route.ip, sni: route.sni)
            }
            SharedLogger.shared.logRaw("CDN_FRONTING_SCAN_RESULT", detail: "selected_ip=unknown selected_sni=unknown")
            return .scanResult(ip: "unknown", sni: "unknown")
        }
        if lower.contains("cdn fronting scan exhausted") {
            SharedLogger.shared.logRaw("CDN_FRONTING_SCAN_FAILED", detail: "reason=exhausted")
            return .scanFailed(reason: "exhausted")
        }
        return nil
    }

    // MARK: - Bundled extras

    struct BundledCDNExtras: Equatable {
        var extraEdgeIPs: [String] = []
        var extraSniHostnames: [String] = []
    }

    static func loadBundledExtras() -> BundledCDNExtras {
        let merged = mergeBundledJSON()
        return BundledCDNExtras(
            extraEdgeIPs: merged["extraEdgeIPs"] as? [String] ?? [],
            extraSniHostnames: merged["extraSniHostnames"] as? [String] ?? []
        )
    }

    private static func mergeBundledJSON() -> [String: Any] {
        let base = loadJSON(named: bundledBaseName) ?? [:]
        let local = loadJSON(named: bundledLocalName) ?? [:]
        var out = base
        if let ips = local["extraEdgeIPs"] as? [String], !ips.isEmpty {
            out["extraEdgeIPs"] = ips
        }
        if let snis = local["extraSniHostnames"] as? [String], !snis.isEmpty {
            out["extraSniHostnames"] = snis
        }
        return out
    }

    private static func loadJSON(named name: String) -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    // MARK: - Shiro dial overrides

    private static func makeDialOverrides(customSni: String) -> [[String: Any]] {
        var overrides: [[String: Any]] = []
        let fastlyVerify = [
            "www.python.org", "pypi.org", "fastly.com", "www.fastly.com",
            "developer.fastly.com", "githubassets.com", "github.com",
            "github.io", "githubusercontent.com"
        ]
        let fastlyALPN = ["h2", "http/1.1"]

        overrides.append(meekOverride(
            id: "fastly-provider",
            providerRegexes: ["(?i)fastly"],
            dialAddressRegexes: nil,
            dialAddress: "pypi.org",
            sni: "pypi.org",
            verifyNames: fastlyVerify,
            alpn: fastlyALPN
        ))
        overrides.append(meekOverride(
            id: "fastly-address",
            providerRegexes: nil,
            dialAddressRegexes: ["(?i)(fastly|pypi|python|github)"],
            dialAddress: "pypi.org",
            sni: "pypi.org",
            verifyNames: fastlyVerify,
            alpn: fastlyALPN
        ))

        var seenIPs = Set<String>()
        for (id, ip) in builtInEdgeIPs where seenIPs.insert(ip).inserted {
            overrides.append(edgeOverride(id: id, ip: ip, customSni: customSni))
        }
        for ip in loadBundledExtras().extraEdgeIPs {
            let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenIPs.insert(trimmed).inserted else { continue }
            overrides.append(edgeOverride(id: "bundled-\(trimmed)", ip: trimmed, customSni: customSni))
        }
        return overrides
    }

    private static func makeScanSpec(ipCandidates: [String], customSni: String) -> [String: Any]? {
        guard !ipCandidates.isEmpty else { return nil }
        var spec: [String: Any] = ["IPCandidates": ipCandidates]
        let snis = parseSNIList(customSni)
        if !snis.isEmpty {
            spec["SNIServerNames"] = snis
        }
        return spec
    }

    private static func allCustomIPCandidates(settings: AppSettings) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for ip in parseIPList(settings.cdnFrontingCustomIpList) + loadBundledExtras().extraEdgeIPs {
            if seen.insert(ip).inserted { out.append(ip) }
        }
        return out
    }

    // MARK: - Parsing (Shiro parseCdnFrontingCustomIpCandidates / parseCdnFrontingCustomSniList)

    static func parseIPList(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for entry in text.split(whereSeparator: { ",; \n\t".contains($0) }) {
            let candidate = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, isValidIPv4(candidate) || isValidIPv4CIDR(candidate) else { continue }
            if seen.insert(candidate).inserted { out.append(candidate) }
        }
        return out
    }

    static func parseSNIList(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for entry in text.split(whereSeparator: { ",; \n\t".contains($0) }) {
            let sni = normalizeHostname(String(entry))
            guard !sni.isEmpty, seen.insert(sni).inserted else { continue }
            out.append(sni)
        }
        return out
    }

    private static func normalizedFirstSNI(_ text: String) -> String {
        parseSNIList(text).first ?? ""
    }

    private static func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return false }
            guard let value = Int(part), (0...255).contains(value) else { return false }
        }
        return true
    }

    private static func isValidIPv4CIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isValidIPv4(String(parts[0])), let prefix = Int(parts[1]) else { return false }
        return (0...32).contains(prefix)
    }

    private static func normalizeHostname(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253, !isValidIPv4(host) else { return "" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return "" }
        for label in labels {
            if label.isEmpty || label.count > 63 || label.hasPrefix("-") || label.hasSuffix("-") { return "" }
            for ch in label where !ch.isLetter && !ch.isNumber && ch != "-" { return "" }
        }
        return host
    }

    private static func meekOverride(
        id: String,
        providerRegexes: [String]?,
        dialAddressRegexes: [String]?,
        dialAddress: String,
        sni: String,
        verifyNames: [String],
        alpn: [String]
    ) -> [String: Any] {
        var o: [String: Any] = [
            "OverrideID": id,
            "DialAddresses": [dialAddress],
            "SNIServerName": sni,
            "VerifyServerNames": verifyNames,
            "ALPNProtocols": alpn,
            "TLSProfile": "Chrome-83"
        ]
        if let providerRegexes { o["MatchFrontingProviderIDRegexes"] = providerRegexes }
        if let dialAddressRegexes { o["MatchDialAddressRegexes"] = dialAddressRegexes }
        return o
    }

    private static func edgeOverride(id: String, ip: String, customSni: String) -> [String: Any] {
        let sni = customSni.isEmpty ? ip : customSni
        let verify = uniqueStrings([
            sni, ip,
            "a248.e.akamai.net", "a.akamaized.net", "a.akamaized-staging.net",
            "a.akamaihd.net", "a.akamaihd-staging.net", "www.akamai.com"
        ])
        return meekOverride(
            id: id,
            providerRegexes: nil,
            dialAddressRegexes: [".*"],
            dialAddress: ip,
            sni: sni,
            verifyNames: verify,
            alpn: ["http/1.1"]
        )
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func removeCdnKeys(from dict: inout [String: Any]) {
        dict.removeValue(forKey: "FrontedMeekDialOverrides")
        dict.removeValue(forKey: "FrontedMeekDialOverridesProbability")
        dict.removeValue(forKey: "FrontedMeekCDNScanUseBuiltInSpec")
        dict.removeValue(forKey: "FrontedMeekCDNScanSpec")
    }

    private static func parseScanFoundRoute(_ message: String) -> (ip: String, sni: String)? {
        guard let open = message.range(of: "(ip: "),
              let close = message.range(of: ")", range: open.upperBound..<message.endIndex) else {
            return nil
        }
        let inner = message[open.upperBound..<close.lowerBound]
        let parts = inner.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let ip = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        var sni = parts[1]
            .replacingOccurrences(of: "sni:", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if sni == "none" { sni = "no SNI" }
        return ip.isEmpty ? nil : (ip: ip, sni: sni)
    }

    private static func truncated(_ message: String, max: Int = 200) -> String {
        message.count > max ? String(message.prefix(max)) : message
    }
}

enum CDNFrontingDiagnosticEvent: Equatable {
    case scanStart
    case scanResult(ip: String, sni: String)
    case scanFailed(reason: String)
}
