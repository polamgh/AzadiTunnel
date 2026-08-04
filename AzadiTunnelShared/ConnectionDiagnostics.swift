import Foundation

enum LeakTestVerdict: String, Codable, Equatable {
    case safe = "SAFE"
    case warning = "WARNING"
    case leakDetected = "LEAK DETECTED"
    case unknown = "UNKNOWN"
}

struct LeakTestReport: Codable, Equatable {
    var publicIPBefore: String = ""
    var publicIPAfter: String = ""
    var dnsSummary: String = ""
    var ipv6Summary: String = ""
    var webRTCSummary: String = ""
    var verdict: LeakTestVerdict = .unknown
    var detail: String = ""
    var testedAt: Date = Date()
}

struct ConnectionQualityReport: Codable, Equatable {
    var connectedProtocol: String = ""
    var publicIP: String = ""
    var countryRegion: String = ""
    var https204Passed: Bool = false
    var latencyMs: Int = -1
    var transportMode: String = ""
    var cdnEdgeIP: String = ""
    var cdnSNI: String = ""
    var readyAt: Date = Date()
}

enum FallbackStep: String, Codable, Equatable {
    case cdn = "cdn"
    case autoBeast = "auto_beast"
    case direct = "direct"
    case conduitPublic = "conduit_public"
}

struct FallbackChainState: Codable, Equatable {
    var isActive: Bool = false
    var currentStep: FallbackStep?
    var lastFailedStep: FallbackStep?
    var lastFailureReason: String = ""
    var succeededStep: FallbackStep?
    var succeededProtocol: String = ""
    var exhausted: Bool = false
}

/// Runtime result from Find Best / fallback chain success. Reuse is process-local and path-scoped.
struct BestServerSelection: Codable, Equatable {
    var transport: String = ""
    var tunnelProtocol: String = ""
    var latencyMs: Int = -1
    var cdnEdgeIP: String = ""
    var cdnSNI: String = ""
    var selectedAt: Date = Date()
    /// Coarse path context at the time this result worked. It is paired with a process-local path
    /// generation; neither legacy records nor this profile alone is sufficient for reuse.
    var networkProfile: NetworkProfile? = nil
    /// Process-local `NWPathMonitor` generation. A path update invalidates the session cache even
    /// when the coarse profile still looks like Wi-Fi or cellular.
    var pathGeneration: UInt64? = nil
    /// Explicit expiry keeps the cache bounded even when the device stays on one path.
    var expiresAt: Date? = nil
}

enum BestServerCachePolicy {
    /// Transport availability can change quickly on a censored network; keep this cache short-lived.
    static let maxAge: TimeInterval = 6 * 60 * 60

    static func isReusable(
        _ selection: BestServerSelection?,
        for snapshot: NetworkPathSnapshot,
        now: Date
    ) -> Bool {
        guard let selection,
              let savedProfile = selection.networkProfile,
              let savedGeneration = selection.pathGeneration,
              savedProfile == snapshot.profile,
              savedGeneration == snapshot.generation,
              selection.selectedAt <= now else {
            return false
        }
        let expiry = selection.expiresAt ?? selection.selectedAt.addingTimeInterval(maxAge)
        return now < expiry
    }

    /// A coarse profile alone is not a stable network identity. It is never sufficient to reuse a
    /// winner, even when its interface/expensive/IPv4/IPv6 fields happen to match.
    static func isReusable(
        _ selection: BestServerSelection?,
        for profile: NetworkProfile,
        now: Date
    ) -> Bool {
        _ = selection
        _ = profile
        _ = now
        return false
    }

    static func scoped(
        _ selection: BestServerSelection,
        for snapshot: NetworkPathSnapshot,
        now: Date
    ) -> BestServerSelection {
        var scoped = selection
        scoped.networkProfile = snapshot.profile
        scoped.pathGeneration = snapshot.generation
        scoped.selectedAt = now
        scoped.expiresAt = now.addingTimeInterval(maxAge)
        return scoped
    }
}

