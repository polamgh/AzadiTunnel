import Darwin
import Foundation
import Network
import NetworkExtension

/// Intercepts IPv4 UDP/53 when Secure DNS (DoH) is enabled and answers with
/// RFC 8484 DoH responses. When Secure DNS is off, returns false so Psiphon
/// transparent DNS handles the query (AAAA suppression may still claim packets).
/// Invalid, timed-out, and cancelled DoH paths fail closed.
enum TunnelDnsForwarder {
    private static let queue = DispatchQueue(
        label: "com.polamgh.ali.AzadiTunnel.dns",
        qos: .userInitiated
    )

    private static let requests = RequestRegistry()

    private struct ParsedQuery {
        let ipHeaderLength: Int
        let srcIP: [UInt8]
        let dstIP: [UInt8]
        let srcPort: UInt16
        let dstPort: UInt16
        let dnsPayload: Data
    }

    /// Cancels DNS work before the Psiphon engine is torn down.
    static func stop() {
        requests.cancelAll()
        SecureDNSResolver.cancel()
    }

    static func handleIfDnsQuery(
        packet: Data,
        protocolNumber: NSNumber,
        packetFlow: NEPacketTunnelFlow,
        socksHost: String,
        socksPort: Int,
        packetEngineCapabilities: PacketEngineCapabilities = .ipv4Only
    ) -> Bool {
        guard isDNSDestination(packet) else { return false }

        let settings = SharedSettingsStore.shared.tunnelEffectiveAppSettings
        let secureDNSActive = SecureDNSConfiguration.isActive(settings)

        // When DoH is off, only claim packets we must rewrite (AAAA suppression). Everything else
        // returns false so Psiphon transparent DNS handles the query.
        // When DoH is on, also claim malformed UDP/53 so nothing escapes cleartext.
        guard let parsed = parseDnsQuery(packet: packet) else { return secureDNSActive }
        guard let question = parseQuestion(parsed.dnsPayload) else {
            guard secureDNSActive else { return false }
            if let formerr = SecureDNSWire.errorResponse(for: parsed.dnsPayload, rcode: 1) {
                writeResponse(
                    packet: parsed,
                    dnsPayload: formerr,
                    protocolNumber: protocolNumber,
                    packetFlow: packetFlow
                )
            }
            return true
        }

        let routePlan = PacketEngineRoutePlan.fullTunnel(for: packetEngineCapabilities)
        if routePlan.shouldSuppressAAAA(qtype: question.type) {
            if let emptyAAAA = SecureDNSWire.errorResponse(for: parsed.dnsPayload, rcode: 0) {
                writeResponse(
                    packet: parsed,
                    dnsPayload: emptyAAAA,
                    protocolNumber: protocolNumber,
                    packetFlow: packetFlow
                )
            }
            return true
        }

        guard secureDNSActive else { return false }

        let requestID = UUID()
        let task = Task { [settings] in
            do {
                let result = try await SecureDNSResolver.resolve(
                    wireQuery: parsed.dnsPayload,
                    settings: settings,
                    socksHost: socksHost,
                    socksPort: socksPort
                )
                try Task.checkCancellation()
                writeResponse(
                    packet: parsed,
                    dnsPayload: result.payload,
                    protocolNumber: protocolNumber,
                    packetFlow: packetFlow
                )
            } catch is CancellationError {
                return
            } catch {
                SharedSettingsStore.shared.secureDNSWarning = "blocked"
                guard let servfail = SecureDNSWire.errorResponse(for: parsed.dnsPayload, rcode: 2) else {
                    return
                }
                writeResponse(
                    packet: parsed,
                    dnsPayload: servfail,
                    protocolNumber: protocolNumber,
                    packetFlow: packetFlow
                )
            }
        }
        requests.insert(task, id: requestID)
        Task {
            _ = await task.value
            requests.remove(id: requestID)
        }
        return true
    }

