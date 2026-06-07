import Foundation
import Darwin

/// Resolves bypass hostnames to IPv4 addresses and caches them in App Group storage so the
/// extension can add them as /32 excluded routes.
///
/// Domain bypass is inherently best-effort: CDN-backed hosts return many rotating IPs and the set
/// resolved here can drift from what the device later connects to. The UI warns about this.
enum BypassDomainResolver {
    /// Resolve each hostname, merge with the previous cache, and persist. Returns the fresh map.
    @discardableResult
    static func resolveAndCache(domains: [String]) async -> [String: [String]] {
        let store = SharedSettingsStore.shared
        let cleaned = domains
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !BypassRoutes.isValidIPv4($0) }

        guard !cleaned.isEmpty else {
            store.storeBypassDomainResolvedIPs([:])
            return [:]
        }

        var map: [String: [String]] = [:]
        for domain in Set(cleaned) {
            let ips = await resolveIPv4(domain)
            if ips.isEmpty {
                SharedLogger.shared.log(.bypassDomainFailed, detail: "domain=\(domain)")
            } else {
                map[domain] = ips
                SharedLogger.shared.log(.bypassDomainResolved, detail: "domain=\(domain) ips=\(ips.joined(separator: ","))")
            }
        }
        store.storeBypassDomainResolvedIPs(map)
        return map
    }

    /// Blocking `getaddrinfo` wrapped on a background thread.
    private static func resolveIPv4(_ host: String) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: synchronousResolve(host))
            }
        }
    }

    private static func synchronousResolve(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET, // IPv4 only — excludedRoutes here are NEIPv4Route
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var ips = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ai_next }
            guard let sa = node.pointee.ai_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addrIn = sockaddr_in()
            memcpy(&addrIn, sa, MemoryLayout<sockaddr_in>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if withUnsafePointer(to: &addrIn.sin_addr, { ptr in
                inet_ntop(AF_INET, ptr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }) != nil {
                let ip = String(cString: buffer)
                if BypassRoutes.isValidIPv4(ip) { ips.insert(ip) }
            }
        }
        return Array(ips).sorted()
    }
}
