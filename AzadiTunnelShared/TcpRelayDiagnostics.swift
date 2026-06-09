import Foundation

/// Structured logging for tun2socks → SOCKS5 → Psiphon relay paths (messaging apps).
enum TcpRelayDiagnostics {
    struct SessionContext: Sendable {
        let sessionId: UInt64
        let destHost: String
        let destPort: UInt16
        let app: String

        init(destHost: String, destPort: UInt16) {
            self.sessionId = UInt64.random(in: 1...UInt64.max)
            self.destHost = destHost
            self.destPort = destPort
            switch MessagingAppsConfiguration.messagingApp(host: destHost, port: destPort) {
            case .telegram: app = "telegram"
            case .whatsapp: app = "whatsapp"
            case .messaging: app = "messaging"
            case .other: app = "other"
            }
        }

        private var base: String {
            "sid=\(sessionId) app=\(app) dest=\(destHost):\(destPort)"
        }

        func log(_ event: String, detail: String) {
            SharedLogger.shared.logRaw(event, detail: "\(base) \(detail)")
        }
    }

    static func logTunAccept(host: String, port: UInt16) {
        guard MessagingAppsConfiguration.isMessagingTcpEndpoint(host: host, port: port) else { return }
        let app = MessagingAppsConfiguration.messagingApp(host: host, port: port).rawValue
        SharedLogger.shared.logRaw(
            "TCP_RELAY_TUN_ACCEPT",
            detail: "app=\(app) dest=\(host):\(port)"
        )
    }
}
