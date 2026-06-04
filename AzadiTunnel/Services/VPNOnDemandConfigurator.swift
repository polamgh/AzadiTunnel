import Foundation
import NetworkExtension

enum VPNOnDemandConfigurator {
    static func apply(to manager: NETunnelProviderManager, settings: AppSettings) {
        if settings.vpnOnDemandEnabled {
            manager.onDemandRules = rules(for: settings.vpnOnDemandMode)
            manager.isOnDemandEnabled = true
        } else {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
        }
    }

    static func rules(for mode: AppSettings.VPNOnDemandMode) -> [NEOnDemandRule] {
        let rule = NEOnDemandRuleConnect()
        switch mode {
        case .always:
            rule.interfaceTypeMatch = .any
        case .wifi:
            rule.interfaceTypeMatch = .wiFi
        case .cellular:
            rule.interfaceTypeMatch = .cellular
        }
        return [rule]
    }
}
