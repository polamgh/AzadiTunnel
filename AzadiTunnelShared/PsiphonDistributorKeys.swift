import Foundation

/// Psiphon distributor credentials (Shiro CI / `psiphon-config.local.json` — never in public git).
enum PsiphonDistributorKeys {
    static let serverEntrySignatureKey = "ServerEntrySignaturePublicKey"
    static let remoteServerListURLsKey = "RemoteServerListURLs"

    static let conduitBlockedStatusLine = "Conduit blocked: missing Psiphon distributor keys"

    struct Readiness: Equatable {
        let entrySignatureKey: Bool
        let remoteList: Bool

        var allowsConduit: Bool { entrySignatureKey && remoteList }

        var logDetail: String {
            "entry_sig_key=\(entrySignatureKey) remote_list=\(remoteList)"
        }
    }

    static func readiness(composedJSON: String, embeddedServerEntryLines: Int) -> Readiness {
        guard let data = composedJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Readiness(entrySignatureKey: false, remoteList: false)
        }
        return readiness(dict: dict, embeddedServerEntryLines: embeddedServerEntryLines)
    }

    static func readiness(dict: [String: Any], embeddedServerEntryLines: Int) -> Readiness {
        let entry = nonEmptyString(dict[serverEntrySignatureKey])
        let remoteURLs = nonEmptyURLList(dict[remoteServerListURLsKey])
        let remote = remoteURLs || embeddedServerEntryLines > 0
        return Readiness(entrySignatureKey: entry, remoteList: remote)
    }

    static func hasServerEntrySignatureKey(in composedJSON: String) -> Bool {
        readiness(composedJSON: composedJSON, embeddedServerEntryLines: 0).entrySignatureKey
    }

    private static func nonEmptyString(_ value: Any?) -> Bool {
        guard let s = value as? String else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func nonEmptyURLList(_ value: Any?) -> Bool {
        if let urls = value as? [String] {
            return urls.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let transferURLs = value as? [[String: Any]] {
            return transferURLs.contains { item in
                let url = (item["URL"] as? String) ?? ""
                return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return false
    }
}
