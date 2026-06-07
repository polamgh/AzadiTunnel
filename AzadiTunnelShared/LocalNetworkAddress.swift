import Foundation
import Darwin

/// Resolves the device's Wi-Fi IPv4 address by walking BSD `getifaddrs()` for `en0`.
///
/// `en0` is the canonical Wi-Fi interface on iPhone/iPad. We deliberately skip cellular
/// (`pdp_ip*`), VPN (`utun*`), and link-local addresses so the LAN proxy only ever advertises
/// an address other Wi-Fi devices can reach.
enum LocalNetworkAddress {
    /// IPv4 address bound to `en0`, or `nil` if Wi-Fi is unreachable.
    static func wifiIPv4() -> String? {
        return ipv4(forInterface: "en0")
    }

    static func ipv4(forInterface name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let ifa = ptr.pointee
            guard let cname = ifa.ifa_name else { continue }
            let ifaceName = String(cString: cname)
            guard ifaceName == name else { continue }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var sockaddrIn = sockaddr_in()
            memcpy(&sockaddrIn, addr, MemoryLayout<sockaddr_in>.size)
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result = withUnsafePointer(to: &sockaddrIn.sin_addr) { ptrIn -> String? in
                guard inet_ntop(AF_INET, ptrIn, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: ipBuffer)
            }
            if let ip = result,
               !ip.hasPrefix("127."),
               !ip.hasPrefix("169.254.") {
                return ip
            }
        }
        return nil
    }
}
