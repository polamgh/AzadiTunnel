import Foundation

/// Telegram / WhatsApp helpers for routing, DNS, and compatibility mode.
enum MessagingAppsConfiguration {
  static let protectedDomains: [String] = [
    "telegram.org",
    "t.me",
    "web.telegram.org",
    "cdn-telegram.org",
    "whatsapp.com",
    "whatsapp.net",
    "mmg.whatsapp.net",
    "facebook.com",
    "fbcdn.net",
    "fbsbx.com",
    "edge-mqtt.facebook.com",
    "gateway.facebook.com",
    "mqtt.c10r.facebook.com",
    "dgw.c10r.facebook.com",
    "dit.whatsapp.net",
    "api.whatsapp.net",
    "g-fallback.whatsapp.net",
    "graph.whatsapp.com",
  ]

  /// WhatsApp endpoints that often return CNAME-only from some DoH providers (e.g. g.whatsapp.net).
  static let whatsappDiagnosticDomains: [String] = [
    "g.whatsapp.net",
    "chat.whatsapp.com",
    "web.whatsapp.com",
    "whatsapp.net",
    "mmg.whatsapp.net",
    "edge-mqtt.facebook.com",
    "gateway.facebook.com",
    "mqtt.c10r.facebook.com",
    "dgw.c10r.facebook.com",
    "dit.whatsapp.net",
    "api.whatsapp.net",
    "g-fallback.whatsapp.net",
    "graph.whatsapp.com",
  ]

  /// Messaging overlays (lower MTU, IPv4-only DNS, longer relay timeouts) when Secure DNS is active.
  static func usesMessagingOverlays(_ settings: AppSettings) -> Bool {
    SecureDNSConfiguration.isActive(settings)
  }

  static func isWhatsAppDomain(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !normalized.isEmpty else { return false }
    return normalized == "whatsapp.com"
      || normalized.hasSuffix(".whatsapp.com")
      || normalized == "whatsapp.net"
      || normalized.hasSuffix(".whatsapp.net")
      || normalized == "facebook.com"
      || normalized.hasSuffix(".facebook.com")
      || normalized == "fbcdn.net"
      || normalized.hasSuffix(".fbcdn.net")
      || normalized == "fbsbx.com"
      || normalized.hasSuffix(".fbsbx.com")
  }

  static func needsMessagingDnsFallback(qname: String, ipv4Answers: [String]) -> Bool {
    isWhatsAppDomain(qname) && ipv4Answers.isEmpty
  }

  /// Nudge Telegram/WhatsApp clients toward IPv4 (especially with Secure DNS + CDN Meek).
  static func prefersIPv4Only(settings: AppSettings, qname: String) -> Bool {
    guard usesMessagingOverlays(settings) else { return false }
    return isProtectedDomain(qname) || isWhatsAppDomain(qname)
  }

  static func dnsProviderFallbackChain(primary: SecureDNSProvider, qname: String? = nil) -> [SecureDNSProvider] {
    if let qname, isWhatsAppDomain(qname) || isProtectedDomain(qname) {
      // Google DoH tends to return usable A records for Meta MQTT/gateway hosts faster than Cloudflare.
      var chain: [SecureDNSProvider] = [.google]
      if primary != .google { chain.append(primary) }
      for candidate in [SecureDNSProvider.cloudflare, .quad9, .adguard] {
        if !chain.contains(candidate) { chain.append(candidate) }
      }
      return chain
    }
    var chain: [SecureDNSProvider] = [primary]
    for candidate in [SecureDNSProvider.google, .quad9, .cloudflare, .adguard] {
      if !chain.contains(candidate) { chain.append(candidate) }
    }
    return chain
  }

  enum MessagingApp: String, Equatable {
    case telegram
    case whatsapp
    case messaging
    case other
  }

  /// Telegram DC IPv4 ranges (checked before Meta/WhatsApp).
  private static let telegramCIDRs: [(network: UInt32, mask: UInt32)] = [
    (ipv4ToUInt32(149, 154, 160, 0), maskForPrefix(20)), // 149.154.160.0/20
    (ipv4ToUInt32(91, 108, 4, 0), maskForPrefix(22)),    // 91.108.4.0/22
    (ipv4ToUInt32(91, 108, 8, 0), maskForPrefix(22)),    // 91.108.8.0/22
    (ipv4ToUInt32(91, 108, 12, 0), maskForPrefix(22)),   // 91.108.12.0/22
    (ipv4ToUInt32(91, 108, 16, 0), maskForPrefix(22)),   // 91.108.16.0/22
    (ipv4ToUInt32(91, 108, 56, 0), maskForPrefix(22)),   // 91.108.56.0/22
    (ipv4ToUInt32(109, 239, 140, 0), maskForPrefix(24)), // 109.239.140.0/24
  ]

  /// Meta / WhatsApp IPv4 prefixes (must not overlap Telegram classification).
  private static let whatsappIPv4Prefixes: [String] = [
    "31.13.",
    "157.240.",
    "179.43.",
    "57.144.",
    "163.70.",
  ]

  /// Legacy helper list (Telegram + Meta) for bypass route filtering.
  static let protectedIPv4Prefixes: [String] = [
    "149.154.",
    "91.108.",
    "95.161.",
    "109.239.140.",
  ] + whatsappIPv4Prefixes

  /// WhatsApp / Telegram TCP ports (chat, HTTPS fallback).
  static let messagingTcpPorts: Set<UInt16> = [
    80, 443, 5222, 5223, 5228, 5242,
  ]

  static func isTelegramIPv4(_ ip: String) -> Bool {
    guard let value = parseIPv4UInt32(ip) else { return false }
    return telegramCIDRs.contains { (value & $0.mask) == $0.network }
  }

