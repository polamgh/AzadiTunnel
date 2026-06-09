import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Logs Telegram / WhatsApp DNS, routing, and transport diagnostics (no secrets).
enum MessagingAppsDiagnostics {
  static func logCompatibilityStartup(
    settings: AppSettings,
    excludedRoutes: [BypassRoute],
    mtu: Int
  ) {
    let compat = settings.messagingAppsCompatibilityModeEnabled
    let effective = MessagingAppsConfiguration.tunnelSettings(from: settings)
    SharedLogger.shared.logRaw(
      "MESSAGING_COMPAT_STATUS",
      detail: [
        "enabled=\(compat)",
        "mtu=\(mtu)",
        "secure_dns=\(effective.secureDNSMode.rawValue)",
        "bypass_iran=\(settings.bypassIranIPsEnabled)",
        "excluded_routes=\(excludedRoutes.count)",
        "udp_relay=tcp_only",
        "ipv6_relay=none",
        "ipv6_policy=\(compat ? "blackhole" : "none")",
      ].joined(separator: " ")
    )
    if compat {
      SharedLogger.shared.logRaw(
        "MESSAGING_COMPAT_ACTIVE",
        detail: "mtu=\(mtu) secure_dns=\(effective.secureDNSMode.rawValue) provider=\(effective.secureDNSProvider.rawValue)"
      )
    }
  }

  static func runDomainChecks(excludedRoutes: [BypassRoute]) {
    var domains: [String] = []
    var seen = Set<String>()
    for domain in MessagingAppsConfiguration.protectedDomains + MessagingAppsConfiguration.whatsappDiagnosticDomains {
      guard seen.insert(domain).inserted else { continue }
      domains.append(domain)
    }
    for domain in domains {
      let ips = resolveIPv4(domain)
      let ipList = ips.isEmpty ? "unresolved" : ips.joined(separator: ",")
      SharedLogger.shared.logRaw(
        "MESSAGING_DNS_RESOLVED",
        detail: "domain=\(domain) ips=\(ipList)"
      )
      for ip in ips {
        let decision = MessagingAppsConfiguration.routeDecision(for: ip, excluded: excludedRoutes)
        SharedLogger.shared.logRaw(
          "MESSAGING_ROUTE_DECISION",
          detail: "domain=\(domain) ip=\(ip) route=\(decision)"
        )
      }
      if ips.isEmpty {
        SharedLogger.shared.logRaw(
          "MESSAGING_ROUTE_DECISION",
          detail: "domain=\(domain) ip=none route=unknown"
        )
      }
    }
  }

  static func logDnsAnswer(
    domain: String,
    ips: [String],
    secure: Bool,
    provider: SecureDNSProvider? = nil
  ) {
    guard MessagingAppsConfiguration.isProtectedDomain(domain)
      || MessagingAppsConfiguration.isWhatsAppDomain(domain) else { return }
    let list = ips.isEmpty ? "none" : ips.joined(separator: ",")
    let providerToken = provider.map { " provider=\($0.rawValue)" } ?? ""
    SharedLogger.shared.logRaw(
      "MESSAGING_DNS_ANSWER",
      detail: "domain=\(domain) ips=\(list) secure=\(secure)\(providerToken)"
    )
    if MessagingAppsConfiguration.isWhatsAppDomain(domain) {
      SharedLogger.shared.logRaw(
        "WHATSAPP_DNS_ANSWER",
        detail: "domain=\(domain) ips=\(list) secure=\(secure)\(providerToken)"
      )
      if ips.isEmpty {
        SharedLogger.shared.logRaw(
          "WHATSAPP_DNS_EMPTY_ANSWER",
          detail: "domain=\(domain)\(providerToken)"
        )
      }
    }
    for ip in ips {
      SharedLogger.shared.logRaw(
        "MESSAGING_DNS_RESOLVED",
        detail: "domain=\(domain) ip=\(ip) source=tunnel_dns"
      )
    }
  }

  static func logDnsProviderFallback(
    domain: String,
    from: SecureDNSProvider,
    to: SecureDNSProvider,
    reason: String
  ) {
    SharedLogger.shared.logRaw(
      "MESSAGING_DNS_PROVIDER_FALLBACK",
      detail: "domain=\(domain) from=\(from.rawValue) to=\(to.rawValue) reason=\(reason)"
    )
    if MessagingAppsConfiguration.isWhatsAppDomain(domain) {
      SharedLogger.shared.logRaw(
        "WHATSAPP_DNS_PROVIDER_FALLBACK",
        detail: "domain=\(domain) from=\(from.rawValue) to=\(to.rawValue) reason=\(reason)"
      )
    }
  }

  static func logDnsCnameChase(domain: String, cname: String, provider: SecureDNSProvider) {
    SharedLogger.shared.logRaw(
      "MESSAGING_DNS_CNAME_CHASE",
      detail: "domain=\(domain) cname=\(cname) provider=\(provider.rawValue)"
    )
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

  static func logUdpDropped(destIP: String, destPort: UInt16, length: Int) {
    let messagingIP = MessagingAppsConfiguration.isProtectedIPv4(destIP)
    let notablePort = MessagingAppsConfiguration.notableUDPPorts.contains(destPort)
    guard messagingIP || notablePort else { return }
    SharedLogger.shared.logRaw(
      "MESSAGING_UDP_DROPPED",
      detail: "dest=\(destIP):\(destPort) len=\(length) reason=tun2socks_tcp_only messaging_ip=\(messagingIP)"
    )
  }

  static func logIpv6Dropped(length: Int) {
    SharedLogger.shared.logRaw(
      "MESSAGING_IPV6_DROPPED",
      detail: "len=\(length) reason=ipv6_not_relayed"
    )
  }

  private static func resolveIPv4(_ host: String) -> [String] {
#if canImport(Darwin)
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(host, nil, &hints, &result)
    defer { if let result { freeaddrinfo(result) } }
    guard code == 0, let chain = result else { return [] }
    var ips: [String] = []
    var seen = Set<String>()
    var cursor: UnsafeMutablePointer<addrinfo>? = chain
    while let node = cursor {
      if node.pointee.ai_family == AF_INET,
         let addr = node.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = addr.pointee.sin_addr
        inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: buffer)
        if seen.insert(ip).inserted { ips.append(ip) }
      }
      cursor = node.pointee.ai_next
    }
    return ips
#else
    return []
#endif
  }
}
