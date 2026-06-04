import Foundation

/// Parses Psiphon in-proxy / Conduit diagnostics for dashboard display (Shiro `TunnelManager` parity).
enum ConduitStatusParser {
    private static let maxHistory = 8

    /// Returns a user-visible line if `message` describes a Conduit attempt; nil otherwise.
    static func parseDashboardLine(from message: String) -> String? {
        if message.contains("CandidateServers:") {
            return parseCandidateServersNotice(message)
        }
        if message.contains("RequestingTactics") || message.contains("RequestedTactics") {
            return "Waiting for Psiphon tactics (skipped when DisableTactics is on)…"
        }
        if let notice = parseInfoMessageField(message) {
            return notice
        }
        if let relay = parseTryingRelay(message) {
            return relay
        }
        if let connected = parseConduitConnected(message) {
            return connected
        }
        if let dial = parseInproxyDial(message) {
            return dial
        }
        if let broker = parseBrokerLine(message) {
            return broker
        }
        if let verify = parseSignatureVerificationFailure(message) {
            return verify
        }
        return nil
    }

    static func appendHistory(_ line: String, to stats: inout TunnelStatistics) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if stats.conduitStatusLine == trimmed {
            return false
        }
        if !stats.conduitStatusLine.isEmpty {
            stats.conduitStatusHistory.insert(stats.conduitStatusLine, at: 0)
            if stats.conduitStatusHistory.count > maxHistory {
                stats.conduitStatusHistory.removeLast(stats.conduitStatusHistory.count - maxHistory)
            }
        }
        stats.conduitStatusLine = trimmed
        stats.conduitStatusUpdatedAt = Date()
        return true
    }

    // MARK: - Shiro patterns

    private static func parseTryingRelay(_ message: String) -> String? {
        guard message.contains("trying Conduit relay (country:") else { return nil }
        guard let match = message.range(
            of: #"\(country: ([A-Z]{2})\)"#,
            options: .regularExpression
        ) else { return nil }
        let snippet = String(message[match])
        let code = snippet
            .replacingOccurrences(of: "(country: ", with: "")
            .replacingOccurrences(of: ")", with: "")
        let country = RegionDisplayNames.countryName(for: code)
        return "Trying Conduit relay (\(country))"
    }

    private static func parseConduitConnected(_ message: String) -> String? {
        if message.contains("tunnel connected via Conduit relay (protocol:"),
           message.contains("country:"),
           let match = message.range(
               of: #"\(protocol: ([^,]+), country: ([A-Z]{2})\)"#,
               options: .regularExpression
           ) {
            let inner = String(message[match])
                .replacingOccurrences(of: "(protocol: ", with: "")
                .replacingOccurrences(of: ")", with: "")
            let parts = inner.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 {
                let proto = ConnectedTunnelProtocolParser.displayName(for: String(parts[0]))
                let country = RegionDisplayNames.countryName(
                    for: String(parts[1].replacingOccurrences(of: "country: ", with: ""))
                )
                return "Connected via Conduit (\(proto), \(country))"
            }
        }
        if message.contains("tunnel connected via Conduit relay (protocol:"),
           let match = message.range(
               of: #"\(protocol: ([^)]+)\)"#,
               options: .regularExpression
           ) {
            let protoRaw = String(message[match])
                .replacingOccurrences(of: "(protocol: ", with: "")
                .replacingOccurrences(of: ")", with: "")
            let proto = ConnectedTunnelProtocolParser.displayName(for: protoRaw)
            return "Connected via Conduit (\(proto))"
        }
        return nil
    }

    private static func parseInfoMessageField(_ message: String) -> String? {
        guard let data = extractJSONObject(from: message),
              let msg = data["message"] as? String, !msg.isEmpty else {
            if message.contains("CandidateServers") {
                return parseCandidateServersNotice(message)
            }
            return nil
        }
        if msg.hasPrefix("inproxy-dial:") {
            return parseInproxyDial(message)
        }
        if msg.contains("inproxy: selected broker") {
            return "In-proxy broker selected"
        }
        if msg.lowercased().contains("in-proxy protocol selection") {
            return "Selecting in-proxy protocol…"
        }
        if msg.contains("trying Conduit relay") {
            return parseTryingRelay(msg) ?? msg
        }
        return nil
    }

    private static func parseCandidateServersNotice(_ message: String) -> String? {
        var jsonStr = message
        if let range = message.range(of: "CandidateServers:") {
            let after = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
            jsonStr = after.hasPrefix("{") ? String(after) : message
        }
        guard let data = extractJSONObject(from: jsonStr) ?? extractJSONObject(from: message) else { return nil }
        if let count = data["count"] as? Int, count > 0 {
            let duration = formatGoDuration(data["duration"] as? String) ?? ""
            if duration.isEmpty {
                return "Loaded \(count) server candidates"
            }
            return "Loaded \(count) server candidates (\(duration))"
        }
        return "Loading server candidates…"
    }

    private static func extractJSONObject(from message: String) -> [String: Any]? {
        var jsonStr = message
        if let range = message.range(of: ": {") {
            jsonStr = String(message[range.upperBound...])
        } else if let range = message.range(of: ":{") {
            jsonStr = String(message[range.upperBound...])
        } else if message.trimmingCharacters(in: .whitespaces).first == "{" {
            jsonStr = message
        } else {
            return nil
        }
        guard let data = jsonStr.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func parseSignatureVerificationFailure(_ message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("verifysignature") && lower.contains("missing public key") {
            return PsiphonDistributorKeys.conduitBlockedStatusLine
        }
        if lower.contains("missing_distributor_keys") {
            return PsiphonDistributorKeys.conduitBlockedStatusLine
        }
        if lower.contains("failed to make dial parameters") {
            if lower.contains("missing public key") || lower.contains("verifysignature") {
                return PsiphonDistributorKeys.conduitBlockedStatusLine
            }
            return "Conduit dial failed (check distributor keys in config)"
        }
        return nil
    }

    private static func parseBrokerLine(_ message: String) -> String? {
        let lower = message.lowercased()
        guard lower.contains("inproxy") || lower.contains("in-proxy") else { return nil }
        if lower.contains("selected broker") {
            return "In-proxy broker selected"
        }
        if lower.contains("broker") {
            if lower.contains("404") {
                return "In-proxy broker unreachable (404)"
            }
            if lower.contains("roundtripper") {
                return "Contacting in-proxy broker…"
            }
            return "In-proxy broker…"
        }
        if lower.contains("protocol selection") {
            return "Selecting in-proxy protocol…"
        }
        if message.contains("CandidateServers") {
            return parseCandidateServersNotice(message)
        }
        return nil
    }

    /// Shiro `parseInproxyDiagnostic` — `inproxy-dial: …` JSON notices.
    private static func parseInproxyDial(_ message: String) -> String? {
        guard message.contains("inproxy-dial:") else { return nil }

        var jsonStr = message
        if let range = message.range(of: ": {") {
            jsonStr = String(message[range.upperBound...])
        } else if let range = message.range(of: ":{") {
            jsonStr = String(message[range.upperBound...])
        }

        if let data = jsonStr.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let msg = object["message"] as? String ?? ""
            guard msg.hasPrefix("inproxy-dial:") else { return fallbackInproxyPhase(message) }
            let phase = String(msg.dropFirst("inproxy-dial: ".count))
            var sb = ""
            if let attempt = object["attempt"] as? String, !attempt.isEmpty {
                sb += "#\(attempt) "
            } else if let attemptNum = object["attempt"] as? Int {
                sb += "#\(attemptNum) "
            }
            sb += phase
            if let duration = formatGoDuration(object["duration"] as? String) {
                sb += " (\(duration))"
            }
            if let timeout = formatGoDuration(object["timeout"] as? String) {
                sb += " [timeout=\(timeout)]"
            }
            if let nat = object["natType"] as? String, !nat.isEmpty {
                sb += " [NAT=\(nat)]"
            }
            if var error = object["error"] as? String, !error.isEmpty {
                if error.count > 120 {
                    error = String(error.prefix(120)) + "…"
                }
                sb += " | \(error)"
            }
            return sb.isEmpty ? nil : sb
        }
        return fallbackInproxyPhase(message)
    }

    private static func fallbackInproxyPhase(_ message: String) -> String? {
        guard let idx = message.range(of: "inproxy-dial: ") else { return nil }
        var remainder = String(message[idx.upperBound...])
        if let end = remainder.range(of: "\",") ?? remainder.range(of: "\"}") {
            remainder = String(remainder[..<end.lowerBound])
        }
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatGoDuration(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") {
            let num = raw.dropLast(2)
            if let ms = Double(num) {
                return String(format: "%.0fms", ms)
            }
        }
        if raw.hasSuffix("s"), !raw.hasSuffix("ms") {
            let mIdx = raw.firstIndex(of: "m")
            let prefix: String
            let secPart: String
            if let mIdx {
                prefix = String(raw[...mIdx])
                secPart = String(raw[raw.index(after: mIdx)..<raw.index(before: raw.endIndex)])
            } else {
                prefix = ""
                secPart = String(raw.dropLast())
            }
            if let secs = Double(secPart) {
                if secs < 10 {
                    return prefix + String(format: "%.1fs", secs)
                }
                return prefix + String(format: "%.0fs", secs)
            }
        }
        if raw.contains("µs") || raw.contains("us") {
            return "<1ms"
        }
        return raw
    }
}
