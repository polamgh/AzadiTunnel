import Foundation

/// Privacy-preserving characteristics of the current iOS network path.
///
/// This intentionally contains no SSID, BSSID, local IP address, or other network identifier.
/// It is only coarse path context, not a stable network identity; it is never sufficient on its
/// own to reuse a successful transport choice.
struct NetworkProfile: Codable, Equatable, Hashable, Sendable {
    enum InterfaceClass: String, Codable, Hashable, Sendable {
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case other
        case unknown
    }

    enum PathStatus: String, Codable, Hashable, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
        case unknown
    }

    let interfaceClass: InterfaceClass
    let availableInterfaceClasses: [InterfaceClass]
    let pathStatus: PathStatus
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool

    init(
        interfaceClass: InterfaceClass,
        availableInterfaceClasses: [InterfaceClass] = [],
        pathStatus: PathStatus = .satisfied,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true
    ) {
        self.interfaceClass = interfaceClass
        self.availableInterfaceClasses = availableInterfaceClasses
        self.pathStatus = pathStatus
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }
}

/// A path snapshot paired with a process-local generation from `NWPathMonitor`.
///
/// The generation is intentionally not Codable or persisted. It changes on every path update,
/// including two Wi-Fi paths that have the same coarse interface characteristics, so a successful
/// transport cannot be reused after an unseen network transition.
struct NetworkPathSnapshot: Equatable, Sendable {
    let profile: NetworkProfile
    let generation: UInt64
}
