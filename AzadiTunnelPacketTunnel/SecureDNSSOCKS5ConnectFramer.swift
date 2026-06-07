import Darwin
import Foundation
import Network

/// SOCKS5 CONNECT as a Network.framework framer.
///
/// Stack order is: app HTTP bytes -> TLS -> SOCKS5 framer -> TCP to Psiphon SOCKS.
/// This avoids the brittle manual SecureTransport-over-NWConnection path and keeps
/// TLS SNI/certificate validation on the DoH hostname while the TCP dial target is
/// Psiphon's local SOCKS listener.
@available(iOS 15.4, *)
enum SecureDNSSOCKS5ConnectFramer {
    private static let targetHostKey = "secure.dns.socks5.target.host"
    private static let targetPortKey = "secure.dns.socks5.target.port"

    static let definition = NWProtocolFramer.Definition(implementation: Implementation.self)

    static func setTarget(host: String, port: UInt16, on options: NWProtocolFramer.Options) {
        options[targetHostKey] = host
        options[targetPortKey] = Int(port)
        SharedLogger.shared.logRaw(
            "SECURE_DNS_SOCKS5_FRAMER_TARGET",
            detail: "host=\(host) port=\(port)"
        )
    }

    final class Implementation: NWProtocolFramerImplementation {
        static let label = "SecureDNSSOCKS5Connect"

        private enum Phase {
            case start
            case sentGreeting
            case sentConnect
            case connected
            case failed
        }

        private var phase = Phase.start
        private var targetHost = ""
        private var targetPort: UInt16 = 0
        private var didClose = false

        required init(framer: NWProtocolFramer.Instance) {}

        func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
            guard let target = Self.target(from: framer.options), !target.host.isEmpty else {
                fail(framer: framer, reason: "missing_target")
                return .willMarkReady
            }
            targetHost = target.host
            targetPort = target.port

            SharedLogger.shared.logRaw(
                "SECURE_DNS_SOCKS5_FRAMER_START",
                detail: "target=\(targetHost):\(targetPort)"
            )
            framer.writeOutput(data: Data([0x05, 0x01, 0x00]))
            phase = .sentGreeting
            return .willMarkReady
        }

        func wakeup(framer: NWProtocolFramer.Instance) {
            if phase == .connected, !didClose {
                _ = passThroughInput(framer: framer)
            }
        }

        func stop(framer: NWProtocolFramer.Instance) -> Bool {
            didClose = true
            return true
        }

        func cleanup(framer: NWProtocolFramer.Instance) {
            didClose = true
        }

        func handleInput(framer: NWProtocolFramer.Instance) -> Int {
            switch phase {
            case .sentGreeting:
                return handleGreetingReply(framer: framer)
            case .sentConnect:
                return handleConnectReply(framer: framer)
            case .connected:
                return passThroughInput(framer: framer)
            case .start, .failed:
                return 0
            }
        }