enum SmartRecoveryPhase: String, Codable, Equatable {
    case savedBest = "saved_best"
    case transportChain = "transport_chain"
    case clearEgress = "clear_egress"
    case egressRegion = "egress_region"
    case beastAuto = "beast_auto"
    case messagingCompat = "messaging_compat"
    case secureDnsOff = "secure_dns_off"
    case conduitPublic = "conduit_public"
    case conduitUncensor = "conduit_uncensor"
    case directReconnect = "direct_reconnect"
}

struct SmartRecoveryState: Codable, Equatable {
    var isActive: Bool = false
    var currentPhase: SmartRecoveryPhase?
    var attemptIndex: Int = 0
    var totalAttempts: Int = 0
    var lastFailureReason: String = ""
    var succeededPhase: SmartRecoveryPhase?
    var exhausted: Bool = false
}

enum ConnectionDiagnosticsStore {
    private static let leakKey = "leak_test_report_json"
    private static let qualityKey = "connection_quality_report_json"
    private static let fallbackKey = "fallback_chain_state_json"
    private static let legacyBestServerKey = "best_server_selection_json"
    private static let smartRecoveryKey = "smart_recovery_state_json"
    /// Deliberately process-local. A UserDefaults winner would outlive the path monitor and could
    /// be reused on an unrelated Wi-Fi network after relaunch.
    private static var sessionBestServer: BestServerSelection?

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    static func saveLeak(_ report: LeakTestReport) {
        save(report, key: leakKey)
    }

    static func loadLeak() -> LeakTestReport? {
        load(key: leakKey)
    }

    static func saveQuality(_ report: ConnectionQualityReport) {
        save(report, key: qualityKey)
    }

    static func loadQuality() -> ConnectionQualityReport? {
        load(key: qualityKey)
    }

    static func saveFallback(_ state: FallbackChainState) {
        save(state, key: fallbackKey)
    }

    static func loadFallback() -> FallbackChainState {
        load(key: fallbackKey) ?? FallbackChainState()
    }

    static func clearFallback() {
        defaults?.removeObject(forKey: fallbackKey)
    }

    static func saveBestServer(_ selection: BestServerSelection) {
        _ = selection
        // Unscoped writes are intentionally ignored. Use the snapshot overload below.
    }

    static func saveBestServer(
        _ selection: BestServerSelection,
        for snapshot: NetworkPathSnapshot,
        now: Date = Date()
    ) {
        sessionBestServer = BestServerCachePolicy.scoped(selection, for: snapshot, now: now)
    }

    /// Returns a winner only when it was recorded for this same coarse path profile and has not
    /// expired. The generation check also rejects a path update that leaves the coarse profile
    /// unchanged.
    static func loadBestServer(
        for snapshot: NetworkPathSnapshot,
        now: Date = Date()
    ) -> BestServerSelection? {
        guard let selection = sessionBestServer else { return nil }
        guard BestServerCachePolicy.isReusable(selection, for: snapshot, now: now) else {
            sessionBestServer = nil
            return nil
        }
        return selection
    }

    /// Unscoped reads are intentionally disabled so callers cannot accidentally reuse a winner on
    /// a different Wi-Fi, cellular, or constrained/expensive path, or after relaunch.
    static func loadBestServer() -> BestServerSelection? {
        nil
    }

    /// Clears the process-local winner as soon as `NWPathMonitor` reports any path update.
    static func invalidateBestServer() {
        sessionBestServer = nil
    }

    static func clearBestServer() {
        invalidateBestServer()
        // Remove records written by older builds; they are never read by this implementation.
        defaults?.removeObject(forKey: legacyBestServerKey)
    }

    static func saveSmartRecovery(_ state: SmartRecoveryState) {
        save(state, key: smartRecoveryKey)
    }

    static func loadSmartRecovery() -> SmartRecoveryState {
        load(key: smartRecoveryKey) ?? SmartRecoveryState()
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let defaults,
              let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(key: String) -> T? {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        return value
    }
}
