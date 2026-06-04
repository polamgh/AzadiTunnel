import Foundation

/// Shiro Khorshid Android `TunnelManager` conduit parity checks (no secret values).
enum PsiphonShiroConduitCompare {
    static func logComposedConfig(
        dict: [String: Any],
        settings: AppSettings,
        embeddedServerEntryLines: Int
    ) {
        let limits = dict["LimitTunnelProtocols"] as? [String] ?? []
        let limitMatch = limits == PsiphonProtocolSets.conduit
        let disableTactics = dict["DisableTactics"] as? Bool == true
        let personalID = nonEmptyString(dict["InproxyClientPersonalCompartmentID"])
        let remoteURLs = transferURLCount(dict["RemoteServerListURLs"])
        let obfRoots = transferURLCount(dict["ObfuscatedServerListRootURLs"])
        let entrySig = nonEmptyString(dict["ServerEntrySignaturePublicKey"])
        let listSig = nonEmptyString(dict["RemoteServerListSignaturePublicKey"])
        let exchange = nonEmptyString(dict["ExchangeObfuscationKey"])
        let clientVersion = (dict["ClientVersion"] as? String) ?? ""
        let aggressive = dict["AggressiveEstablishment"] as? Bool == true
        let tunnelTimeout = dict["EstablishTunnelTimeoutSeconds"] as? Int
        let mode = settings.conduitMode.rawValue
        let compartmentMode: String
        if settings.conduitMode == .publicOnly {
            compartmentMode = "public"
        } else if settings.conduitMode == .auto, settings.conduitFallbackToPublic {
            compartmentMode = "auto_public_fallback"
        } else if settings.conduitMode == .auto {
            compartmentMode = "auto_community"
        } else {
            compartmentMode = "shirokhorshid"
        }

        SharedLogger.shared.logRaw(
            "SHIRO_COMPARE_CONDUIT_CONFIG",
            detail: [
                "protocols_match=\(limitMatch)",
                "protocol_count=\(limits.count)",
                "disable_tactics=\(disableTactics)",
                "shiro_conduit_expects_disable_tactics=false",
                "personal_compartment=\(personalID)",
                "compartment_mode=\(compartmentMode)",
                "embedded_entries=\(embeddedServerEntryLines)",
                "remote_list_urls=\(remoteURLs)",
                "obfuscated_list_roots=\(obfRoots)",
                "entry_sig_key=\(entrySig)",
                "remote_list_sig=\(listSig)",
                "exchange_key=\(exchange)",
                "client_version=\(clientVersion.isEmpty ? "unset" : clientVersion)",
                "shiro_expects_client_version=453",
                "aggressive=\(aggressive)",
                "establish_timeout_s=\(tunnelTimeout.map(String.init) ?? "unset")",
                "shiro_conduit_expects_establish_timeout=unset",
                "beast=\(settings.beastModeEnabled)"
            ].joined(separator: " ")
        )

        SharedLogger.shared.logRaw(
            "CONDUIT_COMPARTMENT_MODE",
            detail: compartmentMode
        )
    }

    static func logDiagnostic(_ message: String) {
        let lower = message.lowercased()
        if lower.contains("no broker specs") {
            SharedLogger.shared.logRaw("CONDUIT_BROKER_SPEC_SOURCE", detail: "missing")
        } else if lower.contains("await tactics") || lower.contains("fetching tactics") {
            SharedLogger.shared.logRaw("CONDUIT_TACTICS_READY", detail: "pending")
        } else if lower.contains("applied inproxy broker tactics")
            || lower.contains("in-proxy protocol selection") && !lower.contains("no broker") {
            SharedLogger.shared.logRaw("CONDUIT_TACTICS_READY", detail: "true")
            SharedLogger.shared.logRaw("CONDUIT_BROKER_SPEC_SOURCE", detail: "tactics_or_config")
        }
        if lower.contains("no_match") || lower.contains("no match") {
            let snippet = message.count > 160 ? String(message.prefix(160)) : message
            SharedLogger.shared.logRaw("CONDUIT_NO_MATCH", detail: snippet)
        }
        if lower.contains("inproxy-dial:") || lower.contains("broker offer") {
            SharedLogger.shared.logRaw("CONDUIT_RETRY", detail: "inproxy_activity")
        }
    }

    private static func nonEmptyString(_ value: Any?) -> Bool {
        guard let s = value as? String else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func transferURLCount(_ value: Any?) -> Int {
        if let strings = value as? [String] {
            return strings.filter { !$0.isEmpty }.count
        }
        if let objects = value as? [[String: Any]] {
            return objects.filter { ($0["URL"] as? String)?.isEmpty == false }.count
        }
        return 0
    }
}
