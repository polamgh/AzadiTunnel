import Foundation
import NetworkExtension

/// Load, enable, and save the AzadiTunnel `NETunnelProviderManager` (fixes NEVPNError configurationDisabled / code 2).
enum VPNProfileCoordinator {
    static let providerBundleID = "com.polamgh.ali.AzadiTunnel.PacketTunnel"

    static func isConfigurationDisabledError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NEVPNErrorDomain && ns.code == Int(NEVPNError.configurationDisabled.rawValue)
    }

    static func findManager(in managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        }
    }

    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return findManager(in: managers)
    }

    @discardableResult
    static func ensureEnabled(
        manager: NETunnelProviderManager,
        settings: AppSettings
    ) async throws -> NETunnelProviderManager {
        if manager.protocolConfiguration == nil
            || (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier != providerBundleID {
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleID
            proto.serverAddress = "AzadiTunnel"
            proto.providerConfiguration = [:]
            manager.protocolConfiguration = proto
        }
        if manager.localizedDescription?.isEmpty != false {
            manager.localizedDescription = "AzadiTunnel"
        }

        let wasDisabled = !manager.isEnabled
        manager.isEnabled = true
        VPNOnDemandConfigurator.apply(to: manager, settings: settings)

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        if wasDisabled {
            SharedLogger.shared.logRaw(
                "VPN_CONFIG_REENABLED",
                detail: "isEnabled=true onDemand=\(manager.isOnDemandEnabled)"
            )
        }
        return manager
    }

    static func createManager(settings: AppSettings) -> NETunnelProviderManager {
        let mgr = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "AzadiTunnel"
        proto.providerConfiguration = [:]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "AzadiTunnel"
        mgr.isEnabled = true
        VPNOnDemandConfigurator.apply(to: mgr, settings: settings)
        return mgr
    }
}
