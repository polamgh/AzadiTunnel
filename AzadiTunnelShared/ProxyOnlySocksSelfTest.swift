import Foundation
import Network

/// Probes a SOCKS5 listener with a minimal RFC 1928 greeting (no CONNECT).
enum ProxyOnlySocksSelfTest {
    struct Result: Equatable {
        let host: String
        let port: Int
        let handshakeOK: Bool
        let logDetail: String
        let userMessage: String
    }

    static func probe(host: String, port: Int, timeoutSeconds: TimeInterval = 6) async -> Result {
        guard (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return Result(
                host: host,
                port: port,
                handshakeOK: false,
                logDetail: "host=\(host) port=\(port) status=invalid_port",
                userMessage: "Invalid port"
            )
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )

        do {
            try await waitReady(connection, timeoutSeconds: timeoutSeconds)
            try await sendAll(connection, Data([0x05, 0x01, 0x00]))
            let reply = try await receiveExactly(connection, count: 2, timeoutSeconds: timeoutSeconds)
            connection.cancel()

            let ok = reply.count == 2 && reply[0] == 0x05 && reply[1] == 0x00
            let detail = "host=\(host) port=\(port) status=\(ok ? "handshake_ok" : "bad_reply") reply=\(reply.map(String.init).joined(separator: ","))"
            return Result(
                host: host,
                port: port,
                handshakeOK: ok,
                logDetail: detail,
                userMessage: ok ? "SOCKS5 handshake OK" : "SOCKS5 handshake failed (bad reply)"
            )
        } catch {
            connection.cancel()
            let detail = "host=\(host) port=\(port) status=failed error=\(error.localizedDescription)"
            return Result(
                host: host,
                port: port,
                handshakeOK: false,
                logDetail: detail,
                userMessage: "Connection failed: \(error.localizedDescription)"
            )
        }
    }

    private static func waitReady(_ connection: NWConnection, timeoutSeconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    cont.resume()
                case .failed(let error):
                    finished = true
                    cont.resume(throwing: error)
                case .cancelled:
                    finished = true
                    cont.resume(throwing: SelfError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                cont.resume(throwing: SelfError.timeout)
            }
        }
    }

    private static func sendAll(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private static func receiveExactly(
        _ connection: NWConnection,
        count: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var buffer = Data()
            var finished = false

            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, _, error in
                    guard !finished else { return }
                    if let error {
                        finished = true
                        cont.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                    }
                    if buffer.count >= count {
                        finished = true
                        cont.resume(returning: buffer.prefix(count))
                        return
                    }
                    pump()
                }
            }

            pump()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                cont.resume(throwing: SelfError.timeout)
            }
        }
    }

    private enum SelfError: LocalizedError {
        case timeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .timeout: return "timeout"
            case .cancelled: return "cancelled"
            }
        }
    }
}

/// Resolves proxy addresses shown to users and used for same-device binding.
enum SameDeviceProxyAddress {
    /// Loopback inside the packet-tunnel extension is not reachable from the containing app or other apps.
    static let extensionLoopbackNote =
        "127.0.0.1 in the Network Extension is not reachable from Telegram or other apps on this iPhone."

    /// Host other apps on this iPhone should use (Wi-Fi IP of en0).
    static func reachableHost(boundHost: String?) -> String? {
        if let boundHost,
           !boundHost.isEmpty,
           boundHost != "127.0.0.1",
           boundHost != "0.0.0.0" {
            return boundHost
        }
        return LocalNetworkAddress.wifiIPv4()
    }
}
