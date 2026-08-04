import Foundation


/// Logs Telegram / WhatsApp DNS, routing, and transport diagnostics (no secrets).
enum MessagingAppsDiagnostics {
  static func logCompatibilityStartup(
    settings: AppSettings,
    excludedRoutes: [BypassRoute],
    mtu: Int,
    packetEngineCapabilities: PacketEngineCapabilities = .ipv4Only
  ) {
    let compat = settings.messagingAppsCompatibilityModeEnabled
    let overlays = MessagingAppsConfiguration.usesMessagingOverlays(settings)
    let effective = MessagingAppsConfiguration.tunnelSettings(from: settings)
    let routePlan = PacketEngineRoutePlan.fullTunnel(for: packetEngineCapabilities)
    SharedLogger.shared.logRaw(
      "MESSAGING_COMPAT_STATUS",
      detail: [
        "enabled=\(compat)",
        "overlays=\(overlays)",
        "mtu=\(mtu)",
        "secure_dns=\(effective.secureDNSMode.rawValue)",
        "bypass_iran=\(settings.bypassIranIPsEnabled)",
        "excluded_routes=\(excludedRoutes.count)",
        "udp_relay=native_packet",
        "ipv6_relay=\(packetEngineCapabilities.logValue)",
        "ipv6_policy=\(routePlan.installsIPv6DefaultRoute ? "engine_relay" : "capture_icmpv6_reject_and_aaaa_suppress")",
      ].joined(separator: " ")
    )
    if overlays {
      SharedLogger.shared.logRaw(
        "MESSAGING_COMPAT_ACTIVE",
        detail: "mtu=\(mtu) secure_dns=\(effective.secureDNSMode.rawValue) provider=\(effective.secureDNSProvider.rawValue)"
      )
    }
  }

  static func logTcpRelay(
    host: String,
    port: UInt16,
    ok: Bool,
    error: String? = nil,
    stage: String = "connected"
  ) {
    guard MessagingAppsConfiguration.isMessagingTcpEndpoint(host: host, port: port) else { return }
    let app = MessagingAppsConfiguration.messagingApp(host: host, port: port).rawValue
    let event = ok ? "MESSAGING_TCP_RELAY_OK" : "MESSAGING_TCP_RELAY_FAIL"
    SharedLogger.shared.logRaw(
      event,
      detail: "app=\(app) stage=\(stage) dest=\(host):\(port)\(error.map { " reason=\($0)" } ?? "")"
    )
  }

  static func logRelayGateRejected(host: String, port: UInt16) {
    let app = MessagingAppsConfiguration.messagingApp(host: host, port: port).rawValue
    SharedLogger.shared.logRaw(
      "MESSAGING_TCP_RELAY_GATE_FULL",
      detail: "app=\(app) dest=\(host):\(port) reason=parallel_socks_limit"
    )
  }

}
