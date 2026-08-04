import Foundation

/// Migrations applied when the App Group settings blob is read. Secure DNS migration is kept
/// separate from messaging compatibility persistence so enabling one feature can never rewrite
/// the other feature's explicit user choice.
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
        if settings.secureDNSMode != .doh {
            settings.secureDNSMode = .doh
            settings.customDoTHost = ""
            didMigrate = true
        }
        if !settings.blockCleartextDNS {
            settings.blockCleartextDNS = true
            didMigrate = true
        }
        return didMigrate
    }
}
