import Foundation

/// Ordered, bounded packet queue shared by the Network Extension callback
/// bridge. Capacity checks and append happen under one condition lock so the
/// bridge never drops a packet because a concurrent callback observed stale
/// queue state.
final class PsiphonPacketTunnelPacketQueue: @unchecked Sendable {
    enum EnqueueResult: Equatable {
        case enqueued
        case closed
        case overflow
    }

    private let condition = NSCondition()
    private let capacity: Int
    // `head` advances through the array instead of shifting every remaining
    // packet on each dequeue. Compaction is deliberately bounded so the
    // backing storage stays below roughly two queue capacities while the
    // live-count invariant remains O(1).
    private var packets: [Data?] = []
    private var head = 0
    private var closed = false
    private var terminalError: NSError?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        packets.reserveCapacity(self.capacity)
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    var error: NSError? {
        condition.lock()
        defer { condition.unlock() }
        return terminalError
    }

    func enqueue(_ packet: Data) -> EnqueueResult {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return .closed }
        guard packets.count - head < capacity else { return .overflow }
        packets.append(packet)
        condition.signal()
        return .enqueued
    }

    func dequeue() throws -> Data {
        condition.lock()
        while head >= packets.count && !closed {
            condition.wait()
        }

        if head < packets.count {
            let packet = packets[head]!
            packets[head] = nil
            head += 1
            compactIfNeeded()
            condition.unlock()
            return packet
        }

        let error = terminalError ?? NSError(
            domain: "AzadiTunnel.PsiphonPacketTunnel",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Packet tunnel flow closed"]
        )
        condition.unlock()
        throw error
    }

    /// Closes the queue and discards packets only during explicit shutdown.
    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        packets.removeAll(keepingCapacity: false)
        head = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Fails the queue without discarding already queued packets. Returns true
    /// only for the first failure so the provider receives one cancellation.
    func fail(_ error: NSError) -> Bool {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return false
        }
        terminalError = error
        closed = true
        condition.broadcast()
        condition.unlock()
        return true
    }

    private func compactIfNeeded() {
        guard head > 0,
              head >= 256 || head >= capacity,
              head * 2 >= packets.count else {
            return
        }
        packets = Array(packets[head...])
        head = 0
    }
}
