import Foundation

/// Deep-merges Psiphon JSON: local overlay wins; nested dictionaries merge recursively.
enum PsiphonConfigMerge {
    static func merge(baseJSON: String, overlayJSON: String) throws -> String {
        guard let baseData = baseJSON.data(using: .utf8),
              let overlayData = overlayJSON.data(using: .utf8),
              let base = try JSONSerialization.jsonObject(with: baseData) as? [String: Any],
              let overlay = try JSONSerialization.jsonObject(with: overlayData) as? [String: Any] else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        let merged = mergeDict(base, overlay)
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        guard let text = String(data: out, encoding: .utf8) else {
            throw PsiphonConfigValidationError.invalidJSON
        }
        return text
    }

    private static func mergeDict(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in overlay {
            if isEmptyOverlayValue(value) {
                out.removeValue(forKey: key)
                continue
            }
            if let nestedOverlay = value as? [String: Any],
               let nestedBase = out[key] as? [String: Any] {
                out[key] = mergeDict(nestedBase, nestedOverlay)
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func isEmptyOverlayValue(_ value: Any) -> Bool {
        if let s = value as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let arr = value as? [Any] {
            return arr.isEmpty
        }
        return false
    }
}
