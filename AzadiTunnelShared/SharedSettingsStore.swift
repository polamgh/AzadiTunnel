import Foundation

final class SharedSettingsStore {
    static let shared = SharedSettingsStore()

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    var psiphonBootstrapInstalled: Bool {
        get { defaults?.bool(forKey: AppGroupConstants.psiphonBootstrapInstalledKey) ?? false }
        set { defaults?.set(newValue, forKey: AppGroupConstants.psiphonBootstrapInstalledKey) }
    }

    var hasActivePsiphonConfig: Bool {
        guard let json = psiphonConfigJSON else { return false }
        return !json.isEmpty
    }

    /// True when composed config has distributor keys required for Conduit (in-proxy).
    var conduitConnectAllowed: Bool {
        guard let json = psiphonConfigJSON else { return false }
        return PsiphonDistributorKeys.readiness(
            composedJSON: json,
            embeddedServerEntryLines: psiphonServerEntriesLineCount
        ).allowsConduit
    }

    var conduitDistributorReadiness: PsiphonDistributorKeys.Readiness {
        PsiphonDistributorKeys.readiness(
            composedJSON: psiphonConfigJSON ?? "",
            embeddedServerEntryLines: psiphonServerEntriesLineCount
        )
    }

    var psiphonConfigJSON: String? {
        get { defaults?.string(forKey: AppGroupConstants.psiphonConfigKey) }
        set {
            if let newValue {
                defaults?.set(newValue, forKey: AppGroupConstants.psiphonConfigKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.psiphonConfigKey)
            }
        }
    }

    var psiphonConfigBaseJSON: String? {
        get { defaults?.string(forKey: AppGroupConstants.psiphonConfigBaseKey) }
        set {
            if let newValue {
                defaults?.set(newValue, forKey: AppGroupConstants.psiphonConfigBaseKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.psiphonConfigBaseKey)
            }
        }
    }

    /// Path to embedded server entries in the App Group container (too large for UserDefaults).
    var psiphonServerEntriesPath: String? {
        guard let url = psiphonServerEntriesFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url.path
    }

    var psiphonServerEntriesLineCount: Int {
        if let stored = defaults?.object(forKey: AppGroupConstants.psiphonServerEntriesLineCountKey) as? Int,
           stored > 0 {
            return stored
        }
        guard let path = psiphonServerEntriesPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return 0
        }
        return Self.countServerEntryLines(text)
    }

    private var psiphonServerEntriesFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName)?
            .appendingPathComponent(AppGroupConstants.psiphonServerEntriesFileName)
    }

    var usesBundledConfig: Bool {
        defaults?.bool(forKey: AppGroupConstants.psiphonUsesBundledConfigKey) ?? false
    }

    var appSettings: AppSettings {
        get {
            guard let defaults,
                  let data = defaults.data(forKey: AppGroupConstants.appSettingsKey),
                  var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
                return AppSettings()
            }
            if !settings.hasAcceptedConnectionDisclaimer && settings.hasAcceptedVPNDisclosure {
                settings.hasAcceptedConnectionDisclaimer = true
            }
            if !settings.hasChosenLanguage,
               settings.hasCompletedOnboarding || settings.preferredLanguage != .system {
                settings.hasChosenLanguage = true
            }
            return settings
        }
        set {
            guard let defaults,
                  let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: AppGroupConstants.appSettingsKey)
        }
    }

    var vpnStatus: VPNStatusDisplay {
        get {
            guard let raw = defaults?.string(forKey: AppGroupConstants.vpnStatusKey),
                  let value = VPNStatusDisplay(rawValue: raw) else {
                return .disconnected
            }
            return value
        }
        set {
            defaults?.set(newValue.rawValue, forKey: AppGroupConstants.vpnStatusKey)
            SharedLogger.shared.log(.vpnStatusChanged, detail: "status=\(newValue.rawValue)")
        }
    }

    var isUITestMode: Bool {
        get { defaults?.bool(forKey: AppGroupConstants.testModeKey) ?? false }
        set { defaults?.set(newValue, forKey: AppGroupConstants.testModeKey) }
    }

    var lastInternetTestOK: Bool {
        get { defaults?.bool(forKey: AppGroupConstants.lastInternetTestOKKey) ?? false }
        set { defaults?.set(newValue, forKey: AppGroupConstants.lastInternetTestOKKey) }
    }

    /// True after Psiphon `onConnected` (SOCKS CONNECT fails with rep=1 until then).
    var psiphonTunnelEstablished: Bool {
        get { defaults?.bool(forKey: AppGroupConstants.psiphonTunnelEstablishedKey) ?? false }
        set { defaults?.set(newValue, forKey: AppGroupConstants.psiphonTunnelEstablishedKey) }
    }

    func installPsiphonConfig(json: String, serverEntries: String?, bundled: Bool = true) throws {
        let hasEntries = !(serverEntries ?? "").isEmpty
        let normalized = try PsiphonConfigValidator.normalizedJSON(
            json,
            hasEmbeddedServerEntries: hasEntries
        )
        psiphonConfigBaseJSON = normalized
        try writeServerEntriesFile(serverEntries)
        psiphonBootstrapInstalled = true
        defaults?.set(bundled, forKey: AppGroupConstants.psiphonUsesBundledConfigKey)
        try recomposeEffectiveConfig()
        SharedLogger.shared.log(.psiphonConfigInstalled, detail: "bundled=\(bundled)")
    }

    func recomposeEffectiveConfig() throws {
        guard let base = psiphonConfigBaseJSON else { return }
        let composed = try PsiphonConfigComposer.compose(baseJSON: base, settings: appSettings)
        let hasEntries = psiphonServerEntriesLineCount > 0
        psiphonConfigJSON = try PsiphonConfigValidator.normalizedJSON(
            composed,
            hasEmbeddedServerEntries: hasEntries
        )
        let readiness = conduitDistributorReadiness
        SharedLogger.shared.logRaw("CONDUIT_CONFIG", detail: readiness.logDetail)
        if appSettings.protocolSelection == .conduit, !readiness.allowsConduit {
            SharedLogger.shared.logRaw("CONDUIT_BLOCKED", detail: "missing_distributor_keys")
        }
    }

    func updateAppSettings(_ settings: AppSettings, logKey: String) {
        appSettings = settings
        SharedLogger.shared.log(.settingChanged, detail: "key=\(logKey)")
        try? recomposeEffectiveConfig()
    }

    func extensionCanReadSettings() -> Bool {
        defaults != nil
    }

    private func writeServerEntriesFile(_ serverEntries: String?) throws {
        defaults?.removeObject(forKey: AppGroupConstants.psiphonServerEntriesKey)
        guard let url = psiphonServerEntriesFileURL else { return }
        guard let serverEntries, !serverEntries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            defaults?.set(0, forKey: AppGroupConstants.psiphonServerEntriesLineCountKey)
            return
        }
        try serverEntries.write(to: url, atomically: true, encoding: .utf8)
        let count = Self.countServerEntryLines(serverEntries)
        defaults?.set(count, forKey: AppGroupConstants.psiphonServerEntriesLineCountKey)
    }

    private static func countServerEntryLines(_ text: String) -> Int {
        text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .count
    }

    /// Migrates legacy UserDefaults-stored entries to the App Group file.
    func migrateServerEntriesFromDefaultsIfNeeded() {
        guard psiphonServerEntriesPath == nil,
              let legacy = defaults?.string(forKey: AppGroupConstants.psiphonServerEntriesKey),
              !legacy.isEmpty else { return }
        try? writeServerEntriesFile(legacy)
    }
}
