import Foundation

/// Shiro parity: tunnel-core fetches remote server list in parallel; logs readiness (no secrets).
enum PsiphonRemoteServerListDiagnostics {
    private static var fetchStarted = false
    private static var storeCompleted = false

    static func handleDiagnostic(_ message: String) {
        let lower = message.lowercased()
        if lower.contains("fetching common remote server list") {
            fetchStarted = true
            SharedLogger.shared.logRaw("REMOTE_SERVER_LIST_FETCH", detail: "phase=start")
        }
        if message.contains("RemoteServerListResourceDownloaded") {
            storeCompleted = true
            SharedLogger.shared.logRaw("REMOTE_SERVER_LIST_FETCH", detail: "phase=downloaded")
        }
        if lower.contains("failed to download common remote server list") {
            SharedLogger.shared.logRaw("REMOTE_SERVER_LIST_FETCH", detail: "phase=failed")
        }
        if message.contains("CandidateServers") {
            let count = parseCandidateCount(message)
            if count > 0 {
                SharedLogger.shared.logRaw(
                    "CANDIDATE_SERVERS",
                    detail: "count=\(count) remote_stored=\(storeCompleted)"
                )
            }
        }
    }

    static func logBootstrapSummary(dict: [String: Any], embeddedLines: Int) {
        let urlCount = transferURLCount(dict["RemoteServerListURLs"])
        let hasSig = nonEmptyString(dict["RemoteServerListSignaturePublicKey"])
        let clientVersion = (dict["ClientVersion"] as? String) ?? ""
        SharedLogger.shared.logRaw(
            "REMOTE_SERVER_LIST_CONFIG",
            detail: "embedded_lines=\(embeddedLines) remote_urls=\(urlCount) list_sig=\(hasSig) client_version=\(clientVersion.isEmpty ? "unset" : clientVersion)"
        )
    }

    private static func parseCandidateCount(_ message: String) -> Int {
        guard let data = extractJSONObject(from: message),
              let count = data["count"] as? Int else {
            return 0
        }
        return count
    }

    private static func extractJSONObject(from message: String) -> [String: Any]? {
        var jsonStr = message
        if let range = message.range(of: ": {") {
            jsonStr = String(message[range.upperBound...])
        } else if let range = message.range(of: ":{") {
            jsonStr = String(message[range.upperBound...])
        }
        guard let data = jsonStr.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
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
