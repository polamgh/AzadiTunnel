import Combine
import Foundation
import SwiftUI

/// One finished (or failed) connection attempt, kept for the Stats tab.
struct ConnectionSessionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let attemptStartedAt: Date
    /// Nil when the attempt never reached `.connected`.
    var connectedAt: Date?
    var endedAt: Date
    var tunnelProtocol: String
    var countryCode: String
    var bytesDown: UInt64
    var bytesUp: UInt64

    var succeeded: Bool { connectedAt != nil }

    var duration: TimeInterval {
        guard let connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }

    /// Seconds from tapping Connect to a working tunnel.
    var timeToConnect: TimeInterval? {
        connectedAt.map { max(0, $0.timeIntervalSince(attemptStartedAt)) }
    }
}

struct DailyUsage: Codable, Equatable, Identifiable {
    /// `yyyy-MM-dd` in the device's calendar.
    let day: String
    var bytesDown: UInt64
    var bytesUp: UInt64
    var id: String { day }
}

struct SpeedSample: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let down: UInt64
    let up: UInt64
}

struct LatencySample: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let milliseconds: Int
}

/// Records live speed, ping, per-day usage and connection sessions once per second for
/// the Stats tab. History lives in the app group; live samples are in memory only.
@MainActor
final class StatsHistoryStore: ObservableObject {
    static let shared = StatsHistoryStore()

    @Published private(set) var speedSamples: [SpeedSample] = []
    @Published private(set) var latencySamples: [LatencySample] = []
    @Published private(set) var dailyUsage: [DailyUsage] = []
    @Published private(set) var sessions: [ConnectionSessionRecord] = []
    @Published private(set) var status: VPNStatusDisplay = .disconnected
    @Published private(set) var statistics = TunnelStatistics()
    @Published private(set) var sessionPeakDown: UInt64 = 0
    @Published private(set) var sessionPeakUp: UInt64 = 0
    /// Y-axis ceiling for the live speed chart: jumps up with new peaks, eases down
    /// as speed falls, so the curve keeps filling the chart.
    @Published private(set) var speedChartScale: Double = 50_000

    private static let maxSpeedSamples = 120
    private static let maxLatencySamples = 60
    private static let maxSessions = 100
    private static let maxDays = 30
    private static let dailyKey = "stats_daily_usage_json"
    private static let sessionsKey = "stats_sessions_json"

    private var loop: Task<Void, Never>?
    private var lastBytesDown: UInt64?
    private var lastBytesUp: UInt64?
    private var attemptStartedAt: Date?
    private var openSession: ConnectionSessionRecord?
    private var latencyTicks = 0
    private var latencyInFlight = false
    /// Seconds between ping probes while connected.
    private static let latencyInterval = 3
    private var ticksSincePersist = 0

