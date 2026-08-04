import Foundation

/// Monotonic deadline used by every DoH attempt. `systemUptime` is not affected by wall-clock
/// changes, NTP corrections, or device timezone updates.
struct SecureDNSDeadline: Equatable, Sendable {
    let uptime: TimeInterval

    init(after interval: TimeInterval, now: TimeInterval = SecureDNSMonotonicClock.now) {
        uptime = now + max(0, interval)
    }

    var remaining: TimeInterval {
        max(0, uptime - SecureDNSMonotonicClock.now)
    }
}

enum SecureDNSMonotonicClock {
    nonisolated static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
