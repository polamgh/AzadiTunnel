import Foundation

/// Shiro Khorshid shared tunnel-core fields (DNS, diagnostics, beast, tactics for direct).
enum PsiphonShiroTunnelConfig {
    private static let dnsServers = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]

    static func apply(to dict: inout [String: Any], settings: AppSettings) {
        dict["EmitDiagnosticNotices"] = true
        dict["EmitDiagnosticNetworkParameters"] = true
        dict["EmitServerAlerts"] = true
        dict["DNSResolverAlternateServers"] = dnsServers

        if settings.disableTimeouts {
            dict["NetworkLatencyMultiplierLambda"] = 0.1
        } else {
            dict.removeValue(forKey: "NetworkLatencyMultiplierLambda")
        }

        if settings.protocolSelection == .direct {
            dict["DisableTactics"] = true
        } else if settings.protocolSelection != .conduit && settings.protocolSelection != .cdnFronting {
            dict.removeValue(forKey: "DisableTactics")
        }

        // Shiro VPN build: beast sets AggressiveEstablishment only (no EstablishTunnelTimeoutSeconds).
        if settings.beastModeEnabled {
            dict["AggressiveEstablishment"] = true
        } else {
            dict.removeValue(forKey: "AggressiveEstablishment")
        }
    }

    static func logSummary(
        settings: AppSettings,
        composedJSON: String,
        embeddedServerEntryLines: Int = 0
    ) -> String {
        guard let data = composedJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "invalid_json"
        }
        let cdn = PsiphonShiroCDNFrontingConfig.enablesCdnFrontingBlock(settings.protocolSelection)
        let overrides = (dict["FrontedMeekDialOverrides"] as? [Any])?.count ?? 0
        let aggressive = dict["AggressiveEstablishment"] as? Bool == true
        let tacticsOff = dict["DisableTactics"] as? Bool == true
        let readiness = PsiphonDistributorKeys.readiness(
            dict: dict,
            embeddedServerEntryLines: embeddedServerEntryLines
        )
        return [
            "protocol=\(settings.protocolSelection.rawValue)",
            "beast=\(settings.beastModeEnabled)",
            "cdn_block=\(cdn)",
            "meek_overrides=\(overrides)",
            "aggressive=\(aggressive)",
            "disable_tactics=\(tacticsOff)",
            readiness.logDetail
        ].joined(separator: " ")
    }
}
