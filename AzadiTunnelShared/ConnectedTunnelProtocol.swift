import Foundation

/// Parses Psiphon `ConnectedServer` notices and maps tunnel protocol IDs to short UI labels (Shiro-style).
enum ConnectedTunnelProtocolParser {
    static func extractProtocol(from diagnosticMessage: String) -> String? {
        let trimmed = diagnosticMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.localizedCaseInsensitiveContains("connectedserver") else { return nil }

        if let json = jsonPayload(from: trimmed),
           let proto = json["protocol"] as? String,
           !proto.isEmpty {
            return proto
        }

        if let proto = regexCapture(#""protocol"\s*:\s*"([^"]+)""#, in: trimmed), !proto.isEmpty {
            return proto
        }
        return nil
    }

    /// Short label shown on the dashboard (e.g. OSSH → SSH, TLS-OSSH → TLS).
    static func displayName(for rawProtocol: String) -> String {
        let p = rawProtocol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "" }

        if p.hasPrefix("INPROXY-WEBRTC-") {
            let inner = String(p.dropFirst("INPROXY-WEBRTC-".count))
            let innerLabel = displayName(for: inner.isEmpty ? p : inner)
            return innerLabel.isEmpty ? "Conduit" : "Conduit · \(innerLabel)"
        }

        switch p {
        case "SSH", "OSSH":
            return "SSH"
        case "TLS-OSSH":
            return "TLS"
        case "QUIC-OSSH":
            return "QUIC"
        case "SHADOWSOCKS-OSSH":
            return "Shadowsocks"
        case "FRONTED-MEEK-OSSH", "FRONTED-MEEK-HTTP-OSSH", "FRONTED-MEEK-QUIC-OSSH":
            return "Meek"
        case "FRONTED-MEEK-CDN-OSSH", "FRONTED-MEEK-CDN-HTTP-OSSH", "FRONTED-MEEK-CDN-QUIC-OSSH":
            return "CDN Meek"
        case "UNFRONTED-MEEK-OSSH", "UNFRONTED-MEEK-HTTPS-OSSH", "UNFRONTED-MEEK-SESSION-TICKET-OSSH":
            return "Meek"
        default:
            if p.hasSuffix("-OSSH") {
                return String(p.dropLast("-OSSH".count))
            }
            return p
        }
    }

    private static func jsonPayload(from message: String) -> [String: Any]? {
        if let brace = message.firstIndex(of: "{") {
            let jsonText = String(message[brace...])
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let dataField = obj["data"] as? [String: Any] {
                    return dataField
                }
                return obj
            }
        }
        return nil
    }

    private static func regexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }
}
