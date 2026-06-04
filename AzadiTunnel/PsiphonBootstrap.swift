import Foundation

/// Installs bundled Psiphon config + embedded server entries into App Group (first launch / app update).
enum PsiphonBootstrap {
    private static let bundledConfigName = "psiphon-config"
    private static let bundledConfigLocalName = "psiphon-config.local"
    private static let bundledEntriesName = "psiphon-embedded-server-entries"
    private static let bundledEntriesLocalName = "psiphon-embedded-server-entries.local"

    @discardableResult
    static func installBundledConfigIfNeeded(force: Bool = false) -> Bool {
        migrateBundledConfigIfAppUpdated()

        if force {
            SharedSettingsStore.shared.psiphonBootstrapInstalled = false
        }
        SharedSettingsStore.shared.migrateServerEntriesFromDefaultsIfNeeded()
        guard !SharedSettingsStore.shared.psiphonBootstrapInstalled else {
            SharedSettingsStore.shared.migrateServerEntriesFromDefaultsIfNeeded()
            try? SharedSettingsStore.shared.recomposeEffectiveConfig()
            return true
        }

        let (configText, configSource) = loadMergedBundledConfigJSON()
        guard let configText else {
            SharedLogger.shared.log(.psiphonConfigFound, detail: "found=false")
            return false
        }
        SharedLogger.shared.log(.psiphonConfigFound, detail: "source=\(configSource)")
        SharedLogger.shared.log(.psiphonBundledConfigFound, detail: "source=\(configSource)")

        let serverEntries = loadBundledServerEntries()
        let entriesSource = serverEntries == nil ? "none" : bundledEntriesSource()

        do {
            _ = PsiphonGeoIP.installToAppGroupIfNeeded()
            try SharedSettingsStore.shared.installPsiphonConfig(
                json: configText,
                serverEntries: serverEntries,
                bundled: true
            )
            if let data = configText.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                PsiphonRemoteServerListDiagnostics.logBootstrapSummary(
                    dict: dict,
                    embeddedLines: SharedSettingsStore.shared.psiphonServerEntriesLineCount
                )
            }
            recordBootstrapVersion()
            SharedLogger.shared.log(.psiphonBundledConfigInstalled, detail: "entries=\(entriesSource)")
            if SharedSettingsStore.shared.psiphonServerEntriesLineCount > 0 {
                SharedLogger.shared.log(
                    .psiphonServerEntriesLoaded,
                    detail: "lines=\(SharedSettingsStore.shared.psiphonServerEntriesLineCount)"
                )
            }
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            SharedLogger.shared.log(.psiphonBundledConfigInstallFailed, detail: "error=\(reason)")
            SharedLogger.shared.log(.configValidateFailed, detail: "phase=bundled_bootstrap")
            return false
        }
    }

    /// Refresh bundled JSON on app version bump when user still uses bundled config (not custom import).
    private static func migrateBundledConfigIfAppUpdated() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName)
        let previous = defaults?.string(forKey: AppGroupConstants.psiphonBootstrapVersionKey)

        guard previous != current else { return }
        defaults?.set(current, forKey: AppGroupConstants.psiphonBootstrapVersionKey)

        guard SharedSettingsStore.shared.usesBundledConfig else { return }
        SharedLogger.shared.logRaw("PSIPHON_BOOTSTRAP_MIGRATE", detail: "from=\(previous ?? "none") to=\(current)")
        SharedSettingsStore.shared.psiphonBootstrapInstalled = false
        _ = installBundledConfigIfNeeded()
    }

    private static func recordBootstrapVersion() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        UserDefaults(suiteName: AppGroupConstants.suiteName)?
            .set(current, forKey: AppGroupConstants.psiphonBootstrapVersionKey)
    }

    static var setupHintForUser: String {
        """
        Psiphon config is not installed.

        See docs/BUNDLED_PSIPHON_CONFIG.md, then Settings → Advanced → Retry bundled install.
        """
    }

    private static func loadBundledServerEntries() -> String? {
        SharedSettingsStore.mergedBundledServerEntriesText()
    }

    private static func bundledEntriesSource() -> String {
        var parts = ["bundled.txt"]
        if Bundle.main.url(forResource: bundledEntriesLocalName, withExtension: "txt") != nil {
            parts.append("local.txt")
        }
        if Bundle.main.url(
            forResource: "psiphon-embedded-server-entries.remote-supplement",
            withExtension: "txt"
        ) != nil {
            parts.append("remote-supplement.txt")
        }
        return parts.joined(separator: "+")
    }

    /// Merges `psiphon-config.json` + gitignored `psiphon-config.local.json` (distributor keys).
    private static func loadMergedBundledConfigJSON() -> (text: String?, source: String) {
        let base = loadBundledText(primary: bundledConfigName, local: "", ext: "json")
        let overlay = loadBundledText(primary: "", local: bundledConfigLocalName, ext: "json")

        switch (base, overlay) {
        case let (b?, o?):
            do {
                let merged = try PsiphonConfigMerge.merge(baseJSON: b, overlayJSON: o)
                return (merged, "bundled+local.json")
            } catch {
                SharedLogger.shared.logRaw(
                    "PSIPHON_CONFIG_MERGE_FAILED",
                    detail: "error=\(error.localizedDescription)"
                )
                return (b, "bundled.json")
            }
        case let (b?, nil):
            return (b, "bundled.json")
        case let (nil, o?):
            return (o, "local.json")
        case (nil, nil):
            return (nil, "missing")
        }
    }

    private static func loadBundledTextWithSource(
        primary: String,
        local: String,
        ext: String
    ) -> (text: String?, source: String) {
        if !local.isEmpty,
           let localURL = Bundle.main.url(forResource: local, withExtension: ext),
           let text = try? String(contentsOf: localURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (text, "local.\(ext)")
        }
        guard !primary.isEmpty,
              let url = Bundle.main.url(forResource: primary, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, "missing")
        }
        return (text, "bundled.\(ext)")
    }

    private static func loadBundledText(primary: String, local: String, ext: String) -> String? {
        if !local.isEmpty,
           let localURL = Bundle.main.url(forResource: local, withExtension: ext),
           let text = try? String(contentsOf: localURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard !primary.isEmpty,
              let url = Bundle.main.url(forResource: primary, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
