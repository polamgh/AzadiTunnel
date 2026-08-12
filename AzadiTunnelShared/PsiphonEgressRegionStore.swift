import Foundation

/// Dynamic Psiphon egress regions reported by tunnel-core (`onAvailableEgressRegions`).
enum PsiphonEgressRegionStore {
    /// Shiro `RegionListPreference.allRegions` seed list when Psiphon has not reported yet.
    static let builtIn: [String] = [
        "AE", "AR", "AT", "AU", "BE", "BG", "BR", "CA", "CH", "CL", "CO", "CZ", "DE", "DK",
        "EE", "ES", "FI", "FR", "GB", "GR", "HK", "HR", "HU", "ID", "IE", "IN", "IR", "IS",
        "IT", "JP", "KE", "KR", "LT", "LV", "MX", "MY", "NL", "NO", "NZ", "PL", "PT", "RO",
        "RS", "SE", "SG", "SK", "TW", "UA", "US", "ZA"
    ]

    /// Regions offered in the picker. After Psiphon reports availability, only that list is
    /// shown (Android `RegionListPreference` parity). Before the first report, use the seed list.
    static func knownRegions() -> [String] {
        let stored = loadStoredRegions()
        if !stored.isEmpty { return stored }
        return builtIn
    }

    static func isKnownRegion(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return true }
        return knownRegions().contains(normalized)
    }

    @discardableResult
    static func updateAvailableRegions(_ regions: [String]) -> Bool {
        let normalized = regions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        guard !normalized.isEmpty else { return false }

        let sorted = Array(Set(normalized)).sorted()
        defaults?.set(sorted, forKey: AppGroupConstants.psiphonKnownEgressRegionsKey)
        SharedLogger.shared.logRaw(
            "PSIPHON_AVAILABLE_EGRESS_REGIONS",
            detail: "count=\(sorted.count) sample=\(sorted.prefix(6).joined(separator: ","))"
        )
        return reconcileSelectedRegion(with: sorted)
    }

    private static func reconcileSelectedRegion(with available: [String]) -> Bool {
        let availableSet = Set(available)
        let durable = SharedSettingsStore.shared.appSettings
        let selected = durable.egressRegion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !selected.isEmpty, !availableSet.contains(selected) else { return false }

        // Clear durable preference and any active recovery overlay. Fallback chains snapshot
        // settings at start; leaving an unavailable region in the overlay would keep retrying
        // it after we silently flip the UI to Auto.
        var cleared = durable
        cleared.egressRegion = ""
        SharedSettingsStore.shared.updateAppSettings(cleared, logKey: "egress_region_unavailable")
        SharedSettingsStore.shared.egressRegionUnavailable = true

        if var trial = SharedSettingsStore.shared.recoveryTrialSettings {
            trial.egressRegion = ""
            SharedSettingsStore.shared.applyRecoveryTrialSettings(trial)
        } else {
            try? SharedSettingsStore.shared.recomposeEffectiveConfig()
        }

        SharedLogger.shared.logRaw(
            "PSIPHON_EGRESS_REGION_RESET",
            detail: "previous=\(selected) available=\(available.prefix(8).joined(separator: ","))"
        )
        return true
    }

    private static func loadStoredRegions() -> [String] {
        defaults?.stringArray(forKey: AppGroupConstants.psiphonKnownEgressRegionsKey) ?? []
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }
}
