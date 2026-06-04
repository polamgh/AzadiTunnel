import CryptoKit
import Foundation

/// Community (personal compartment) Conduit diagnostics — no secret values in logs.
enum PsiphonCommunityDiagnostics {
    private static var active = false
    private static var brokerReached = false
    private static var brokerSpecCount: Int?
    private static var inproxyDialStarted = false
    private static var iceStarted = false
    private static var peerMatched = false
    private static var noMatchCount = 0
    private static var loggedFinal = false

    static func reset() {
        active = false
        brokerReached = false
        brokerSpecCount = nil
        inproxyDialStarted = false
        iceStarted = false
        peerMatched = false
        noMatchCount = 0
        loggedFinal = false
    }

    /// Call when tunnel starts with community compartment (shirokhorshid or auto before fallback).
    static func logCompareStarted(composedJSON: String, settings: AppSettings) {
        guard settings.protocolSelection == .conduit else { return }
        guard isCommunityPhase(settings: settings) else { return }

        reset()
        active = true

        let dict = (try? JSONSerialization.jsonObject(with: Data(composedJSON.utf8)) as? [String: Any]) ?? [:]
        let propagation = (dict["PropagationChannelId"] as? String) ?? ""
        let sponsor = (dict["SponsorId"] as? String) ?? ""
        let clientVersion = (dict["ClientVersion"] as? String) ?? ""
        let bundledCompartment = (dict[PsiphonConduitConfig.bundledCompartmentKey] as? String) ?? ""
        let inproxyCompartment = (dict["InproxyClientPersonalCompartmentID"] as? String) ?? ""
        let usesPersonal = PsiphonConduitConfig.usesPersonalCompartment(settings: settings)

        SharedLogger.shared.logRaw("COMMUNITY_COMPARE_STARTED", detail: "mode=\(settings.conduitMode.rawValue)")
        SharedLogger.shared.logRaw(
            "COMMUNITY_CONFIG_COMPARE",
            detail: [
                "client_version=\(clientVersion.isEmpty ? "unset" : clientVersion)",
                "propagation_set=\(!propagation.isEmpty)",
                "sponsor_set=\(!sponsor.isEmpty)",
                "personal_compartment_enabled=\(usesPersonal)",
                "bundled_compartment_set=\(!bundledCompartment.isEmpty)",
                "inproxy_compartment_set=\(!inproxyCompartment.isEmpty)",
                "compartment_ids_match=\(bundledCompartment == inproxyCompartment)",
                "remote_urls=\(transferURLCount(dict["RemoteServerListURLs"]))",
                "entry_sig=\(nonEmpty(dict["ServerEntrySignaturePublicKey"]))",
                "list_sig=\(nonEmpty(dict["RemoteServerListSignaturePublicKey"]))",
                "exchange_key=\(nonEmpty(dict["ExchangeObfuscationKey"]))",
                "disable_tactics=\((dict["DisableTactics"] as? Bool) == true)",
                "reject_countries=\((dict["InproxyRejectProxyCountryCodes"] as? [String])?.count ?? 0)"
            ].joined(separator: " ")
        )

        let compartmentForHash = inproxyCompartment.isEmpty ? bundledCompartment : inproxyCompartment
        if !compartmentForHash.isEmpty {
            let hash = sha256Prefix(compartmentForHash)
            SharedLogger.shared.logRaw(
                "COMMUNITY_COMPARTMENT_ID_HASH",
                detail: "value=\(hash) len=\(compartmentForHash.count)"
            )
        } else {
            SharedLogger.shared.logRaw("COMMUNITY_COMPARTMENT_ID_HASH", detail: "value=none")
        }
    }

    static func handleDiagnostic(_ message: String) {
        guard active else { return }
        let lower = message.lowercased()

        if lower.contains("in-proxy broker selected") || lower.contains("selected broker") {
            brokerReached = true
            SharedLogger.shared.logRaw("COMMUNITY_BROKER_REACHED", detail: "true")
        }
        if lower.contains("no broker specs") {
            brokerSpecCount = 0
            SharedLogger.shared.logRaw("COMMUNITY_BROKER_SPEC_COUNT", detail: "count=0")
        }
        if lower.contains("applied inproxy broker") || lower.contains("in-proxy protocol selection") {
            if !lower.contains("no broker") {
                if brokerSpecCount == nil { brokerSpecCount = 1 }
                SharedLogger.shared.logRaw(
                    "COMMUNITY_BROKER_SPEC_COUNT",
                    detail: "count=\(brokerSpecCount ?? 1) source=tactics_or_config"
                )
            }
        }
        if lower.contains("inproxy-dial:") || lower.contains("broker offer") {
            if !inproxyDialStarted {
                inproxyDialStarted = true
                SharedLogger.shared.logRaw("COMMUNITY_INPROXY_DIAL_STARTED", detail: "true")
            }
        }
        if lower.contains("ice gathering") {
            if !iceStarted {
                iceStarted = true
                SharedLogger.shared.logRaw("COMMUNITY_ICE_STARTED", detail: "true")
            }
        }
        if lower.contains("no_match") || lower.contains("no match") {
            noMatchCount += 1
            SharedLogger.shared.logRaw("COMMUNITY_NO_MATCH", detail: "count=\(noMatchCount)")
        }
        if message.contains("CONDUIT_CONNECTED_PROTOCOL") || message.contains("PSIPHON_CONNECTED_PROTOCOL"),
           message.contains("INPROXY-WEBRTC-") {
            peerMatched = true
            SharedLogger.shared.logRaw("COMMUNITY_PEER_MATCHED", detail: "true")
            logFinalResult("CONNECTED")
        }
    }

    static func notePublicFallback() {
        guard active, !loggedFinal else { return }
        logFinalResult("FALLBACK")
    }

    static func noteTimeout() {
        guard active, !loggedFinal else { return }
        if noMatchCount > 0 {
            logFinalResult("NO_MATCH")
        } else if !brokerReached {
            logFinalResult("TIMEOUT")
        } else {
            logFinalResult("NO_MATCH")
        }
    }

    private static func logFinalResult(_ result: String) {
        guard !loggedFinal else { return }
        loggedFinal = true
        SharedLogger.shared.logRaw(
            "COMMUNITY_FINAL_RESULT",
            detail: "result=\(result) broker=\(brokerReached) ice=\(iceStarted) peer=\(peerMatched) no_match=\(noMatchCount)"
        )
    }

    private static func isCommunityPhase(settings: AppSettings) -> Bool {
        switch settings.conduitMode {
        case .shiroCommunity:
            return true
        case .auto:
            return !settings.conduitFallbackToPublic
        case .publicOnly:
            return false
        }
    }

    private static func sha256Prefix(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: Any?) -> Bool {
        guard let s = value as? String else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func transferURLCount(_ value: Any?) -> Int {
        if let strings = value as? [String] { return strings.filter { !$0.isEmpty }.count }
        if let objects = value as? [[String: Any]] {
            return objects.filter { ($0["URL"] as? String)?.isEmpty == false }.count
        }
        return 0
    }
}
