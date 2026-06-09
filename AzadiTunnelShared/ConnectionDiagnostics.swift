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

/// Persisted result from Find Best / fallback chain success.
struct BestServerSelection: Codable, Equatable {
    var transport: String = ""
    var tunnelProtocol: String = ""
    var latencyMs: Int = -1
    var cdnEdgeIP: String = ""
    var cdnSNI: String = ""
    var selectedAt: Date = Date()
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
    private static let bestServerKey = "best_server_selection_json"
    private static let smartRecoveryKey = "smart_recovery_state_json"

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
        save(selection, key: bestServerKey)
    }

    static func loadBestServer() -> BestServerSelection? {
        load(key: bestServerKey)
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
