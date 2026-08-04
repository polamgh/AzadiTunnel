import Foundation

/// A short-lived runtime overlay shared with the packet extension. It is not
/// the user's durable AppSettings preference and must never be treated as one.
struct RecoveryTrialSettingsEnvelope: Codable, Equatable {
    let settings: AppSettings
    let issuedAt: Date
    let expiresAt: Date

    init(
        settings: AppSettings,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = RecoveryTrialSettingsDefaults.lifetime
    ) {
        self.settings = settings
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(max(0, lifetime))
    }

    func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }
}

enum RecoveryTrialSettingsDefaults {
    /// Long enough for the 75-second recovery budget and a healthy handoff to
    /// the extension, while bounding a stale overlay after process death.
    static let lifetime: TimeInterval = 15 * 60
}
