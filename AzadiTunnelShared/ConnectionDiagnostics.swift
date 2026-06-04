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

enum ConnectionDiagnosticsStore {
    private static let leakKey = "leak_test_report_json"
    private static let qualityKey = "connection_quality_report_json"
    private static let fallbackKey = "fallback_chain_state_json"

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
