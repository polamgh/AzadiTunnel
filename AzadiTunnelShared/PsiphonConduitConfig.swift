import Foundation

/// Conduit (in-proxy) options aligned with Shiro `TunnelManager` conduit block.
enum PsiphonConduitConfig {
    /// Bundled JSON key — extracted from Shiro APK (`PSIPHON_CONDUIT_COMPARTMENT_ID`).
    static let bundledCompartmentKey = "ConduitPersonalCompartmentID"

    static func usesPersonalCompartment(settings: AppSettings) -> Bool {
        switch settings.conduitMode {
        case .shiroCommunity:
            return true
        case .publicOnly:
            return false
        case .auto:
            return !settings.conduitFallbackToPublic
        }
    }

    static func apply(to dict: inout [String: Any], settings: AppSettings) {
        guard settings.protocolSelection == .conduit else {
            dict.removeValue(forKey: "InproxyClientPersonalCompartmentID")
            dict.removeValue(forKey: bundledCompartmentKey)
            dict.removeValue(forKey: "GeoIPDatabasePath")
            dict.removeValue(forKey: "InproxyRejectProxyCountryCodes")
            return
        }

        let compartment = (dict[bundledCompartmentKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        dict.removeValue(forKey: bundledCompartmentKey)

        if usesPersonalCompartment(settings: settings), !compartment.isEmpty {
            dict["InproxyClientPersonalCompartmentID"] = compartment
        } else {
            dict.removeValue(forKey: "InproxyClientPersonalCompartmentID")
        }

        if let geoPath = PsiphonGeoIP.installToAppGroupIfNeeded() {
            dict["GeoIPDatabasePath"] = geoPath
        } else {
            dict.removeValue(forKey: "GeoIPDatabasePath")
        }

        if settings.rejectCensoredCountryProxies {
            dict["InproxyRejectProxyCountryCodes"] = PsiphonGeoIP.censoredCountryCodes
        } else {
            dict.removeValue(forKey: "InproxyRejectProxyCountryCodes")
        }

        // Shiro conduit block does not set DisableTactics — broker specs come from tactics.
        dict.removeValue(forKey: "DisableTactics")
        // Shiro does not set EstablishTunnelTimeoutSeconds for normal conduit (only temporary tunnels).
        dict.removeValue(forKey: "EstablishTunnelTimeoutSeconds")
    }
}
