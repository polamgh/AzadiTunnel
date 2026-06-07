import Darwin
import Foundation
import Network
import Security

/// Minimal TLS client over an established TCP stream (e.g. after SOCKS CONNECT) for DoT.
final class NWConnectionTLSClient: @unchecked Sendable {
    private let connection: NWConnection
    private let hostname: String
    private var sslContext: SSLContext?
    private let ioLock = NSLock()
    private var receiveBuffer = Data()
    private var receiveWaiters: [CheckedContinuation<Data, Error>] = []
    private var isReceiving = false

    init(connection: NWConnection, hostname: String) {
        self.connection = connection
        self.hostname = hostname
    }

    func handshake(timeout: TimeInterval = 6) throws {
        guard let ctx = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            throw SecureDNSTransportError.tlsHandshakeFailed("create_context")
        }
        SSLSetPeerDomainName(ctx, hostname, hostname.utf8.count)
        let retained = Unmanaged.passRetained(self)
        SSLSetConnection(ctx, retained.toOpaque())
        SSLSetIOFuncs(ctx, Self.sslRead, Self.sslWrite)
        sslContext = ctx

        let deadline = Date().addingTimeInterval(timeout)
        var status = SSLHandshake(ctx)
        var attempts = 0
        while status == errSSLWouldBlock, attempts < 200, Date() < deadline {
            pumpReceive()
            Thread.sleep(forTimeInterval: 0.02)
            status = SSLHandshake(ctx)
            attempts += 1
        }
        guard status == noErr else {
            retained.release()
            if status == errSSLWouldBlock {
                throw SecureDNSTransportError.tlsHandshakeFailed("timeout attempts=\(attempts)")
            }
            throw SecureDNSTransportError.tlsHandshakeFailed("status=\(status)")
        }
        retained.release()
    }

    func write(_ data: Data) throws {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        var processed = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var status = SSLWrite(ctx, base, data.count, &processed)
            var attempts = 0
            while status == errSSLWouldBlock, attempts < 200 {
                pumpReceive()
                Thread.sleep(forTimeInterval: 0.01)
                status = SSLWrite(ctx, base.advanced(by: processed), data.count - processed, &processed)
                attempts += 1
            }
            guard status == noErr else {
                throw SecureDNSTransportError.tlsWriteFailed("status=\(status)")
            }
        }
    }

    func read(count: Int, timeout: TimeInterval = 15) throws -> Data {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        var buffer = Data(count: count)
        var readCount = 0
        let deadline = Date().addingTimeInterval(timeout)
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while readCount < count, Date() < deadline {
                var chunk = 0
                let status = SSLRead(ctx, base.advanced(by: readCount), count - readCount, &chunk)
                if chunk > 0, status == noErr || status == errSSLWouldBlock {
                    readCount += chunk
                    continue
                }
                if status == errSSLClosedGraceful, readCount > 0 { break }
                if status != errSSLWouldBlock, status != noErr {
                    throw SecureDNSTransportError.tlsReadFailed("status=\(status)")
                }
                pumpReceive()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard readCount > 0 else { throw SecureDNSTransportError.tlsReadFailed("timeout") }
        return buffer.prefix(readCount)
    }

    func readSome(maxCount: Int, timeout: TimeInterval = 15) throws -> Data {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        var buffer = Data(count: maxCount)
        let deadline = Date().addingTimeInterval(timeout)
        var readCount = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while readCount == 0, Date() < deadline {
                var chunk = 0
                let status = SSLRead(ctx, base, maxCount, &chunk)
                if chunk > 0, status == noErr || status == errSSLWouldBlock {
                    readCount = chunk
                    return
                }
                if status == errSSLClosedGraceful {
                    return
                }
                if status != errSSLWouldBlock, status != noErr {
                    throw SecureDNSTransportError.tlsReadFailed("status=\(status)")
                }
                pumpReceive()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return buffer.prefix(readCount)
    }

    private func pumpReceive() {
        ioLock.lock()
        guard !isReceiving else {
            ioLock.unlock()
            return
        }
        isReceiving = true
        ioLock.unlock()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            self.ioLock.lock()
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
            }
            self.isReceiving = false
            let waiters = self.receiveWaiters
            self.receiveWaiters.removeAll()
            let chunk = self.receiveBuffer
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.ioLock.unlock()

            for waiter in waiters {
                if chunk.isEmpty {
                    waiter.resume(throwing: SecureDNSTransportError.tlsReadFailed("closed"))
                } else {
                    waiter.resume(returning: chunk)
                }
            }
        }
    }

    private func blockingReceive(minBytes: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            ioLock.lock()
            if receiveBuffer.count >= minBytes {
                let chunk = receiveBuffer.prefix(minBytes)
                receiveBuffer.removeFirst(minBytes)
                ioLock.unlock()
                return Data(chunk)
            }
            ioLock.unlock()
            pumpReceive()
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw SecureDNSTransportError.tlsReadFailed("blocking_timeout")
    }

    private static let sslRead: SSLReadFunc = { ref, buffer, length in
        let client = Unmanaged<NWConnectionTLSClient>.fromOpaque(ref).takeUnretainedValue()
        do {
            let chunk = try client.blockingReceive(minBytes: 1, timeout: 0.05)
            let copy = min(chunk.count, length.pointee)
            chunk.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(buffer, src, copy)
            }
            length.pointee = copy
            return noErr
        } catch {
            length.pointee = 0
            return errSSLWouldBlock
        }
    }

    private static let sslWrite: SSLWriteFunc = { ref, data, length in
        let client = Unmanaged<NWConnectionTLSClient>.fromOpaque(ref).takeUnretainedValue()
        let count = length.pointee
        guard count > 0 else {
            length.pointee = 0
            return noErr
        }
        let payload = Data(bytes: data, count: count)
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writeError: Error?
        client.connection.send(content: payload, completion: .contentProcessed { error in
            lock.lock()
            writeError = error
            lock.unlock()
            sem.signal()
        })
        if sem.wait(timeout: .now() + 2) == .timedOut {
            length.pointee = 0
            return errSSLWouldBlock
        }
        lock.lock()
        let didFail = writeError != nil
        lock.unlock()
        if didFail {
            length.pointee = 0
            return errSSLWouldBlock
        }
        length.pointee = count
        return noErr
    }
}

enum SecureDNSTransportError: LocalizedError {
    case noResolver
    case noProxy
    case dohBadStatus(Int)
    case dotBadResponse
    case tlsHandshakeFailed(String)
    case tlsNotReady
    case tlsWriteFailed(String)
    case tlsReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noResolver: return "no_resolver"
        case .noProxy: return "no_proxy"
        case .dohBadStatus(let code): return "doh_status:\(code)"
        case .dotBadResponse: return "dot_bad_response"
        case .tlsHandshakeFailed(let detail): return "tls_handshake:\(detail)"
        case .tlsNotReady: return "tls_not_ready"
        case .tlsWriteFailed(let detail): return "tls_write:\(detail)"
        case .tlsReadFailed(let detail): return "tls_read:\(detail)"
        }
    }
}