    static func runTest(
        socksHost: String,
        socksPort: Int
    ) async -> (ok: Bool, detail: String) {
        let settings = SharedSettingsStore.shared.tunnelEffectiveAppSettings
        SharedLogger.shared.log(
            .secureDnsTestStarted,
            detail: "mode=doh provider=\(settings.secureDNSProvider.rawValue)"
        )

        let query = SecureDNSConfiguration.exampleComWireQuery
        do {
            let result = try await SecureDNSResolver.resolve(
                wireQuery: query,
                settings: settings,
                socksHost: socksHost,
                socksPort: socksPort
            )
            _ = try SecureDNSWire.validateResponse(result.payload, for: query)
            let detail = "bytes=\(result.payload.count) secure=true"
            SharedLogger.shared.log(.secureDnsTestOk, detail: detail)
            SharedSettingsStore.shared.secureDNSWarning = nil
            return (true, detail)
        } catch {
            let detail = "reason=\(error.localizedDescription)"
            SharedLogger.shared.log(.secureDnsTestFailed, detail: detail)
            return (false, detail)
        }
    }

    private static func parseDnsQuery(packet: Data) -> ParsedQuery? {
        guard packet.count >= 28, packet[0] >> 4 == 4 else { return nil }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard ihl >= 20, packet.count >= ihl + 8, packet[9] == 17 else { return nil }
        let udpOffset = ihl
        let dstPort = UInt16(packet[udpOffset + 2]) << 8 | UInt16(packet[udpOffset + 3])
        guard dstPort == 53 else { return nil }
        let udpLength = Int(UInt16(packet[udpOffset + 4]) << 8 | UInt16(packet[udpOffset + 5]))
        let dnsOffset = udpOffset + 8
        guard udpLength >= 8,
              dnsOffset + udpLength - 8 <= packet.count,
              dnsOffset + udpLength - 8 > dnsOffset else { return nil }
        return ParsedQuery(
            ipHeaderLength: ihl,
            srcIP: Array(packet[12..<16]),
            dstIP: Array(packet[16..<20]),
            srcPort: UInt16(packet[udpOffset]) << 8 | UInt16(packet[udpOffset + 1]),
            dstPort: dstPort,
            dnsPayload: packet.subdata(in: dnsOffset..<(dnsOffset + udpLength - 8))
        )
    }

    private static func isDNSDestination(_ packet: Data) -> Bool {
        guard packet.count >= 24, packet[0] >> 4 == 4, packet[9] == 17 else { return false }
        let ihl = Int(packet[0] & 0x0f) * 4
        guard ihl >= 20, packet.count >= ihl + 4 else { return false }
        let destinationPort = UInt16(packet[ihl + 2]) << 8 | UInt16(packet[ihl + 3])
        return destinationPort == 53
    }

    private static func parseQuestion(_ payload: Data) -> SecureDNSWire.Question? {
        guard let message = try? SecureDNSWire.parse(payload),
              !message.isResponse,
              message.questions.count == 1,
              let question = message.questions.first else {
            return nil
        }
        return question
    }

    private static func writeResponse(
        packet: ParsedQuery,
        dnsPayload: Data,
        protocolNumber: NSNumber,
        packetFlow: NEPacketTunnelFlow
    ) {
        guard let out = buildUdpResponsePacket(from: packet, dnsPayload: dnsPayload) else {
            return
        }
        queue.async {
            packetFlow.writePackets([out], withProtocols: [protocolNumber])
        }
    }

    private static func buildUdpResponsePacket(from query: ParsedQuery, dnsPayload: Data) -> Data? {
        if let response = IPv4UDPResponsePacketBuilder.build(
            ipHeaderLength: query.ipHeaderLength,
            sourceIP: query.srcIP,
            destinationIP: query.dstIP,
            sourcePort: query.srcPort,
            destinationPort: query.dstPort,
            payload: dnsPayload
        ) {
            return response
        }
        let servfail = SecureDNSWire.errorResponse(for: query.dnsPayload, rcode: 2) ?? Data()
        return IPv4UDPResponsePacketBuilder.build(
            ipHeaderLength: query.ipHeaderLength,
            sourceIP: query.srcIP,
            destinationIP: query.dstIP,
            sourcePort: query.srcPort,
            destinationPort: query.dstPort,
            payload: servfail
        )
    }

    private final class RequestRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UUID: Task<Void, Never>] = [:]

        func insert(_ task: Task<Void, Never>, id: UUID) {
            lock.lock()
            tasks[id] = task
            lock.unlock()
        }

        func remove(id: UUID) {
            lock.lock()
            tasks.removeValue(forKey: id)
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            let current = Array(tasks.values)
            tasks.removeAll(keepingCapacity: true)
            lock.unlock()
            for task in current { task.cancel() }
        }
    }
}
