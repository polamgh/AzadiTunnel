import Foundation

/// Regression test for App Group settings persistence: Secure DNS migration may rewrite legacy
/// DNS fields, but it must preserve the user's explicit messaging compatibility choice.
@main
struct SharedSettingsMigrationTests {
    static func main() throws {
        var legacy = AppSettings()
        legacy.secureDNSMode = .off
        legacy.blockCleartextDNS = false
        legacy.messagingAppsCompatibilityModeEnabled = true

        let encodedLegacy = try JSONEncoder().encode(legacy)
        var persisted = try JSONDecoder().decode(AppSettings.self, from: encodedLegacy)
        _ = SharedSettingsMigration.migrate(&persisted)
        let encodedMigrated = try JSONEncoder().encode(persisted)
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: encodedMigrated)

        precondition(reloaded.secureDNSMode == .doh, "legacy DNS mode was not migrated")
        precondition(reloaded.blockCleartextDNS, "cleartext DNS remained enabled")
        precondition(
            reloaded.messagingAppsCompatibilityModeEnabled,
            "explicit messaging compatibility setting was reset during DNS migration"
        )
        print("SharedSettingsMigrationTests: PASS")
    }
}
