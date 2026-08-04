import Darwin
import Foundation
import Network
import Security

/// Minimal TLS client over an established TCP stream after a Psiphon SOCKS CONNECT.
///
/// SecureTransport asks its callbacks for bytes synchronously, while Network.framework delivers
/// them asynchronously. The receive path is consequently an amortized-O(1) FIFO with a head
/// index. Network callbacks append; SecureTransport callbacks consume. No callback discards data
/// that has not yet been consumed by SecureTransport.
final class NWConnectionTLSClient: @unchecked Sendable {
    private let connection: NWConnection
    private let hostname: String
    private var sslContext: SSLContext?
    private let ioLock = NSLock()
    private var receiveBuffer = Data()
    private var receiveBufferHead = 0
    private var receiveError: Error?
    private var receiveClosed = false
    private var isReceiving = false
    private var ioDeadline: SecureDNSDeadline?
    private var didTimeout = false
#if SECURE_DNS_INTEGRATION_TEST
    private let trustedRootDER: Data?
#endif

#if SECURE_DNS_INTEGRATION_TEST
    init(connection: NWConnection, hostname: String, trustedRootDER: Data? = nil) {
        self.connection = connection
        self.hostname = hostname
        self.trustedRootDER = trustedRootDER
    }
#else
    init(connection: NWConnection, hostname: String) {
        self.connection = connection
        self.hostname = hostname
    }
#endif

    /// Cancels the underlying stream immediately. This is used by the async DoH cancellation
    /// handler, because the synchronous SecureTransport call otherwise cannot observe task
    /// cancellation until its operation deadline expires.
    func cancel() {
        abortIO()
    }

    func handshake(timeout: TimeInterval = 6) throws {
        guard let ctx = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            throw SecureDNSTransportError.tlsHandshakeFailed("create_context")
        }
        guard SSLSetPeerDomainName(ctx, hostname, hostname.utf8.count) == noErr else {
            throw SecureDNSTransportError.tlsHandshakeFailed("peer_name")
        }
#if SECURE_DNS_INTEGRATION_TEST
        guard trustedRootDER != nil,
              SSLSetSessionOption(ctx, SSLSessionOption(rawValue: 0)!, true) == noErr else {
            throw SecureDNSTransportError.tlsHandshakeFailed("test_auth_hook")
        }
#endif

        let retained = Unmanaged.passRetained(self)
        defer { retained.release() }
        SSLSetConnection(ctx, retained.toOpaque())
        SSLSetIOFuncs(ctx, Self.sslRead, Self.sslWrite)
        sslContext = ctx

        let deadline = SecureDNSDeadline(after: max(0.05, timeout))
        beginIO(deadline: deadline)
        defer { endIO() }

        var status = SSLHandshake(ctx)
        while deadline.remaining > 0 {
            #if SECURE_DNS_INTEGRATION_TEST
            if status == -9841 {
                try validateIntegrationTrust(ctx)
                status = SSLHandshake(ctx)
                continue
            }
            #endif
            guard status == errSSLWouldBlock else { break }
            if didTimeoutValue() { break }
            pumpReceive()
            let pause = min(0.02, deadline.remaining)
            if pause > 0 { Thread.sleep(forTimeInterval: max(0.001, pause)) }
            status = SSLHandshake(ctx)
        }
        if didTimeoutValue() || status == errSSLWouldBlock {
            abortIO()
            throw SecureDNSTransportError.tlsHandshakeFailed("timeout")
        }
        guard status == noErr else {
            throw SecureDNSTransportError.tlsHandshakeFailed("status=\(status)")
        }
    }

