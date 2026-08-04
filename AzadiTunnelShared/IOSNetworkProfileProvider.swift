import Foundation
import Network

/// Reads privacy-preserving path snapshots and tracks path changes for the current app process.
@MainActor
final class IOSNetworkProfileProvider {
    static let shared = IOSNetworkProfileProvider()

    private let monitor: NWPathMonitor
    private var latestSnapshot: NetworkPathSnapshot?
    private var waitingContinuations: [CheckedContinuation<NetworkPathSnapshot, Never>] = []
    private var nextGeneration: UInt64 = 0

    private init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.record(path: path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.azaditunnel.network-profile"))
    }

    static func current() async -> NetworkPathSnapshot {
        await shared.snapshot()
    }

    private func snapshot() async -> NetworkPathSnapshot {
        if let latestSnapshot {
            return latestSnapshot
        }
        return await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    private func record(path: NWPath) {
        nextGeneration &+= 1
        let snapshot = NetworkPathSnapshot(
            profile: Self.makeProfile(from: path),
            generation: nextGeneration
        )
        ConnectionDiagnosticsStore.invalidateBestServer()
        latestSnapshot = snapshot
        let continuations = waitingContinuations
        waitingContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(returning: snapshot)
        }
    }

    private static func makeProfile(from path: NWPath) -> NetworkProfile {
        let available: [(NWInterface.InterfaceType, NetworkProfile.InterfaceClass)] = [
            (.wifi, .wifi),
            (.cellular, .cellular),
            (.wiredEthernet, .wiredEthernet),
            (.loopback, .loopback),
            (.other, .other)
        ]
        let availableClasses = available
            .filter { path.usesInterfaceType($0.0) }
            .map(\.1)

        let activeClass: NetworkProfile.InterfaceClass
        if path.usesInterfaceType(.wifi) {
            activeClass = .wifi
        } else if path.usesInterfaceType(.cellular) {
            activeClass = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            activeClass = .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            activeClass = .loopback
        } else if path.usesInterfaceType(.other) {
            activeClass = .other
        } else {
            activeClass = .unknown
        }

        let status: NetworkProfile.PathStatus
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .unsatisfied:
            status = .unsatisfied
        case .requiresConnection:
            status = .requiresConnection
        @unknown default:
            status = .unknown
        }

        return NetworkProfile(
            interfaceClass: activeClass,
            availableInterfaceClasses: availableClasses,
            pathStatus: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
    }
}