  static func isWhatsAppIPv4(_ ip: String) -> Bool {
    whatsappIPv4Prefixes.contains { ip.hasPrefix($0) }
  }

  /// Classify a TCP destination; Telegram ranges win over Meta when both could match.
  static func messagingApp(host: String, port: UInt16) -> MessagingApp {
    if isTelegramIPv4(host) { return .telegram }
    if isWhatsAppIPv4(host) { return .whatsapp }
    if messagingTcpPorts.contains(port) { return .messaging }
    return .other
  }

  static func isMessagingTcpEndpoint(host: String, port: UInt16) -> Bool {
    switch messagingApp(host: host, port: port) {
    case .telegram, .whatsapp, .messaging: return true
    case .other: return isProtectedIPv4(host)
    }
  }

  static func isWhatsAppEndpoint(host: String, port: UInt16) -> Bool {
    messagingApp(host: host, port: port) == .whatsapp
  }

  private static func parseIPv4UInt32(_ ip: String) -> UInt32? {
    let parts = ip.split(separator: ".")
    guard parts.count == 4,
          let a = UInt32(parts[0]), a <= 255,
          let b = UInt32(parts[1]), b <= 255,
          let c = UInt32(parts[2]), c <= 255,
          let d = UInt32(parts[3]), d <= 255 else { return nil }
    return ipv4ToUInt32(UInt8(a), UInt8(b), UInt8(c), UInt8(d))
  }

  private static func ipv4ToUInt32(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
    (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
  }

  private static func maskForPrefix(_ prefix: Int) -> UInt32 {
    prefix == 0 ? 0 : UInt32.max << (32 - prefix)
  }

  struct SocksRelayTimeouts: Equatable {
    var ready: TimeInterval
    var method: TimeInterval
    var connectReply: TimeInterval
    /// Per-chunk read timeout in relay pump; nil = wait indefinitely (long-lived chat).
    var receiveChunk: TimeInterval?
    /// Logged label for diagnostics.
    var profile: String
  }

  static func socksRelayTimeouts(for host: String, port: UInt16) -> SocksRelayTimeouts {
    let messaging = isMessagingTcpEndpoint(host: host, port: port)
    let compat = usesMessagingOverlays(SharedSettingsStore.shared.appSettings)
    if messaging {
      // Long-lived chat/media sockets must not use the 8s default read timeout.
      let connect: TimeInterval
      if port == 5222 || port == 5223 {
        connect = compat ? 60 : 45
      } else if port == 443 || port == 80 {
        connect = compat ? 45 : 35
      } else {
        connect = compat ? 35 : 30
      }
      return SocksRelayTimeouts(
        ready: compat ? 15 : 12,
        method: compat ? 10 : 8,
        connectReply: connect,
        receiveChunk: nil,
        profile: compat ? "messaging_compat" : "messaging"
      )
    }
    return SocksRelayTimeouts(
      ready: 5,
      method: 5,
      connectReply: 8,
      receiveChunk: 8,
      profile: "default"
    )
  }

  static func isProtectedDomain(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !normalized.isEmpty else { return false }
    return protectedDomains.contains { domain in
      normalized == domain || normalized.hasSuffix(".\(domain)")
    }
  }

  static func isProtectedIPv4(_ ip: String) -> Bool {
    protectedIPv4Prefixes.contains { ip.hasPrefix($0) }
  }

  /// Overlay applied inside the tunnel when compatibility mode is on (or Secure DNS needs messaging-friendly MTU/DNS).
  static func tunnelSettings(from base: AppSettings) -> AppSettings {
    guard usesMessagingOverlays(base) else { return base }
    var overlay = base
    if overlay.secureDNSMode == .off {
      overlay.secureDNSMode = .doh
      overlay.secureDNSProvider = .cloudflare
      overlay.blockCleartextDNS = false
    }
    return overlay
  }

  static func tunnelMTU(for settings: AppSettings) -> Int {
    guard usesMessagingOverlays(settings) else { return 1500 }
    return settings.messagingAppsTunnelMTU.rawValue
  }

  /// Remove messaging destinations from bypass excluded routes when messaging overlays are active.
  static func filterExcludedRoutes(
    _ routes: [BypassRoute],
    compatibilityMode: Bool
  ) -> (filtered: [BypassRoute], removed: [BypassRoute]) {
    guard compatibilityMode else { return (routes, []) }
    var kept: [BypassRoute] = []
    var removed: [BypassRoute] = []
    for route in routes {
      if routeWouldBypassMessaging(route) {
        removed.append(route)
      } else {
        kept.append(route)
      }
    }
    return (kept, removed)
  }

  private static let routeProbeIPs = [
    "149.154.167.99",
    "91.108.56.100",
    "31.13.80.53",
    "157.240.0.1",
  ]

  private static func routeWouldBypassMessaging(_ route: BypassRoute) -> Bool {
    if isProtectedIPv4(route.address) { return true }
    return routeProbeIPs.contains { BypassRoutes.contains(ip: $0, in: route) }
  }

  static func routeDecision(for ip: String, excluded: [BypassRoute]) -> String {
    guard BypassRoutes.isValidIPv4(ip) else { return "unknown" }
    for route in excluded where BypassRoutes.contains(ip: ip, in: route) {
      return "bypass"
    }
    return "tunnel"
  }
}

enum MessagingTunnelMTU: Int, Codable, CaseIterable, Identifiable {
  case compat1200 = 1200
  case compat1240 = 1240
  case compat1280 = 1280
  case compat1400 = 1400
  case standard1500 = 1500

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .compat1200: return "1200 (aggressive)"
    case .compat1240: return "1240"
    case .compat1280: return "1280"
    case .compat1400: return "1400"
    case .standard1500: return "1500"
    }
  }
}
