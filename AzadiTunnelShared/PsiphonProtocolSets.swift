import Foundation

/// Tunnel protocol names aligned with Shiro Khorshid Android `TunnelManager.java`.
enum PsiphonProtocolSets {
    /// Direct (non-fronted, non-in-proxy) — `DIRECT_TUNNEL_PROTOCOLS` subset used for direct mode.
    static let direct: [String] = [
        "SSH",
        "OSSH",
        "TLS-OSSH",
        "UNFRONTED-MEEK-OSSH",
        "UNFRONTED-MEEK-HTTPS-OSSH",
        "UNFRONTED-MEEK-SESSION-TICKET-OSSH",
        "QUIC-OSSH",
        "SHADOWSOCKS-OSSH",
        "FRONTED-MEEK-OSSH",
        "FRONTED-MEEK-CDN-OSSH",
        "FRONTED-MEEK-HTTP-OSSH",
        "FRONTED-MEEK-CDN-HTTP-OSSH",
        "FRONTED-MEEK-QUIC-OSSH",
        "FRONTED-MEEK-CDN-QUIC-OSSH"
    ]

    /// CDN fronting transport mode — Shiro's complete three-protocol set.
    static let cdnFronting: [String] = PsiphonShiroCDNFrontingConfig.cdnFrontingModeProtocols

    /// TCP-only fronting is attempted first on restrictive networks. QUIC remains available in
    /// the final compatibility attempt instead of occupying aggressive workers on every attempt.
    static let cdnFrontingTCP: [String] = [
        "FRONTED-MEEK-CDN-OSSH",
        "FRONTED-MEEK-CDN-HTTP-OSSH"
    ]

    /// Conduit / in-proxy — `CONDUIT_TUNNEL_PROTOCOLS`.
    static let conduit: [String] = [
        "INPROXY-WEBRTC-SSH",
        "INPROXY-WEBRTC-OSSH",
        "INPROXY-WEBRTC-TLS-OSSH",
        "INPROXY-WEBRTC-UNFRONTED-MEEK-OSSH",
        "INPROXY-WEBRTC-UNFRONTED-MEEK-HTTPS-OSSH",
        "INPROXY-WEBRTC-UNFRONTED-MEEK-SESSION-TICKET-OSSH",
        "INPROXY-WEBRTC-FRONTED-MEEK-OSSH",
        "INPROXY-WEBRTC-FRONTED-MEEK-HTTP-OSSH",
        "INPROXY-WEBRTC-QUIC-OSSH",
        "INPROXY-WEBRTC-FRONTED-MEEK-QUIC-OSSH",
        "INPROXY-WEBRTC-SHADOWSOCKS-OSSH"
    ]

    static func limits(for selection: AppSettings.ProtocolSelection) -> [String]? {
        switch selection {
        case .auto:
            return nil
        case .direct:
            return direct
        case .cdnFronting:
            return cdnFronting
        case .conduit:
            return conduit
        }
    }

    /// Expected `LimitTunnelProtocols` for unit checks / Scripts/verify-protocol-parity.py.
    static func expectedLimitJSON(for settings: AppSettings) -> [String]? {
        var limits = limits(for: settings.protocolSelection)
        if settings.protocolSelection == .cdnFronting {
            switch settings.cdnFrontingAttemptStrategy {
            case .dynamicTCP, .staticTCP:
                limits = cdnFrontingTCP
            case .staticAll, nil:
                limits = cdnFronting
            }
        }
        if settings.beastModeEnabled && settings.protocolSelection == .auto {
            limits = nil
        }
        return limits
    }
}
