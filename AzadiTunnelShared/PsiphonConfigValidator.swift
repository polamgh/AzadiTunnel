import Foundation

enum PsiphonConfigValidationError: LocalizedError {
    case empty
    case invalidJSON
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Configuration is empty."
        case .invalidJSON: return "Configuration is not valid JSON."
        case .missingField(let field): return "Missing required field: \(field)."
        }
    }
}

enum PsiphonConfigValidator {
    private static let requiredStringFields = [
        "PropagationChannelId",
        "SponsorId"
    ]

    static func validate(_ jsonText: String, hasEmbeddedServerEntries: Bool = false) throws -> [String: Any] {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PsiphonConfigValidationError.empty }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var dict = object as? [String: Any] else {
            throw PsiphonConfigValidationError.invalidJSON
        }

        for field in requiredStringFields {
            guard let value = dict[field] as? String,
                  !value.isEmpty,
                  !value.hasPrefix("REPLACE_WITH_") else {
                throw PsiphonConfigValidationError.missingField(field)
            }
        }

        if dict["ClientVersion"] == nil {
            dict["ClientVersion"] = "1"
        }

        let hasTarget = (dict["TargetServerEntry"] as? String)?.isEmpty == false
        let hasRemoteList = dict["RemoteServerListURLs"] != nil
        if !hasTarget && !hasRemoteList && !hasEmbeddedServerEntries {
            throw PsiphonConfigValidationError.missingField(
                "TargetServerEntry, RemoteServerListURLs, or embedded server entries"
            )
        }

        return dict
    }

    static func normalizedJSON(_ jsonText: String, hasEmbeddedServerEntries: Bool = false) throws -> String {
        let dict = try validate(jsonText, hasEmbeddedServerEntries: hasEmbeddedServerEntries)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let normalized = String(data: data, encoding: .utf8) else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        return normalized
    }
}
