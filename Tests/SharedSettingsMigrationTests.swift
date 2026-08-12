import Foundation

/// Regression: one-shot Secure DNS → Off migration for all upgrades, then preserve user choice
/// and messaging compatibility.
@main
struct SharedSettingsMigrationTests {
    static func main() throws {
        // Existing DoH (and DoT) installs migrate to Off once.
        var dohSettings = AppSettings()
        dohSettings.secureDNSMode = .doh
        dohSettings.hasMigratedSecureDNSOptionalDefault = false
        dohSettings.messagingAppsCompatibilityModeEnabled = true
        _ = SharedSettingsMigration.migrate(&dohSettings)
        precondition(dohSettings.secureDNSMode == .off, "upgrade must force Secure DNS Off once")
        precondition(dohSettings.hasMigratedSecureDNSOptionalDefault, "migration flag must be set")
        precondition(
            dohSettings.messagingAppsCompatibilityModeEnabled,
            "explicit messaging compatibility setting was reset during DNS migration"
        )

        var dotSettings = AppSettings()
        dotSettings.secureDNSMode = .dot
        dotSettings.customDoTHost = "dns.example"
        dotSettings.hasMigratedSecureDNSOptionalDefault = false
        _ = SharedSettingsMigration.migrate(&dotSettings)
        precondition(dotSettings.secureDNSMode == .off, "legacy DoT must migrate to Off")
        precondition(dotSettings.customDoTHost.isEmpty, "legacy DoT host was not cleared")

        // After the one-shot, turning DoH back on must stick across later migrate calls.
        dohSettings.secureDNSMode = .doh
        _ = SharedSettingsMigration.migrate(&dohSettings)
        precondition(dohSettings.secureDNSMode == .doh, "post-migration DoH choice must be preserved")

        // Round-trip encode preserves off + messaging choice after migration.
        let encoded = try JSONEncoder().encode(dohSettings)
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        precondition(reloaded.secureDNSMode == .doh)
        precondition(reloaded.hasMigratedSecureDNSOptionalDefault)
        precondition(reloaded.messagingAppsCompatibilityModeEnabled)

        // Factory default is off.
        precondition(AppSettings().secureDNSMode == .off, "default secure DNS mode must be off")

        print("SharedSettingsMigrationTests: PASS")
    }
}
