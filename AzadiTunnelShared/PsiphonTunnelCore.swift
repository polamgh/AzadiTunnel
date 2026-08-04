import Foundation

/// Local proxy type reported by psiphon-tunnel-core after start.
enum PsiphonLocalProxyType: String, Sendable {
    case socks
    case http
    case dual
    case unknown
}

/// Stable Swift-facing surface for tunnel-core (live implementation in packet tunnel target only).
protocol PsiphonTunnelCoreProtocol: AnyObject, Sendable, PacketEngineCapabilityProviding {
    var isRunning: Bool { get }
    var localProxyHost: String { get }
    var localProxyPort: Int { get }
    var localProxyType: PsiphonLocalProxyType { get }
    var localProxyEndpoints: PsiphonLocalProxyEndpoints { get }
    var lastError: String? { get }
    var onLocalProxyEndpointsChanged: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)? { get set }

    func start(
        configJSON: String,
        serverEntriesPath: String?,
        dataDir: URL,
        packetTunnel: PsiphonPacketTunnelIO?
    ) async throws
    func stop() async
}

/// Raw packet I/O between Network Extension's public packetFlow API and
/// Psiphon tunnel-core's native packet transport. Implementations must retain
/// packet order, surface queue overflow as an error, and unblock reads on
/// close. Packets are complete IPv4/IPv6 packets with no tun header.
protocol PsiphonPacketTunnelIO: AnyObject, Sendable {
    func readPacket() throws -> Data
    func writePacket(_ packet: Data) throws
    func close()
}

/// Main app and previews use the stub; extension defines live adapter in its target.
enum PsiphonTunnelCoreFactory {
    static func make() -> PsiphonTunnelCoreProtocol {
        PsiphonTunnelAdapterStub()
    }
}

enum PsiphonTunnelCoreError: LocalizedError {
    case frameworkMissing
    case startFailed(String)
    case proxyNotReady
    case noConfig

    var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return "Psiphon tunnel core is only available in the packet tunnel extension."
        case .startFailed(let reason):
            return reason
        case .proxyNotReady:
            return "Local proxy did not become ready."
        case .noConfig:
            return "Psiphon configuration is not installed. Check bundled resources."
        }
    }
}

/// Stub used by the main app (never links PsiphonTunnel.framework).
final class PsiphonTunnelAdapterStub: PsiphonTunnelCoreProtocol, @unchecked Sendable {
    private(set) var lastError: String? = "Psiphon runs in the packet tunnel extension only."

    var onLocalProxyEndpointsChanged: (@Sendable (PsiphonLocalProxyEndpoints) -> Void)?

    var isRunning: Bool { false }
    var localProxyHost: String { "127.0.0.1" }
    var localProxyPort: Int { 0 }
    var localProxyType: PsiphonLocalProxyType { .unknown }
    var localProxyEndpoints: PsiphonLocalProxyEndpoints {
        PsiphonLocalProxyEndpoints(host: localProxyHost, socksPort: 0, httpPort: 0)
    }

    func start(
        configJSON: String,
        serverEntriesPath: String?,
        dataDir: URL,
        packetTunnel: PsiphonPacketTunnelIO?
    ) async throws {
        SharedLogger.shared.log(.psiphonStartFailed, detail: lastError)
        throw PsiphonTunnelCoreError.frameworkMissing
    }

    func stop() async {
        SharedLogger.shared.log(.psiphonStopped)
    }
}
