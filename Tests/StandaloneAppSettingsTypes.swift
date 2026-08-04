#if SECURE_DNS_STANDALONE_TEST
import Foundation

enum SecureDNSMode: String, Codable {
    case doh
    case off
    case dot
}

enum SecureDNSProvider: String, Codable {
    case cloudflare
    case google
    case quad9
    case adguard
    case custom
}

enum MessagingTunnelMTU: Int, Codable {
    case compat1280 = 1280
}
#endif
