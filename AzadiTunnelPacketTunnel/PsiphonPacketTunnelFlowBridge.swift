import Darwin
import Foundation
import NetworkExtension

/// Adapts Apple's public NEPacketTunnelFlow to Psiphon's native packet
/// transport callback. The bridge is deliberately a bounded, loss-intolerant
/// queue: a full queue fails the tunnel instead of dropping packets.
final class PsiphonPacketTunnelFlowBridge: PsiphonPacketTunnelIO, @unchecked Sendable {
    typealias DNSHandler = (_ packet: Data, _ protocolNumber: NSNumber) -> Bool

    private static let queueLimit = 4096
    private let packetFlow: NEPacketTunnelFlow
    let mtu: Int
    private let packetQueue = PsiphonPacketTunnelPacketQueue(capacity: queueLimit)
    private let stateLock = NSLock()
    private var started = false
    private var readLoopStarted = false
    private var dnsHandler: DNSHandler?
    private var failureHandler: ((NSError) -> Void)?
    private var diagnosticCounters: [String: (packets: UInt64, bytes: UInt64)] = [:]

    init(packetFlow: NEPacketTunnelFlow, mtu: Int) {
        self.packetFlow = packetFlow
        self.mtu = mtu
    }

    func setDNSHandler(_ handler: DNSHandler?) {
        stateLock.lock()
        dnsHandler = handler
        stateLock.unlock()
    }

    func setFailureHandler(_ handler: ((NSError) -> Void)?) {
        stateLock.lock()
        failureHandler = handler
        stateLock.unlock()
    }

    /// Starts exactly one outstanding readPackets operation. The core may
    /// already be blocked in readPacket; starting the loop wakes it as soon as
    /// Network Extension supplies the first packet.
    func start() {
        stateLock.lock()
        guard !packetQueue.isClosed, !readLoopStarted else {
            stateLock.unlock()
            return
        }
        started = true
        readLoopStarted = true
        stateLock.unlock()
        scheduleRead()
    }

    func readPacket() throws -> Data {
        let packet = try packetQueue.dequeue()
        recordDiagnostic(stage: "swift_callback_read", bytes: packet.count)
        TunnelStatisticsStore.recordPacketBytes(down: 0, up: packet.count)
        return packet
    }

    func writePacket(_ packet: Data) throws {
        guard !packet.isEmpty,
              let protocolNumber = PsiphonPacketTunnelCapabilities.protocolNumber(for: packet) else {
            let error = Self.error(code: 4, reason: "invalid_ip_packet")
            fail(error)
            throw error
        }

        stateLock.lock()
        if packetQueue.isClosed {
            let error = packetQueue.error ?? Self.error(code: 3, reason: "packet_tunnel_closed")
            stateLock.unlock()
            throw error
        }
        packetFlow.writePackets([packet], withProtocols: [protocolNumber])
        stateLock.unlock()
        recordDiagnostic(stage: "ne_flow_write_submitted", bytes: packet.count)
        TunnelStatisticsStore.recordPacketBytes(down: packet.count, up: 0)
    }

    func failPacketTunnel(_ error: NSError) {
        fail(error)
    }

    func close() {
        stateLock.lock()
        started = false
        packetQueue.close()
        stateLock.unlock()
    }

    private func scheduleRead() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.receive(packets: packets, protocols: protocols)
        }
    }

    private func receive(packets: [Data], protocols: [NSNumber]) {
        for (index, packet) in packets.enumerated() {
            guard !packet.isEmpty,
                  let inferredProtocol = PsiphonPacketTunnelCapabilities.protocolNumber(for: packet) else {
                fail(Self.error(code: 5, reason: "invalid_or_unknown_ip_version"))
                return
            }

            if protocols.indices.contains(index), protocols[index].intValue != inferredProtocol.intValue {
                fail(Self.error(code: 7, reason: "packet_protocol_family_mismatch"))
                return
            }
            let protocolNumber = inferredProtocol
            recordDiagnostic(stage: "ne_flow_read", bytes: packet.count)

            stateLock.lock()
            let active = !packetQueue.isClosed
            let handler = dnsHandler
            stateLock.unlock()
            guard active else { return }

            if handler?(packet, protocolNumber) == true {
                continue
            }

            // enqueue performs the closed/capacity check and append atomically
            // under one condition lock. There is no stale pre-check and no
            // silent drop at the callback boundary.
            switch packetQueue.enqueue(packet) {
            case .enqueued:
                break
            case .closed:
                return
            case .overflow:
                fail(Self.error(code: 6, reason: "packet_queue_overflow"))
                return
            }
        }

        stateLock.lock()
        let shouldContinue = started && !packetQueue.isClosed
        stateLock.unlock()
        if shouldContinue {
            scheduleRead()
        }
    }

    private func fail(_ error: NSError) {
        stateLock.lock()
        guard packetQueue.fail(error) else {
            stateLock.unlock()
            return
        }

        started = false
        let handler = failureHandler
        stateLock.unlock()

        SharedLogger.shared.logRaw(
            "PSIPHON_PACKET_TUNNEL_FAILED",
            detail: "code=\(error.code) reason=\(error.localizedDescription)"
        )
        handler?(error)
    }

    /// Emits only cumulative packet/byte counts. The first packet and powers
    /// of two are logged so device diagnostics stay useful without logging
    /// packet payloads, protocol metadata, or destinations at line rate.
    private func recordDiagnostic(stage: String, bytes: Int) {
        stateLock.lock()
        var counter = diagnosticCounters[stage] ?? (packets: 0, bytes: 0)
        counter.packets &+= 1
        counter.bytes &+= UInt64(bytes)
        diagnosticCounters[stage] = counter
        let shouldLog = counter.packets == 1 || counter.packets.nonzeroBitCount == 1
        stateLock.unlock()

        guard shouldLog else { return }
        SharedLogger.shared.logRaw(
            "PSIPHON_PACKET_DATA_PLANE",
            detail: "stage=\(stage) packets=\(counter.packets) bytes=\(counter.bytes)"
        )
    }

    private static func error(code: Int, reason: String) -> NSError {
        NSError(
            domain: "AzadiTunnel.PsiphonPacketTunnel",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}
