import Foundation

/// Tunnel protocol names aligned with Shiro Khorshid Android `TunnelManager.java`.
enum PsiphonProtocolSets {
    /// Direct — Android `DIRECT_TUNNEL_PROTOCOLS` (classic fronted meek only; no CDN-family).
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
        "FRONTED-MEEK-HTTP-OSSH",
        "FRONTED-MEEK-QUIC-OSSH"
    ]

    /// CDN fronting — Android `CDN_FRONTING_TUNNEL_PROTOCOLS`.
    static let cdnFronting: [String] = PsiphonShiroCDNFrontingConfig.cdnFrontingModeProtocols

    /// Conduit / in-proxy — Android `CONDUIT_TUNNEL_PROTOCOLS`.
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
        if settings.beastModeEnabled && settings.protocolSelection == .auto {
            return nil
        }
        return limits(for: settings.protocolSelection)
    }
}
