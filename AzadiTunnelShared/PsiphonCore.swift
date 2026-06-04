import Foundation

/// Entry point for selecting Psiphon tunnel-core implementation (stub in app, live in extension).
enum PsiphonCore {
    static func makeEngine() -> PsiphonTunnelEngine {
        SharedLogger.shared.log(.psiphonCoreSelected, detail: "impl=\(implementationName)")
        return PsiphonTunnelEngine(core: PsiphonTunnelCoreFactory.make())
    }

    private static var implementationName: String {
        #if PSIPHON_TUNNEL_LIVE
        return "PsiphonTunnel"
        #else
        return "stub"
        #endif
    }
}
