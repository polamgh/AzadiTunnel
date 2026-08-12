import Darwin
import Foundation

@main
struct PacketTunnelBridgeTests {
    static func main() {
        testOrderedDelivery()
        testOverflowAndCloseBoundary()
        testCloseUnblocksRead()
        testIPv4IPv6ProtocolValues()
        testPacketTransportReadiness()
        print("packet tunnel bridge tests: ok")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("packet tunnel bridge tests: FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func testOrderedDelivery() {
        let queue = PsiphonPacketTunnelPacketQueue(capacity: 4)
        let first = Data([0x45, 0x01])
        let second = Data([0x60, 0x02])
        require(queue.enqueue(first) == .enqueued, "first packet enqueue")
        require(queue.enqueue(second) == .enqueued, "second packet enqueue")
        require((try? queue.dequeue()) == first, "first packet order")
        require((try? queue.dequeue()) == second, "second packet order")
    }

    private static func testOverflowAndCloseBoundary() {
        let queue = PsiphonPacketTunnelPacketQueue(capacity: 2)
        require(queue.enqueue(Data([1])) == .enqueued, "capacity packet 1")
        require(queue.enqueue(Data([2])) == .enqueued, "capacity packet 2")
        require(queue.enqueue(Data([3])) == .overflow, "exact overflow boundary")
        require((try? queue.dequeue()) == Data([1]), "first packet before refill")
        require(queue.enqueue(Data([3])) == .enqueued, "live-count refill after dequeue")
        require((try? queue.dequeue()) == Data([2]), "order after refill")
        require((try? queue.dequeue()) == Data([3]), "refilled packet order")

        let failure = NSError(domain: "PacketTunnelBridgeTests", code: 1)
        require(queue.fail(failure), "first queue failure")
        require(!queue.fail(failure), "queue failure is one-shot")
        require(queue.enqueue(Data([4])) == .closed, "write-after-close rejected")
        require((try? queue.dequeue()) == nil, "failed queue reports terminal error")

        let hotQueue = PsiphonPacketTunnelPacketQueue(capacity: 4)
        for index in 0 ..< 20_000 {
            let value = UInt8(truncatingIfNeeded: index)
            require(hotQueue.enqueue(Data([value])) == .enqueued, "steady-state enqueue (index)")
            require((try? hotQueue.dequeue()) == Data([value]), "steady-state order (index)")
        }
    }

    private static func testCloseUnblocksRead() {
        let queue = PsiphonPacketTunnelPacketQueue(capacity: 1)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let errorLock = NSLock()
        var readError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            do {
                _ = try queue.dequeue()
            } catch {
                errorLock.lock()
                readError = error
                errorLock.unlock()
            }
            finished.signal()
        }

        require(started.wait(timeout: .now() + 1) == .success, "reader started")
        queue.close()
        require(finished.wait(timeout: .now() + 1) == .success, "close unblocks reader")
        errorLock.lock()
        let didReadError = readError != nil
        errorLock.unlock()
        require(didReadError, "close returns an error to reader")
    }

    private static func testIPv4IPv6ProtocolValues() {
        var ipv4TCP = Data(repeating: 0, count: 20)
        ipv4TCP[0] = 0x45
        ipv4TCP[9] = 6
        require(PsiphonPacketTunnelCapabilities.kind(of: ipv4TCP) == .ipv4TCP, "IPv4 TCP classification")
        require((PsiphonPacketTunnelCapabilities.protocolNumber(for: ipv4TCP)?.intValue ?? -1) == Int(AF_INET), "IPv4 protocol value")

        var ipv4UDP = Data(repeating: 0, count: 20)
        ipv4UDP[0] = 0x45
        ipv4UDP[9] = 17
        require(PsiphonPacketTunnelCapabilities.kind(of: ipv4UDP) == .ipv4UDP, "IPv4 UDP classification")

        var ipv6TCP = Data(repeating: 0, count: 40)
        ipv6TCP[0] = 0x60
        ipv6TCP[6] = 6
        require(PsiphonPacketTunnelCapabilities.kind(of: ipv6TCP) == .ipv6TCP, "IPv6 TCP classification")
        require((PsiphonPacketTunnelCapabilities.protocolNumber(for: ipv6TCP)?.intValue ?? -1) == Int(AF_INET6), "IPv6 protocol value")

        var ipv6UDP = Data(repeating: 0, count: 40)
        ipv6UDP[0] = 0x60
        ipv6UDP[6] = 17
        require(PsiphonPacketTunnelCapabilities.kind(of: ipv6UDP) == .ipv6UDP, "IPv6 UDP classification")
    }

    private static func testPacketTransportReadiness() {
        require(!PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: true,
            hasPacketProvider: true,
            packetTransportReady: false,
            hasSocks: true,
            coreConnected: true
        ), "SOCKS must not mask an unavailable packet transport")
        require(PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: true,
            hasPacketProvider: true,
            packetTransportReady: true,
            hasSocks: true,
            coreConnected: true
        ), "native packet transport and secure DNS readiness")
        require(!PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: true,
            hasPacketProvider: true,
            packetTransportReady: true,
            hasSocks: false,
            coreConnected: true
        ), "optional in-tunnel DoH requires SOCKS readiness when Secure DNS is enabled")
        require(!PsiphonPacketTunnelCapabilities.isReadyForStart(
            packetMode: true,
            hasPacketProvider: true,
            packetTransportReady: true,
            hasSocks: true,
            coreConnected: false
        ), "core connection is required")
    }
}