    private let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        dailyUsage = load([DailyUsage].self, key: Self.dailyKey) ?? []
        sessions = load([ConnectionSessionRecord].self, key: Self.sessionsKey) ?? []
    }

    func start() {
        guard loop == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestStatsDemo") {
            loadDemoData()
            status = .connected
            loop = Task {}
            return
        }
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await TaskSleep.seconds(1)
            }
        }
    }

    // MARK: - Derived values

    var lastSevenDays: [DailyUsage] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayFormatter.string(from: date)
            return dailyUsage.first { $0.day == key } ?? DailyUsage(day: key, bytesDown: 0, bytesUp: 0)
        }
    }

    static func date(forDay day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    var successRate: Double? {
        guard !sessions.isEmpty else { return nil }
        return Double(sessions.filter(\.succeeded).count) / Double(sessions.count)
    }

    var averageTimeToConnect: TimeInterval? {
        let values = sessions.compactMap(\.timeToConnect)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var totalProtectedTime: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration } + (status == .connected ? statistics.sessionDuration : 0)
    }

    /// Successful sessions per tunnel protocol, most used first.
    var protocolBreakdown: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in sessions where session.succeeded {
            let name = session.tunnelProtocol.isEmpty ? "—" : ConnectedTunnelProtocolParser.displayName(for: session.tunnelProtocol)
            counts[name, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// Bytes moved since the current session connected (0 when not connected).
    var currentSessionDown: UInt64 {
        guard let session = openSession else { return 0 }
        return statistics.bytesDown >= session.bytesDown ? statistics.bytesDown - session.bytesDown : 0
    }

    var currentSessionUp: UInt64 {
        guard let session = openSession else { return 0 }
        return statistics.bytesUp >= session.bytesUp ? statistics.bytesUp - session.bytesUp : 0
    }

    var averageLatency: Int? {
        guard !latencySamples.isEmpty else { return nil }
        return latencySamples.map(\.milliseconds).reduce(0, +) / latencySamples.count
    }

    // MARK: - Sampling

    private func tick() {
        let now = Date()
        let stats = TunnelStatisticsStore.load()
        let newStatus = SharedSettingsStore.shared.vpnStatus
        trackSession(from: status, to: newStatus, stats: stats, now: now)
        status = newStatus
        statistics = stats

        let connected = newStatus == .connected
        let speed = smoothedSpeed(stats: stats, connected: connected)
        speedSamples.append(SpeedSample(time: now, down: speed.down, up: speed.up))
        if speedSamples.count > Self.maxSpeedSamples {
            speedSamples.removeFirst(speedSamples.count - Self.maxSpeedSamples)
        }
        updateSpeedChartScale()
        if connected {
            sessionPeakDown = max(sessionPeakDown, speed.down)
            sessionPeakUp = max(sessionPeakUp, speed.up)
        }

        latencyTicks += 1
        if connected, latencyTicks >= Self.latencyInterval, !latencyInFlight {
            latencyTicks = 0
            latencyInFlight = true
            Task { [weak self] in
                let latency = await ConnectionQualityService.refreshLatency()
                self?.recordLatency(latency)
            }
        }

        accumulateDailyUsage(stats: stats, now: now)
        ticksSincePersist += 1
        if ticksSincePersist >= 15 {
            ticksSincePersist = 0
            save(dailyUsage, key: Self.dailyKey)
        }
    }

    /// Psiphon reports transferred bytes in bursts, so per-second deltas alternate between
    /// zero and spikes. Speed here is the byte delta averaged over the last few seconds.
    private func smoothedSpeed(stats: TunnelStatistics, connected: Bool) -> (down: UInt64, up: UInt64) {
        defer {
            speedBaselineDown = stats.bytesDown
            speedBaselineUp = stats.bytesUp
        }
        guard connected, let baseDown = speedBaselineDown, let baseUp = speedBaselineUp else {
            recentDeltas.removeAll()
            return (0, 0)
        }
        let down = stats.bytesDown >= baseDown ? stats.bytesDown - baseDown : 0
        let up = stats.bytesUp >= baseUp ? stats.bytesUp - baseUp : 0
        recentDeltas.append((down, up))
        if recentDeltas.count > Self.speedWindow {
            recentDeltas.removeFirst(recentDeltas.count - Self.speedWindow)
        }
        let count = UInt64(recentDeltas.count)
        return (
            recentDeltas.reduce(0) { $0 &+ $1.down } / count,
            recentDeltas.reduce(0) { $0 &+ $1.up } / count
        )
    }

    private var speedBaselineDown: UInt64?
    private var speedBaselineUp: UInt64?
    private var recentDeltas: [(down: UInt64, up: UInt64)] = []
    private static let speedWindow = 3

    private func updateSpeedChartScale() {
        let recentPeak = speedSamples.suffix(Self.scaleWindow).map { Double(max($0.down, $0.up)) }.max() ?? 0
        let target = max(recentPeak * 1.25, Self.minimumChartScale)
        speedChartScale = target > speedChartScale ? target : speedChartScale * 0.8 + target * 0.2
    }

    private static let scaleWindow = 20
    private static let minimumChartScale: Double = 4_000

    private func recordLatency(_ latency: Int) {
        latencyInFlight = false
        guard latency >= 0, status == .connected else { return }
        latencySamples.append(LatencySample(time: Date(), milliseconds: latency))
        if latencySamples.count > Self.maxLatencySamples {
            latencySamples.removeFirst(latencySamples.count - Self.maxLatencySamples)
        }
    }

    /// Cumulative byte counters only grow; a decrease means a reset, which is skipped.
    private func accumulateDailyUsage(stats: TunnelStatistics, now: Date) {
        defer {
            lastBytesDown = stats.bytesDown
            lastBytesUp = stats.bytesUp
        }
        guard let lastBytesDown, let lastBytesUp else { return }
        let down = stats.bytesDown >= lastBytesDown ? stats.bytesDown - lastBytesDown : 0
        let up = stats.bytesUp >= lastBytesUp ? stats.bytesUp - lastBytesUp : 0
        guard down > 0 || up > 0 else { return }
        let key = Self.dayFormatter.string(from: now)
        if let index = dailyUsage.firstIndex(where: { $0.day == key }) {
            dailyUsage[index].bytesDown &+= down
            dailyUsage[index].bytesUp &+= up
        } else {
            dailyUsage.append(DailyUsage(day: key, bytesDown: down, bytesUp: up))
            dailyUsage.sort { $0.day < $1.day }
            if dailyUsage.count > Self.maxDays {
                dailyUsage.removeFirst(dailyUsage.count - Self.maxDays)
            }
        }
    }

    private func trackSession(from old: VPNStatusDisplay, to new: VPNStatusDisplay, stats: TunnelStatistics, now: Date) {
        switch new {
        case .connecting:
            if attemptStartedAt == nil, openSession == nil { attemptStartedAt = now }
        case .connected:
            if openSession == nil {
                let connectedAt = stats.connectedAt ?? now
                openSession = ConnectionSessionRecord(
                    attemptStartedAt: attemptStartedAt ?? connectedAt,
                    connectedAt: connectedAt,
                    endedAt: now,
                    tunnelProtocol: stats.connectedTunnelProtocol,
                    countryCode: stats.connectedCountryCode ?? stats.connectedServerRegion,
                    bytesDown: stats.bytesDown,
                    bytesUp: stats.bytesUp
                )
                attemptStartedAt = nil
                sessionPeakDown = 0
                sessionPeakUp = 0
            } else if var session = openSession {
                if session.tunnelProtocol.isEmpty { session.tunnelProtocol = stats.connectedTunnelProtocol }
                if session.countryCode.isEmpty {
                    session.countryCode = stats.connectedCountryCode ?? stats.connectedServerRegion
                }
                openSession = session
            }
        case .disconnected, .disconnecting, .error:
            if var session = openSession {
                // Session byte fields hold the counters at connect; store the difference.
                session.bytesDown = stats.bytesDown >= session.bytesDown ? stats.bytesDown - session.bytesDown : 0
                session.bytesUp = stats.bytesUp >= session.bytesUp ? stats.bytesUp - session.bytesUp : 0
                session.endedAt = now
                record(session)
                openSession = nil
            } else if let started = attemptStartedAt, old == .connecting, new != .disconnecting {
                record(ConnectionSessionRecord(
                    attemptStartedAt: started,
                    connectedAt: nil,
                    endedAt: now,
                    tunnelProtocol: "",
                    countryCode: "",
                    bytesDown: 0,
                    bytesUp: 0
                ))
                attemptStartedAt = nil
            }
        }
    }

    private func record(_ session: ConnectionSessionRecord) {
        sessions.insert(session, at: 0)
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        save(sessions, key: Self.sessionsKey)
        save(dailyUsage, key: Self.dailyKey)
    }

    // MARK: - Persistence

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults?.set(data, forKey: key)
    }

    #if DEBUG
    /// `-UITestStatsDemo`: fills every chart with plausible data so the layout can be reviewed.
    func loadDemoData() {
        let now = Date()
        speedSamples = (0..<Self.maxSpeedSamples).map { index in
            let t = Double(index)
            let down = 900_000 + 650_000 * sin(t / 9) + 300_000 * sin(t / 3.1) + Double.random(in: 0...180_000)
            let up = 120_000 + 70_000 * sin(t / 7 + 1) + Double.random(in: 0...40_000)
            return SpeedSample(time: now.addingTimeInterval(t - Double(Self.maxSpeedSamples)), down: UInt64(max(0, down)), up: UInt64(max(0, up)))
        }
        latencySamples = (0..<30).map { index in
            LatencySample(time: now.addingTimeInterval(Double(index * 5 - 150)), milliseconds: 70 + Int(25 * sin(Double(index) / 3)) + Int.random(in: 0...20))
        }
        let calendar = Calendar.current
        dailyUsage = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            return DailyUsage(
                day: Self.dayFormatter.string(from: date),
                bytesDown: UInt64.random(in: 80_000_000...900_000_000),
                bytesUp: UInt64.random(in: 8_000_000...90_000_000)
            )
        }.sorted { $0.day < $1.day }
        let protocols = ["OSSH", "OSSH", "QUIC-OSSH", "FRONTED-MEEK-CDN-OSSH", "SSH", "TLS-OSSH", "OSSH"]
        let countries = ["DE", "NL", "GB", "FR", "US", "DE", "CA"]
        sessions = (0..<9).map { index in
            let start = now.addingTimeInterval(Double(-index) * 9_000 - 600)
            let succeeded = index != 3 && index != 7
            return ConnectionSessionRecord(
                attemptStartedAt: start,
                connectedAt: succeeded ? start.addingTimeInterval(Double.random(in: 8...40)) : nil,
                endedAt: start.addingTimeInterval(Double.random(in: 900...5_400)),
                tunnelProtocol: succeeded ? protocols[index % protocols.count] : "",
                countryCode: succeeded ? countries[index % countries.count] : "",
                bytesDown: succeeded ? UInt64.random(in: 20_000_000...600_000_000) : 0,
                bytesUp: succeeded ? UInt64.random(in: 2_000_000...60_000_000) : 0
            )
        }
        sessionPeakDown = speedSamples.map(\.down).max() ?? 0
        sessionPeakUp = speedSamples.map(\.up).max() ?? 0
        updateSpeedChartScale()
        var demoStats = TunnelStatistics()
        demoStats.bytesDown = 18_400_000_000
        demoStats.bytesUp = 1_900_000_000
        demoStats.connectedAt = now.addingTimeInterval(-2_754)
        demoStats.connectedTunnelProtocol = "OSSH"
        statistics = demoStats
        openSession = ConnectionSessionRecord(
            attemptStartedAt: now.addingTimeInterval(-2_780),
            connectedAt: demoStats.connectedAt,
            endedAt: now,
            tunnelProtocol: "OSSH",
            countryCode: "DE",
            bytesDown: demoStats.bytesDown - 412_000_000,
            bytesUp: demoStats.bytesUp - 38_000_000
        )
    }
    #endif
}
