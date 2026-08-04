import Foundation

/// Local proxy ports reported by psiphon-tunnel-core.
struct PsiphonLocalProxyEndpoints: Sendable, Equatable {
    let host: String
    let socksPort: Int
    let httpPort: Int

    var hasSocks: Bool { socksPort > 0 }
    var hasHttp: Bool { httpPort > 0 }
}
