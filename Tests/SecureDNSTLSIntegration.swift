import Foundation
import Network

@main
struct SecureDNSTLSIntegration {
    private static let wireBody = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01])
    private static let responseBody = Data([0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])

    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4,
                  let port = Int(arguments[1]),
                  let certificate = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
                throw IntegrationError.invalidArguments
            }
            let captureDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
            let normalRequest = request(delay: false)
            let delayedRequest = request(delay: true)

            try await exerciseSuccessfulRequest(port: port, certificate: certificate, request: normalRequest)
            try await exerciseCancellation(port: port, certificate: certificate, request: delayedRequest)
            try await exerciseTimeout(port: port, certificate: certificate, request: delayedRequest)
            try verifyCapturedRequests(in: captureDirectory, normal: normalRequest, delayed: delayedRequest)
            print("SecureDNSTLSIntegration: PASS")
        } catch {
            fputs("SecureDNSTLSIntegration: FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func request(delay: Bool) -> Data {
        let extra = delay ? "X-Test-Delay: 2\r\n" : ""
        let header =
            "POST /dns-query HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Content-Type: application/dns-message\r\n" +
            "Accept: application/dns-message\r\n" +
            extra +
            "Content-Length: \(wireBody.count)\r\n" +
            "Connection: close\r\n\r\n"
        var result = Data(header.utf8)
        result.append(wireBody)
        return result
    }

    private static func exerciseSuccessfulRequest(
        port: Int,
        certificate: Data,
        request: Data
    ) async throws {
        let (connection, tls) = try await openTLS(port: port, certificate: certificate)
        defer { tls.cancel(); connection.cancel() }
        try tls.write(request, timeout: 1)

        var response = Data()
        while true {
            response.append(try tls.readSome(maxCount: 4096, timeout: 1))
            if response.count > 4096 { throw IntegrationError.responseTooLarge }
            if let header = response.range(of: Data("\r\n\r\n".utf8)),
               response.count >= header.upperBound + responseBody.count {
                break
            }
        }
        guard response.range(of: Data("Content-Type: application/dns-message".utf8)) != nil,
              response.suffix(responseBody.count) == responseBody else {
            throw IntegrationError.invalidResponse
        }
    }

    private static func exerciseCancellation(
        port: Int,
        certificate: Data,
        request: Data
    ) async throws {
        let (connection, tls) = try await openTLS(port: port, certificate: certificate)
        defer { tls.cancel(); connection.cancel() }
        try tls.write(request, timeout: 1)

        let reader = Task<Void, Error> {
            try await withTaskCancellationHandler(operation: {
                _ = try tls.readSome(maxCount: 4096, timeout: 5)
            }, onCancel: {
                tls.cancel()
            })
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = SecureDNSMonotonicClock.now
        reader.cancel()
        var cancelled = false
        do {
            try await reader.value
        } catch {
            cancelled = true
        }
        guard cancelled else {
            throw IntegrationError.cancellationNotObserved
        }
        guard SecureDNSMonotonicClock.now - started < 1 else {
            throw IntegrationError.cancellationTooSlow
        }
    }

    private static func exerciseTimeout(
        port: Int,
        certificate: Data,
        request: Data
    ) async throws {
        let (connection, tls) = try await openTLS(port: port, certificate: certificate)
        defer { tls.cancel(); connection.cancel() }
        try tls.write(request, timeout: 1)
        let started = SecureDNSMonotonicClock.now
        do {
            let data = try tls.readSome(maxCount: 4096, timeout: 0.2)
            if data.isEmpty { return }
            throw IntegrationError.timeoutNotObserved
        } catch is IntegrationError {
            throw IntegrationError.timeoutNotObserved
        } catch {
            guard SecureDNSMonotonicClock.now - started < 0.7 else {
                throw IntegrationError.timeoutTooSlow
            }
        }
    }

    private static func openTLS(port: Int, certificate: Data) async throws -> (NWConnection, NWConnectionTLSClient) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw IntegrationError.invalidArguments
        }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: nwPort,
            using: .tcp
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: IntegrationError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "azadi.secure-dns.tls-test"))
        }
        let tls = NWConnectionTLSClient(connection: connection, hostname: "localhost", trustedRootDER: certificate)
        try tls.handshake(timeout: 2)
        return (connection, tls)
    }

    private static func verifyCapturedRequests(in directory: URL, normal: Data, delayed: Data) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count == 3 else { throw IntegrationError.duplicateOrMissingWrites(files.count) }
        let requests = try files.map { try Data(contentsOf: $0) }
        guard requests.filter({ $0 == normal }).count == 1,
              requests.filter({ $0 == delayed }).count == 2 else {
            throw IntegrationError.requestBytesChanged
        }
        let sniFile = directory.deletingLastPathComponent().appendingPathComponent("sni.txt")
        let sni = try String(contentsOf: sniFile, encoding: .utf8)
        guard sni.split(whereSeparator: \.isNewline).allSatisfy({ $0 == "localhost" }) else {
            throw IntegrationError.sniMismatch
        }
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    private enum IntegrationError: Error, CustomStringConvertible {
        case invalidArguments
        case connectionCancelled
        case invalidResponse
        case responseTooLarge
        case cancellationNotObserved
        case cancellationTooSlow
        case timeoutNotObserved
        case timeoutTooSlow
        case duplicateOrMissingWrites(Int)
        case requestBytesChanged
        case sniMismatch

        var description: String {
            switch self {
            case .invalidArguments: return "invalid arguments"
            case .connectionCancelled: return "connection cancelled before ready"
            case .invalidResponse: return "invalid TLS/HTTP response"
            case .responseTooLarge: return "response too large"
            case .cancellationNotObserved: return "cancellation was not observed"
            case .cancellationTooSlow: return "cancellation exceeded bound"
            case .timeoutNotObserved: return "timeout was not observed"
            case .timeoutTooSlow: return "timeout exceeded bound"
            case .duplicateOrMissingWrites(let count): return "expected 3 captured requests, got \(count)"
            case .requestBytesChanged: return "request bytes changed or were duplicated"
            case .sniMismatch: return "TLS SNI did not match localhost"
            }
        }
    }
}
