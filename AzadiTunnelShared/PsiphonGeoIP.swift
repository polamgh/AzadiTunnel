import Foundation

/// GeoIP database for Conduit (Shiro copies `assets/GeoLite2-Country.mmdb` into app storage).
enum PsiphonGeoIP {
    static let bundledFileName = "GeoLite2-Country"
    static let bundledExtension = "mmdb"
    static let appGroupFileName = "GeoLite2-Country.mmdb"

    /// Copies bundled MMDB into the App Group when missing or outdated. Returns absolute path for `GeoIPDatabasePath`.
    @discardableResult
    static func installToAppGroupIfNeeded() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName
        ) else { return nil }

        let dest = container.appendingPathComponent(appGroupFileName, isDirectory: false)
        guard let source = bundledURL() else {
            SharedLogger.shared.logRaw("GEOIP_INSTALL", detail: "bundled_missing")
            return FileManager.default.fileExists(atPath: dest.path) ? dest.path : nil
        }

        let destExists = FileManager.default.fileExists(atPath: dest.path)
        if destExists {
            if let srcDate = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               let dstDate = try? dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               srcDate <= dstDate {
                return dest.path
            }
        }

        do {
            if destExists { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
            SharedLogger.shared.logRaw("GEOIP_INSTALL", detail: "ok path=\(dest.lastPathComponent)")
            return dest.path
        } catch {
            SharedLogger.shared.logRaw("GEOIP_INSTALL", detail: "failed error=\(error.localizedDescription)")
            return destExists ? dest.path : nil
        }
    }

    static func bundledURL() -> URL? {
        if let url = Bundle.main.url(forResource: bundledFileName, withExtension: bundledExtension) {
            return url
        }
        // Extension / tests may resolve via AzadiTunnel.app bundle path in shared container installs.
        return nil
    }

    /// Shiro `CENSORED_COUNTRY_CODES` — reject in-proxy peers in these regions when enabled.
    static let censoredCountryCodes = ["IR", "CN", "RU", "BY", "TM", "KP"]
}