#if SECURE_DNS_INTEGRATION_TEST
    private func validateIntegrationTrust(_ ctx: SSLContext) throws {
        guard let trustedRootDER,
              let certificate = SecCertificateCreateWithData(nil, trustedRootDER as CFData) else {
            throw SecureDNSTransportError.tlsHandshakeFailed("test_trust")
        }
        var peerTrust: SecTrust?
        guard SSLCopyPeerTrust(ctx, &peerTrust) == errSecSuccess,
              let peerTrust else {
            throw SecureDNSTransportError.tlsHandshakeFailed("test_trust")
        }
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard SecTrustSetPolicies(peerTrust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(peerTrust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(peerTrust, true) == errSecSuccess else {
            throw SecureDNSTransportError.tlsHandshakeFailed("test_trust_policy")
        }
        var result = SecTrustResultType.invalid
        if SecTrustEvaluate(peerTrust, &result) == errSecSuccess,
           result == .proceed || result == .unspecified {
            return
        }

        // macOS 26 no longer exposes SecureTransport's trusted-root setter. The fallback remains
        // test-only and is deliberately exact: it accepts only the DER certificate generated by
        // this harness and only when its subject summary matches the SNI hostname. Production
        // builds never compile this initializer or this branch and use system trust normally.
        guard SecTrustGetCertificateCount(peerTrust) > 0,
              let leaf = SecTrustGetCertificateAtIndex(peerTrust, 0),
              Data(SecCertificateCopyData(leaf) as Data) == trustedRootDER,
              let subject = SecCertificateCopySubjectSummary(leaf) as String?,
              subject.caseInsensitiveCompare(hostname) == .orderedSame else {
            throw SecureDNSTransportError.tlsHandshakeFailed("test_trust_rejected")
        }
    }
#endif

    deinit {
        connection.cancel()
        if let sslContext {
            SSLClose(sslContext)
        }
    }

    /// Writes one complete TLS application payload under one monotonic deadline. If the Network
    /// send callback does not finish in time, the connection is cancelled and SecureTransport is
    /// given a fatal status; the caller never retries an ambiguous outstanding write.
    func write(_ data: Data, timeout: TimeInterval = 5) throws {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        guard !data.isEmpty else { return }

        let deadline = SecureDNSDeadline(after: max(0.05, timeout))
        beginIO(deadline: deadline)
        defer { endIO() }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw SecureDNSTransportError.tlsWriteFailed("empty_buffer")
            }
            var offset = 0
            while offset < data.count {
                guard deadline.remaining > 0, !didTimeoutValue() else {
                    abortIO()
                    throw SecureDNSTransportError.tlsWriteFailed("timeout")
                }

                var processed = 0
                let status = SSLWrite(
                    ctx,
                    base.advanced(by: offset),
                    data.count - offset,
                    &processed
                )
                offset += processed

                if status == noErr {
                    guard processed > 0 else {
                        throw SecureDNSTransportError.tlsWriteFailed("no_progress")
                    }
                    continue
                }
                if status == errSSLWouldBlock {
                    guard deadline.remaining > 0, !didTimeoutValue() else {
                        abortIO()
                        throw SecureDNSTransportError.tlsWriteFailed("timeout")
                    }
                    pumpReceive()
                    let pause = min(0.01, deadline.remaining)
                    if pause > 0 { Thread.sleep(forTimeInterval: max(0.001, pause)) }
                    continue
                }
                throw SecureDNSTransportError.tlsWriteFailed("status=\(status)")
            }
        }
    }

    func read(count: Int, timeout: TimeInterval = 15) throws -> Data {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        guard count > 0 else { return Data() }

        var buffer = Data(count: count)
        var readCount = 0
        let deadline = SecureDNSDeadline(after: max(0.05, timeout))
        beginIO(deadline: deadline)
        defer { endIO() }

        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while readCount < count, deadline.remaining > 0 {
                var chunk = 0
                let status = SSLRead(ctx, base.advanced(by: readCount), count - readCount, &chunk)
                if chunk > 0 {
                    readCount += chunk
                    if readCount == count { return }
                }
                if status == errSSLClosedGraceful, readCount > 0 { return }
                if status != errSSLWouldBlock, status != noErr {
                    throw SecureDNSTransportError.tlsReadFailed("status=\(status)")
                }
                pumpReceive()
                let pause = min(0.01, deadline.remaining)
                if pause > 0 { Thread.sleep(forTimeInterval: max(0.001, pause)) }
            }
        }
        guard readCount > 0 else { throw SecureDNSTransportError.tlsReadFailed("timeout") }
        return Data(buffer.prefix(readCount))
    }

    /// Reads whatever application data is available, up to `maxCount`, without requiring a
    /// caller to know the TLS record size.
    func readSome(maxCount: Int, timeout: TimeInterval = 15) throws -> Data {
        guard let ctx = sslContext else { throw SecureDNSTransportError.tlsNotReady }
        guard maxCount > 0 else { return Data() }

        var buffer = Data(count: maxCount)
        let deadline = SecureDNSDeadline(after: max(0.05, timeout))
        beginIO(deadline: deadline)
        defer { endIO() }

        var readCount = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while readCount == 0, deadline.remaining > 0 {
                var chunk = 0
                let status = SSLRead(ctx, base, maxCount, &chunk)
                if chunk > 0 {
                    readCount = chunk
                    return
                }
                if status == errSSLClosedGraceful { return }
                if status != errSSLWouldBlock, status != noErr {
                    throw SecureDNSTransportError.tlsReadFailed("status=\(status)")
                }
                pumpReceive()
                let pause = min(0.01, deadline.remaining)
                if pause > 0 { Thread.sleep(forTimeInterval: max(0.001, pause)) }
            }
        }
        return Data(buffer.prefix(readCount))
    }

    private enum ReceiveFailure: Error {
        case wouldBlock
        case terminal
    }

    private func beginIO(deadline: SecureDNSDeadline) {
        ioLock.lock()
        ioDeadline = deadline
        didTimeout = false
        ioLock.unlock()
    }

    private func endIO() {
        ioLock.lock()
        ioDeadline = nil
        ioLock.unlock()
    }

    private func currentDeadline() -> SecureDNSDeadline? {
        ioLock.lock()
        let deadline = ioDeadline
        ioLock.unlock()
        return deadline
    }

    private func didTimeoutValue() -> Bool {
        ioLock.lock()
        let timedOut = didTimeout
        ioLock.unlock()
        return timedOut
    }

    private func abortIO() {
        ioLock.lock()
        didTimeout = true
        ioLock.unlock()
        connection.cancel()
    }

    /// Compact only after the consumed prefix is both sizeable and at least half of the backing
    /// storage. This bounds retained memory while keeping normal consumption amortized O(1).
    private func compactReceiveBufferLocked() {
        guard receiveBufferHead > 0 else { return }
        if receiveBufferHead == receiveBuffer.count {
            receiveBuffer.removeAll(keepingCapacity: true)
            receiveBufferHead = 0
        } else if receiveBufferHead >= 4096, receiveBufferHead * 2 >= receiveBuffer.count {
            receiveBuffer.removeSubrange(0..<receiveBufferHead)
            receiveBufferHead = 0
        }
    }

    private func consumeReceiveBufferLocked(maxBytes: Int) -> Data {
        let available = receiveBuffer.count - receiveBufferHead
        let count = min(maxBytes, available)
        let range = receiveBufferHead..<(receiveBufferHead + count)
        let result = Data(receiveBuffer[range])
        receiveBufferHead += count
        compactReceiveBufferLocked()
        return result
    }

    /// Keep exactly one Network receive outstanding and append its bytes to the FIFO. The buffer
    /// is only removed by `blockingReceive`, after SecureTransport has consumed those bytes.
    private func pumpReceive() {
        ioLock.lock()
        guard !isReceiving, !receiveClosed else {
            ioLock.unlock()
            return
        }
        isReceiving = true
        ioLock.unlock()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.ioLock.lock()
            if let data, !data.isEmpty {
                self.compactReceiveBufferLocked()
                self.receiveBuffer.append(data)
            }
            if error != nil {
                self.receiveError = error
                self.receiveClosed = true
            } else if isComplete {
                self.receiveClosed = true
            }
            self.isReceiving = false
            self.ioLock.unlock()
        }
    }

    private func blockingReceive(maxBytes: Int, timeout: TimeInterval) throws -> Data {
        let localDeadline = SecureDNSDeadline(after: max(0.01, timeout))
        while localDeadline.remaining > 0 {
            ioLock.lock()
            if receiveBuffer.count > receiveBufferHead {
                let chunk = consumeReceiveBufferLocked(maxBytes: maxBytes)
                ioLock.unlock()
                return chunk
            }
            let terminal = receiveError != nil || receiveClosed || didTimeout
            let operationRemaining = ioDeadline?.remaining ?? .greatestFiniteMagnitude
            ioLock.unlock()

            if terminal { throw ReceiveFailure.terminal }
            if operationRemaining <= 0 { throw ReceiveFailure.wouldBlock }
            pumpReceive()
            let pause = min(0.01, localDeadline.remaining, operationRemaining)
            if pause > 0 { Thread.sleep(forTimeInterval: max(0.001, pause)) }
        }
        throw ReceiveFailure.wouldBlock
    }

    private static let sslRead: SSLReadFunc = { ref, buffer, length in
        let client = Unmanaged<NWConnectionTLSClient>.fromOpaque(ref).takeUnretainedValue()
        guard length.pointee > 0 else { return noErr }
        let requested = length.pointee
        do {
            let chunk = try client.blockingReceive(maxBytes: requested, timeout: 0.05)
            let copy = min(chunk.count, length.pointee)
            chunk.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(buffer, src, copy)
            }
            length.pointee = copy
            return noErr
        } catch ReceiveFailure.wouldBlock {
            length.pointee = 0
            return errSSLWouldBlock
        } catch {
            // A closed/failed receive is terminal. Returning would-block here would make
            // SecureTransport spin until the DNS deadline and hide the real stream failure.
            length.pointee = 0
            return errSSLClosedAbort
        }
    }

    private static let sslWrite: SSLWriteFunc = { ref, data, length in
        let client = Unmanaged<NWConnectionTLSClient>.fromOpaque(ref).takeUnretainedValue()
        let count = length.pointee
        guard count > 0 else {
            length.pointee = 0
            return noErr
        }

        guard let deadline = client.currentDeadline(), deadline.remaining > 0, !client.didTimeoutValue() else {
            client.abortIO()
            length.pointee = 0
            return errSSLClosedAbort
        }

        let payload = Data(bytes: data, count: count)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writeError: Error?
        client.connection.send(content: payload, completion: .contentProcessed { error in
            lock.lock()
            writeError = error
            lock.unlock()
            semaphore.signal()
        })

        let remaining = deadline.remaining
        guard remaining > 0, semaphore.wait(timeout: .now() + remaining) != .timedOut else {
            // The send is no longer allowed to complete into a connection that SSLWrite might
            // retry. Cancel the stream and return a fatal status; the caller will not retry.
            client.abortIO()
            length.pointee = 0
            return errSSLClosedAbort
        }

        lock.lock()
        let failed = writeError != nil
        lock.unlock()
        guard !failed, !client.didTimeoutValue() else {
            length.pointee = 0
            return errSSLClosedAbort
        }
        length.pointee = count
        return noErr
    }
}

enum SecureDNSTransportError: LocalizedError {
    case noResolver
    case noProxy
    case invalidDNSMessage
    case invalidDNSResponse(String)
    case invalidHTTPResponse(String)
    case dohBadStatus(Int)
    case tlsHandshakeFailed(String)
    case tlsNotReady
    case tlsWriteFailed(String)
    case tlsReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noResolver: return "no_resolver"
        case .noProxy: return "no_proxy"
        case .invalidDNSMessage: return "invalid_dns_message"
        case .invalidDNSResponse(let detail): return "invalid_dns_response:\(detail)"
        case .invalidHTTPResponse(let detail): return "invalid_http_response:\(detail)"
        case .dohBadStatus(let code): return "doh_status:\(code)"
        case .tlsHandshakeFailed(let detail): return "tls_handshake:\(detail)"
        case .tlsNotReady: return "tls_not_ready"
        case .tlsWriteFailed(let detail): return "tls_write:\(detail)"
        case .tlsReadFailed(let detail): return "tls_read:\(detail)"
        }
    }
}
