import Foundation
import os

/// Append-only shared log ring buffer in App Group. Never log secrets or full config bodies.
final class SharedLogger {
    static let shared = SharedLogger()
    private static let osLog = Logger(subsystem: "com.polamgh.ali.AzadiTunnel", category: "events")
    private let maxEntries = 4000
    private let queue = DispatchQueue(label: "com.polamgh.ali.AzadiTunnel.sharedlogger")

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    func log(_ event: SharedLogEvent, detail: String? = nil) {
        let line = Self.formatLine(event: event.rawValue, detail: detail)
        queue.sync {
            guard let defaults else { return }
            var lines = (defaults.stringArray(forKey: AppGroupConstants.sharedLogsKey) ?? [])
            lines.append(line)
            if lines.count > maxEntries {
                lines.removeFirst(lines.count - maxEntries)
            }
            defaults.set(lines, forKey: AppGroupConstants.sharedLogsKey)
        }
        Self.osLog.info("\(line, privacy: .public)")
    }

    func logRaw(_ event: String, detail: String? = nil) {
        let line = Self.formatLine(event: event, detail: detail)
        queue.sync {
            guard let defaults else { return }
            var lines = (defaults.stringArray(forKey: AppGroupConstants.sharedLogsKey) ?? [])
            lines.append(line)
            if lines.count > maxEntries {
                lines.removeFirst(lines.count - maxEntries)
            }
            defaults.set(lines, forKey: AppGroupConstants.sharedLogsKey)
        }
        Self.osLog.info("\(line, privacy: .public)")
    }

    func allLines() -> [String] {
        queue.sync {
            defaults?.stringArray(forKey: AppGroupConstants.sharedLogsKey) ?? []
        }
    }

    /// Full log text for copy/share (no secrets beyond what was already logged).
    func exportText() -> String {
        let lines = allLines()
        if lines.isEmpty {
            return "(no logs)"
        }
        return lines.joined(separator: "\n")
    }

    func clear() {
        queue.sync {
            defaults?.removeObject(forKey: AppGroupConstants.sharedLogsKey)
        }
    }

    private static func formatLine(event: String, detail: String?) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        if let detail, !detail.isEmpty {
            return "\(ts) \(event) \(detail)"
        }
        return "\(ts) \(event)"
    }
}
