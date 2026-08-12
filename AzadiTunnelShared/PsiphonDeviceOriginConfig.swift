import Foundation

/// Injects Psiphon client-origin hints from IP geolocation (no GPS / no location permission).
enum PsiphonDeviceOriginConfig {
    static func apply(to dict: inout [String: Any]) {
        let stats = TunnelStatisticsStore.load()

        if let region = normalizedCountryCode(stats.originCountryCode) {
            dict["DeviceRegion"] = region
        } else {
            dict.removeValue(forKey: "DeviceRegion")
        }

        if let latitude = stats.originLatitude,
           let longitude = stats.originLongitude,
           let geohash = GeoHash.encode(latitude: latitude, longitude: longitude) {
            dict["DeviceLocation"] = geohash
        } else {
            dict.removeValue(forKey: "DeviceLocation")
        }
    }

    static func logSummary(from stats: TunnelStatistics = TunnelStatisticsStore.load()) -> String {
        let region = normalizedCountryCode(stats.originCountryCode) ?? "missing"
        let hasGeo = stats.originLatitude != nil && stats.originLongitude != nil
        return "device_region=\(region) device_location=\(hasGeo ? "present" : "missing")"
    }

    private static func normalizedCountryCode(_ raw: String?) -> String? {
        let code = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        return code
    }
}
