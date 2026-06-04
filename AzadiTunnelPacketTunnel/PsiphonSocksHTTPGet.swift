import Foundation

#if canImport(tun2socks)
/// HTTP GET through Psiphon SOCKS (uses `Socks5TCPClient` with full RFC 1928 reply handling).
enum PsiphonSocksHTTPGet {
    static func get(path: String, host: String, port: UInt16, socksPort: Int) async throws -> Data {
        try await Socks5TCPClient.httpGet(
            path: path,
            host: host,
            port: port,
            proxyHost: "127.0.0.1",
            proxyPort: socksPort
        )
    }
}
#endif