        func handleOutput(
            framer: NWProtocolFramer.Instance,
            message: NWProtocolFramer.Message,
            messageLength: Int,
            isComplete: Bool
        ) {
            do {
                try framer.writeOutputNoCopy(length: messageLength)
            } catch {
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SOCKS5_FRAMER_WRITE_FAILED",
                    detail: "target=\(targetHost):\(targetPort) reason=\(error.localizedDescription)"
                )
            }
        }

        private func handleGreetingReply(framer: NWProtocolFramer.Instance) -> Int {
            var response = Data()
            _ = framer.parseInput(minimumIncompleteLength: 2, maximumLength: 2) { buffer, _ in
                guard let buffer, buffer.count >= 2 else { return 0 }
                response = Data(buffer)
                return 2
            }
            guard response.count == 2 else { return 2 }
            guard response[0] == 0x05, response[1] == 0x00 else {
                fail(framer: framer, reason: "greeting_rejected")
                return 0
            }

            var request = Data([0x05, 0x01, 0x00])
            if let ipv4 = ipv4Bytes(targetHost) {
                request.append(0x01)
                request.append(contentsOf: ipv4)
            } else if let ipv6 = ipv6Bytes(targetHost) {
                request.append(0x04)
                request.append(contentsOf: ipv6)
            } else {
                let hostBytes = Array(targetHost.utf8.prefix(255))
                request.append(0x03)
                request.append(UInt8(hostBytes.count))
                request.append(contentsOf: hostBytes)
            }
            request.append(UInt8((targetPort >> 8) & 0xff))
            request.append(UInt8(targetPort & 0xff))
            framer.writeOutput(data: request)
            phase = .sentConnect
            return 0
        }

        private func handleConnectReply(framer: NWProtocolFramer.Instance) -> Int {
            var header = Data()
            _ = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                guard let buffer, buffer.count >= 4 else { return 0 }
                header = Data(buffer)
                return 4
            }
            guard header.count == 4 else { return 4 }
            guard header[0] == 0x05, header[1] == 0x00 else {
                let rep = header.count > 1 ? String(header[1]) : "?"
                fail(framer: framer, reason: "connect_rejected rep=\(rep)")
                return 0
            }

            let addressLength: Int
            switch header[3] {
            case 0x01:
                addressLength = 4
            case 0x04:
                addressLength = 16
            case 0x03:
                var length = 0
                _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { buffer, _ in
                    guard let buffer, buffer.count == 1 else { return 0 }
                    length = Int(buffer[0])
                    return 1
                }
                guard length > 0 else { return 1 }
                addressLength = length
            default:
                fail(framer: framer, reason: "bad_address_type")
                return 0
            }

            var consumedAddress = false
            _ = framer.parseInput(
                minimumIncompleteLength: addressLength + 2,
                maximumLength: addressLength + 2
            ) { buffer, _ in
                guard let buffer, buffer.count >= addressLength + 2 else { return 0 }
                consumedAddress = true
                return addressLength + 2
            }
            guard consumedAddress else { return addressLength + 2 }

            SharedLogger.shared.logRaw(
                "SECURE_DNS_SOCKS5_FRAMER_CONNECTED",
                detail: "target=\(targetHost):\(targetPort)"
            )
            phase = .connected
            framer.markReady()
            _ = passThroughInput(framer: framer)
            return 0
        }

        private func passThroughInput(framer: NWProtocolFramer.Instance) -> Int {
            var totalConsumed = 0
            while !didClose {
                var available = 0
                var streamComplete = false
                let peeked = framer.parseInput(
                    minimumIncompleteLength: 1,
                    maximumLength: 65_535
                ) { buffer, isComplete in
                    guard let buffer, !buffer.isEmpty else { return 0 }
                    available = buffer.count
                    streamComplete = isComplete
                    return 0
                }
                guard peeked, available > 0 else { break }

                let message = NWProtocolFramer.Message(definition: SecureDNSSOCKS5ConnectFramer.definition)
                guard framer.deliverInputNoCopy(
                    length: available,
                    message: message,
                    isComplete: streamComplete
                ) else {
                    break
                }

                _ = framer.parseInput(
                    minimumIncompleteLength: 1,
                    maximumLength: 65_535
                ) { _, _ in
                    totalConsumed += available
                    return available
                }
            }
            return totalConsumed
        }

        private func fail(framer: NWProtocolFramer.Instance, reason: String) {
            didClose = true
            phase = .failed
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SOCKS5_FRAMER_FAILED",
                detail: "target=\(targetHost):\(targetPort) reason=\(reason)"
            )
            framer.markFailed(error: NWError.posix(.ECONNREFUSED))
        }

        private static func target(from options: NWProtocolFramer.Options) -> (host: String, port: UInt16)? {
            guard let host = options[SecureDNSSOCKS5ConnectFramer.targetHostKey] as? String else {
                return nil
            }
            if let port = options[SecureDNSSOCKS5ConnectFramer.targetPortKey] as? UInt16 {
                return (host, port)
            }
            if let port = options[SecureDNSSOCKS5ConnectFramer.targetPortKey] as? Int,
               let parsed = UInt16(exactly: port) {
                return (host, parsed)
            }
            return nil
        }

        private func ipv4Bytes(_ host: String) -> [UInt8]? {
            var addr = in_addr()
            guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
            return withUnsafeBytes(of: addr.s_addr) { Array($0) }
        }

        private func ipv6Bytes(_ host: String) -> [UInt8]? {
            guard host.contains(":"), let address = IPv6Address(host) else { return nil }
            return Array(address.rawValue)
        }
    }
}
