import Foundation
import FirebaseAnalytics
import FirebaseCore

/// Best-effort Firebase Analytics integration for the main app target.
///
/// Analytics is deliberately kept out of the packet-tunnel extension and out of
/// the connection critical path. A missing/invalid Firebase configuration, an
/// offline device, or an Analytics SDK failure must never prevent a VPN start.
@MainActor
enum FirebaseAnalyticsService {
    private static let connectedEventName = "vpn_connected"
    private static let lastConnectedEventKey = "firebase_last_vpn_connected_event_id"
    private static var configured = false
    private static var pendingEventIDs = Set<String>()

    static func configure() {
        guard !configured else { return }

        if FirebaseApp.app() == nil {
            guard let configURL = Bundle.main.url(
                forResource: "GoogleService-Info",
                withExtension: "plist"
            ) else {
                SharedLogger.shared.logRaw(
                    "FIREBASE_ANALYTICS_DISABLED",
                    detail: "reason=missing_google_service_info"
                )
                return
            }
            guard let options = FirebaseOptions(contentsOfFile: configURL.path) else {
                SharedLogger.shared.logRaw(
                    "FIREBASE_ANALYTICS_DISABLED",
                    detail: "reason=invalid_google_service_info"
                )
                return
            }
            FirebaseApp.configure(options: options)
        }

        // The target links FirebaseAnalyticsCore, so no AdSupport/IDFA capability
        // is included and no tracking permission is requested from the user.
        Analytics.setAnalyticsCollectionEnabled(true)
        configured = true
        SharedLogger.shared.logRaw("FIREBASE_ANALYTICS_READY", detail: "idfa=false")
    }

    /// Logs one event for each app-owned VPN attempt that reaches a verified,
    /// connected state. It intentionally sends no IP address, coordinates, or
    /// user/device identifier.
    static func logConnectionEstablished() {
        let stats = TunnelStatisticsStore.load()
        let settings = SharedSettingsStore.shared.effectiveAppSettings
        let eventID = connectionEventID(for: stats)

        guard !pendingEventIDs.contains(eventID), !wasLogged(eventID) else { return }
        pendingEventIDs.insert(eventID)

        // Network path lookup is isolated from the caller. It cannot delay the
        // VPN UI or stop/restart lifecycle even if the path monitor is waiting.
        Task { @MainActor in
            let snapshot = await IOSNetworkProfileProvider.current()
            configure()
            guard configured else {
                pendingEventIDs.remove(eventID)
                return
            }

            let parameters = makeParameters(
                stats: stats,
                settings: settings,
                networkProfile: snapshot.profile,
                carrier: CellularCarrierProvider.current()
            )
            Analytics.logEvent(connectedEventName, parameters: parameters)
            defaults?.set(eventID, forKey: lastConnectedEventKey)
            pendingEventIDs.remove(eventID)
            SharedLogger.shared.logRaw(
                "FIREBASE_ANALYTICS_EVENT",
                detail: "name=\(connectedEventName) network=\(parameters["network_type"] as? String ?? "unknown") carrier=\(parameters["carrier_id"] as? String ?? "unknown") protocol=\(parameters["protocol"] as? String ?? "unknown") country=\(parameters["egress_country"] as? String ?? "unknown") city=\(parameters["egress_city"] as? String ?? "unknown")"
            )
        }
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    private static func wasLogged(_ eventID: String) -> Bool {
        defaults?.string(forKey: lastConnectedEventKey) == eventID
    }

    private static func connectionEventID(for stats: TunnelStatistics) -> String {
        let attempt = SharedSettingsStore.shared.activeVPNAttemptID ?? "no_attempt"
        let connectedAt = stats.connectedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        return "\(attempt)|\(Int(connectedAt))"
    }

    private static func makeParameters(
        stats: TunnelStatistics,
        settings: AppSettings,
        networkProfile: NetworkProfile,
        carrier: CellularCarrierSnapshot
    ) -> [String: Any] {
        let country = normalizedCountry(stats)
        let city = normalized(stats.connectedCity)
        let protocolName = normalized(
            stats.connectedTunnelProtocol.isEmpty
                ? settings.protocolSelection.rawValue
                : stats.connectedTunnelProtocol
        )

        return [
            "network_type": networkType(networkProfile.interfaceClass),
            "network_expensive": networkProfile.isExpensive ? 1 : 0,
            "network_constrained": networkProfile.isConstrained ? 1 : 0,
            // These are SIM/eSIM provider fields, not a network identifier.
            // They are available without any special user permission.
            "carrier_id": normalized(carrier.primaryIdentifier),
            "carrier_name": normalized(carrier.primaryName),
            "carrier_names": normalized(carrier.namesValue),
            "carrier_country": normalized(carrier.primaryCountry),
            "carrier_codes": normalized(carrier.codesValue),
            "carrier_count": carrier.names.count,
            "protocol": protocolName,
            "configured_protocol": normalized(settings.protocolSelection.rawValue),
            "egress_country": country,
            "egress_city": city,
            "proxy_only": stats.proxyOnlyModeActive ? 1 : 0
        ]
    }

    private static func normalizedCountry(_ stats: TunnelStatistics) -> String {
        let code = stats.connectedCountryCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        if code.count == 2 { return code }
        return normalized(stats.connectedCountry)
    }

    private static func normalized(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "unknown" }
        return String(value.prefix(100))
    }

    private static func networkType(_ interfaceClass: NetworkProfile.InterfaceClass) -> String {
        switch interfaceClass {
        case .wiredEthernet: return "wired_ethernet"
        case .wifi, .cellular, .loopback, .other, .unknown:
            return interfaceClass.rawValue
        }
    }
}
