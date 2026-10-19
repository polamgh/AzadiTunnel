import Foundation

/// Migrations applied when the App Group settings blob is read. Secure DNS migration is kept
/// separate from messaging compatibility persistence so enabling one feature can never rewrite
/// the other feature's explicit user choice (after the one-shot optional-default migration).
enum SharedSettingsMigration {
    @discardableResult
    static func migrate(_ settings: inout AppSettings) -> Bool {
        var didMigrate = false
        if !settings.hasAcceptedConnectionDisclaimer && settings.hasAcceptedVPNDisclosure {
            settings.hasAcceptedConnectionDisclaimer = true
            didMigrate = true
        }
        if !settings.hasChosenLanguage,
           settings.hasCompletedOnboarding || settings.preferredLanguage != .system {
            settings.hasChosenLanguage = true
            didMigrate = true
        }
        // One-shot for everyone upgrading from mandatory-DoH builds: force Off once.
        // Afterwards the user can turn DoH back on and that choice is kept.
        if !settings.hasMigratedSecureDNSOptionalDefault {
            settings.secureDNSMode = .off
            settings.customDoTHost = ""
            settings.hasMigratedSecureDNSOptionalDefault = true
            didMigrate = true
        }
        return didMigrate
    }
}
