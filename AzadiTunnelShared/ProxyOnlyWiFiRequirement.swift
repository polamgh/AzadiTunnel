import Foundation

/// Proxy Only Mode requires a Wi-Fi IPv4 address — same-device apps reach the extension proxy via hairpin.
enum ProxyOnlyWiFiRequirement {
    static var hasReachableWiFiIP: Bool {
        LocalNetworkAddress.wifiIPv4() != nil
    }

    static var isBlocked: Bool {
        SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled && !hasReachableWiFiIP
    }
}
