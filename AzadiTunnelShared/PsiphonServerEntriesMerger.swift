import Foundation

/// Append unique Psiphon server entry lines (Shiro: embedded bootstrap + tunnel remote fetch into datastore).
enum PsiphonServerEntriesMerger {
    static func appendUniqueLines(_ newLines: [String]) throws -> Int {
        guard !newLines.isEmpty,
              let url = SharedSettingsStore.shared.psiphonServerEntriesFileURLForMerge else {
            return 0
        }
        var existing = Set<String>()
        if FileManager.default.fileExists(atPath: url.path),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty, !s.hasPrefix("#") {
                    existing.insert(s)
                }
            }
        }
        var added = 0
        var out = existing.sorted().joined(separator: "\n")
        for line in newLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !existing.contains(trimmed) else { continue }
            if !out.isEmpty { out += "\n" }
            out += trimmed
            existing.insert(trimmed)
            added += 1
        }
        if added > 0 {
            try out.write(to: url, atomically: true, encoding: .utf8)
            let count = out.split(whereSeparator: \.isNewline).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
            }.count
            UserDefaults(suiteName: AppGroupConstants.suiteName)?
                .set(count, forKey: AppGroupConstants.psiphonServerEntriesLineCountKey)
            SharedLogger.shared.logRaw(
                "SERVER_ENTRIES_MERGED",
                detail: "added=\(added) total=\(count)"
            )
        }
        return added
    }
}

extension SharedSettingsStore {
    var psiphonServerEntriesFileURLForMerge: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName)?
            .appendingPathComponent(AppGroupConstants.psiphonServerEntriesFileName)
    }

    /// Bundled lines + optional gitignored supplement (from Tooling fetch script).
    static func mergedBundledServerEntriesText() -> String? {
        let primary = "psiphon-embedded-server-entries"
        let supplement = "psiphon-embedded-server-entries.remote-supplement"
        var lines: [String] = []
        for name in [primary, supplement] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty, !s.hasPrefix("#") {
                    lines.append(s)
                }
            }
        }
        guard !lines.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        return unique.joined(separator: "\n")
    }
}
