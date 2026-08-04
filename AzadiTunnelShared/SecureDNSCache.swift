import Foundation

/// Bounded, actor-isolated DNS response cache. Responses are stored as complete wire messages;
/// callers only rewrite the transaction ID for a cache hit.
actor SecureDNSCache {
    struct Entry {
        let response: Data
        let expiresAt: TimeInterval
        var lastUsedAt: TimeInterval
    }

    let maxEntries: Int
    let maxBytes: Int
    private var entries: [Data: Entry] = [:]
    private var byteCount = 0

    init(maxEntries: Int = 128, maxBytes: Int = 1_048_576) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
    }

    func value(for key: Data, now: TimeInterval = SecureDNSMonotonicClock.now) -> Data? {
        purgeExpired(now: now)
        guard var entry = entries[key] else { return nil }
        entry.lastUsedAt = now
        entries[key] = entry
        return entry.response
    }

    func insert(
        response: Data,
        for key: Data,
        lifetime: TimeInterval,
        now: TimeInterval = SecureDNSMonotonicClock.now
    ) {
        guard lifetime > 0, !response.isEmpty, response.count <= maxBytes else { return }
        purgeExpired(now: now)
        if let old = entries.removeValue(forKey: key) {
            byteCount -= old.response.count
        }

        entries[key] = Entry(
            response: response,
            expiresAt: now + lifetime,
            lastUsedAt: now
        )
        byteCount += response.count
        evictIfNeeded()
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    func count(now: TimeInterval = SecureDNSMonotonicClock.now) -> Int {
        purgeExpired(now: now)
        return entries.count
    }

    func bytes(now: TimeInterval = SecureDNSMonotonicClock.now) -> Int {
        purgeExpired(now: now)
        return byteCount
    }

    private func purgeExpired(now: TimeInterval) {
        let expired = entries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        for key in expired {
            if let removed = entries.removeValue(forKey: key) {
                byteCount -= removed.response.count
            }
        }
    }

    private func evictIfNeeded() {
        while entries.count > maxEntries || byteCount > maxBytes {
            guard let victim = entries.min(by: { lhs, rhs in
                lhs.value.lastUsedAt < rhs.value.lastUsedAt
            })?.key else { break }
            if let removed = entries.removeValue(forKey: victim) {
                byteCount -= removed.response.count
            }
        }
    }
}
