import Foundation
import Network

/// HTTP client for Psiphon's local forward proxy (absolute-URI GET style).
enum TunnelHttpProxyClient {
    enum HttpProxyError: LocalizedError {
        case requestFailed
        case badResponse(status: String)

        var errorDescription: String? {
            switch self {
            case .requestFailed: return "request_failed"
            case .badResponse(let status): return "bad_status:\(status)"
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.polamgh.ali.AzadiTunnel.httpproxy")

    static func get(url: String, proxyPort: Int, retries: Int = 4) async throws -> Data {
        var lastError: Error = HttpProxyError.requestFailed
        for attempt in 0..<retries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            do {
                return try await fetch(url: url, proxyPort: proxyPort)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetch(url: String, proxyPort: Int) async throws -> Data {
        guard let parsed = URL(string: url), let host = parsed.host else {
            throw HttpProxyError.badResponse(status: "invalid_url")
        }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        let absoluteURI: String
        if let query = parsed.query, !query.isEmpty {
            absoluteURI = "http://\(host)\(path)?\(query)"
        } else {
            absoluteURI = "http://\(host)\(path)"
        }

        let conn = NWConnection(
            to: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(proxyPort))),
            using: .tcp
        )
        try await waitReady(conn)
        defer { conn.cancel() }

        let request =
            "GET \(absoluteURI) HTTP/1.1\r\n" +
            "Host: \(host)\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
        try await sendAll(conn, data: Data(request.utf8))
        let raw = try await readAll(conn, limit: 65536)
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            let preview = String(data: raw.prefix(80), encoding: .utf8) ?? "len=\(raw.count)"
            throw HttpProxyError.badResponse(status: "no_headers:\(preview)")
        }
        let statusLine = String(data: raw.subdata(in: 0..<min(raw.count, 64)), encoding: .utf8) ?? ""
        guard statusLine.contains(" 200 ") || statusLine.contains(" 204 ") else {
            throw HttpProxyError.badResponse(status: statusLine.trimmingCharacters(in: .newlines))
        }
        return raw.subdata(in: headerEnd.upperBound..<raw.count)
    }

    private static func waitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: err)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: HttpProxyError.requestFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func sendAll(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private static func readAll(_ connection: NWConnection, limit: Int) async throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(25)
        while buffer.count < limit, Date() < deadline {
            let (chunk, done) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data, Bool), any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: limit - buffer.count) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: (data ?? Data(), isComplete)) }
                }
            }
            if !chunk.isEmpty { buffer.append(chunk) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if done { break }
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return buffer
    }
}
