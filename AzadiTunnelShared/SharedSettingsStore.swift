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

    /// LAN proxy bridge runtime status (published by extension, observed by UI).
    var lanProxyRuntimeStatus: LANProxyRuntimeStatus {
        get {
            guard let raw = defaults?.string(forKey: AppGroupConstants.lanProxyStatusKey),
                  let value = LANProxyRuntimeStatus(rawValue: raw) else {
                return .stopped
            }
            return value
        }
        set { defaults?.set(newValue.rawValue, forKey: AppGroupConstants.lanProxyStatusKey) }
    }

    var lanProxyBoundHost: String? {
        get { defaults?.string(forKey: AppGroupConstants.lanProxyBoundHostKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults?.set(newValue, forKey: AppGroupConstants.lanProxyBoundHostKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.lanProxyBoundHostKey)
            }
        }
    }

    var lanProxyActiveHttpPort: Int {
        get { defaults?.integer(forKey: AppGroupConstants.lanProxyActiveHttpPortKey) ?? 0 }
        set { defaults?.set(newValue, forKey: AppGroupConstants.lanProxyActiveHttpPortKey) }
    }

    var lanProxyActiveSocksPort: Int {
        get { defaults?.integer(forKey: AppGroupConstants.lanProxyActiveSocksPortKey) ?? 0 }
        set { defaults?.set(newValue, forKey: AppGroupConstants.lanProxyActiveSocksPortKey) }
    }

    var lanProxyStatusDetail: String? {
        get { defaults?.string(forKey: AppGroupConstants.lanProxyStatusDetailKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults?.set(newValue, forKey: AppGroupConstants.lanProxyStatusDetailKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.lanProxyStatusDetailKey)
            }
        }
    }

    // MARK: - Iran bypass cache

    private var bypassIranCidrFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName)?
            .appendingPathComponent(AppGroupConstants.bypassIranCidrFileName)
    }

    private var bypassDomainIPsFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName)?
            .appendingPathComponent(AppGroupConstants.bypassDomainIPsFileName)
    }

    /// Cached Iran CIDR lines (too large for UserDefaults — stored as an App Group file).
    var bypassIranCidrLines: [String] {
        guard let url = bypassIranCidrFileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Persists a freshly fetched Iran CIDR list and records the update timestamp + count.
    func storeBypassIranCidrLines(_ lines: [String]) {
        guard let url = bypassIranCidrFileURL else { return }
        let body = lines.joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        defaults?.set(lines.count, forKey: AppGroupConstants.bypassIranListCountKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.bypassIranListUpdatedKey)
    }

    var bypassIranListCount: Int {
        defaults?.integer(forKey: AppGroupConstants.bypassIranListCountKey) ?? 0
    }

    /// CIDR lines actually used for routing: the fetched cache if present, otherwise the bundled
    /// floor. Guarantees the feature is never empty just because the remote update failed.
    var effectiveBypassIranCidrLines: [String] {
        let cached = bypassIranCidrLines
        return cached.isEmpty ? BundledIranCIDR.lines : cached
    }

    /// True when no remote/cached list exists and we are falling back to the bundled snapshot.
    var bypassIranListIsBundledFallback: Bool {
        bypassIranCidrLines.isEmpty
    }

    /// Count shown in the UI: cache count if fetched, otherwise the bundled count.
    var effectiveBypassIranListCount: Int {
        let cached = bypassIranListCount
        return cached > 0 ? cached : BundledIranCIDR.count
    }

    var bypassIranListUpdatedAt: Date? {
        guard let ts = defaults?.object(forKey: AppGroupConstants.bypassIranListUpdatedKey) as? Double,
              ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Cached domain → resolved IPv4 addresses for domain-based bypass.
    var bypassDomainResolvedIPs: [String: [String]] {
        guard let url = bypassDomainIPsFileURL,
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return map
    }

    func storeBypassDomainResolvedIPs(_ map: [String: [String]]) {
        guard let url = bypassDomainIPsFileURL,
              let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.bypassDomainsUpdatedKey)
    }

    var bypassDomainsUpdatedAt: Date? {
        guard let ts = defaults?.object(forKey: AppGroupConstants.bypassDomainsUpdatedKey) as? Double,
              ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Number of routes the extension applied to `excludedRoutes` on the last connect.
    var bypassRoutesAppliedCount: Int {
        get { defaults?.integer(forKey: AppGroupConstants.bypassRoutesAppliedCountKey) ?? 0 }
        set { defaults?.set(newValue, forKey: AppGroupConstants.bypassRoutesAppliedCountKey) }
    }

    // MARK: - Find Best Connection

    /// The best protocol/region the auto-scan saved. Stored separately from the user's manual
    /// `protocolSelection` / `egressRegion`, so the manual connection system is never overwritten.
    var bestConnection: BestConnectionRecord? {
        guard let raw = defaults?.string(forKey: AppGroupConstants.bestConnectionProtocolKey),
              let proto = AppSettings.ProtocolSelection(rawValue: raw) else {
            return nil
        }
        let region = defaults?.string(forKey: AppGroupConstants.bestConnectionRegionKey) ?? ""
        let mbps = defaults?.double(forKey: AppGroupConstants.bestConnectionMbpsKey) ?? 0
        let ts = (defaults?.object(forKey: AppGroupConstants.bestConnectionUpdatedKey) as? Double) ?? 0
        return BestConnectionRecord(
            protocolSelection: proto,
            region: region,
            mbps: mbps,
            updatedAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        )
    }

    func saveBestConnection(protocolSelection: AppSettings.ProtocolSelection, region: String, mbps: Double) {
        defaults?.set(protocolSelection.rawValue, forKey: AppGroupConstants.bestConnectionProtocolKey)
        defaults?.set(region, forKey: AppGroupConstants.bestConnectionRegionKey)
        defaults?.set(mbps, forKey: AppGroupConstants.bestConnectionMbpsKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroupConstants.bestConnectionUpdatedKey)
    }

    func clearBestConnection() {
        defaults?.removeObject(forKey: AppGroupConstants.bestConnectionProtocolKey)
        defaults?.removeObject(forKey: AppGroupConstants.bestConnectionRegionKey)
        defaults?.removeObject(forKey: AppGroupConstants.bestConnectionMbpsKey)
        defaults?.removeObject(forKey: AppGroupConstants.bestConnectionUpdatedKey)
        defaults?.removeObject(forKey: AppGroupConstants.bestConnectionResultsKey)
    }

    /// User-selected minimum acceptable speed (Mbps); a candidate must reach this to be saved.
    var bestConnectionMinMbps: Int {
        get {
            let v = defaults?.integer(forKey: AppGroupConstants.bestConnectionMinMbpsKey) ?? 0
            return v > 0 ? v : 5
        }
        set { defaults?.set(max(1, newValue), forKey: AppGroupConstants.bestConnectionMinMbpsKey) }
    }

    /// All working connections found by the scan (kept sorted best-first by the finder).
    var bestConnectionResults: [FoundConnection] {
        get {
            guard let data = defaults?.data(forKey: AppGroupConstants.bestConnectionResultsKey),
                  let list = try? JSONDecoder().decode([FoundConnection].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults?.set(data, forKey: AppGroupConstants.bestConnectionResultsKey)
            }
        }
    }

    /// Shown in Secure DNS settings when `blockCleartextDNS` prevents fallback after resolver failure.
    var secureDNSWarning: String? {
        get { defaults?.string(forKey: AppGroupConstants.secureDNSWarningKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults?.set(newValue, forKey: AppGroupConstants.secureDNSWarningKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.secureDNSWarningKey)
            }
        }
    }

    var secureDNSCloudflareValidation: String? {
        get { defaults?.string(forKey: AppGroupConstants.secureDNSCloudflareValidationKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults?.set(newValue, forKey: AppGroupConstants.secureDNSCloudflareValidationKey)
            } else {
                defaults?.removeObject(forKey: AppGroupConstants.secureDNSCloudflareValidationKey)
            }
        }
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

    func resetAppSettingsToDefaults() {
        let fresh = AppSettings.factoryDefaults(preserving: appSettings)
        updateAppSettings(fresh, logKey: "reset_to_defaults")
        SharedLogger.shared.log(.settingsResetToDefaults)
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
