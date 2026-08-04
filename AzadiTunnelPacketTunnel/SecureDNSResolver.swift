import Foundation

/// Resolves intercepted tunnel DNS queries with RFC 8484 DoH through Psiphon's local SOCKS port.
/// No query is sent to URLSession, the system resolver, TCP/53, or the local HTTP proxy.
enum SecureDNSResolver {
    struct Result {
        let payload: Data
        let usedSecurePath: Bool
    }

    private struct ResolutionValue: Sendable {
        let response: Data
        let lifetime: TimeInterval?
    }

    private actor ResolutionState {
        private let cache = SecureDNSCache()
        private let coalescer = SecureDNSResolutionCoordinator<ResolutionValue>()
        private let limiter = SecureDNSConcurrencyLimiter()

        init() {
            SharedLogger.shared.logRaw(
                "SECURE_DNS_ADMISSION_CONFIG",
                detail: "max_in_flight=\(SecureDNSConcurrencyLimiter.defaultMaxConcurrentOperations) "
                    + "max_queued=\(SecureDNSConcurrencyLimiter.defaultMaxQueuedOperations)"
            )
        }

        func value(
            for key: Data,
            operation: @escaping @Sendable (SecureDNSDeadline) async throws -> ResolutionValue
        ) async throws -> ResolutionValue {
            if let cached = await cache.value(for: key) {
                return ResolutionValue(response: cached, lifetime: nil)
            }
            let handle = await coalescer.acquire(for: key) {
                let deadline = SecureDNSDeadline(after: SecureDNSFailoverPolicy.totalTimeout)
                let result = try await self.limiter.withPermit(deadline: deadline) {
                    try await operation(deadline)
                }
                if let lifetime = result.lifetime {
                    await self.cache.insert(
                        response: result.response,
                        for: key,
                        lifetime: lifetime
                    )
                }
                return result
            }
            return try await withTaskCancellationHandler(operation: {
                try await coalescer.wait(handle)
            }, onCancel: {
                Task { await coalescer.cancel(handle) }
            })
        }

        func cancelAll() async {
            await coalescer.cancelAll()
            await limiter.cancelQueued()
            await cache.removeAll()
        }
    }

    private static let state = ResolutionState()

    /// Cancels outstanding DoH work and clears the extension-local cache on tunnel teardown.
    static func cancel() {
        Task { await state.cancelAll() }
    }

    static func resolve(
        wireQuery: Data,
        settings: AppSettings,
        socksHost: String,
        socksPort: Int
    ) async throws -> Result {
        // Secure DNS is mandatory after migration. The legacy `.off` value is decoded only long
        // enough for SharedSettingsStore to rewrite it to DoH; it never opens a cleartext path.
        guard socksPort > 0 else { throw SecureDNSTransportError.noProxy }

        let queryMessage: SecureDNSWire.Message
        do {
            queryMessage = try SecureDNSWire.parse(wireQuery)
        } catch {
            throw SecureDNSTransportError.invalidDNSMessage
        }
        guard !queryMessage.isResponse else {
            throw SecureDNSTransportError.invalidDNSMessage
        }
        let key: Data
        do {
            key = try SecureDNSWire.cacheKey(for: wireQuery)
        } catch {
            throw SecureDNSTransportError.invalidDNSMessage
        }

        let endpoints = SecureDNSConfiguration.dohEndpoints(for: settings)
        guard !endpoints.isEmpty else { throw SecureDNSTransportError.noResolver }
        let queryID = queryMessage.id

        let value = try await state.value(for: key) { overallDeadline in
            try Task.checkCancellation()
            do {
                let response = try await SecureDNSDoHClient.post(
                    endpoints: endpoints,
                    wireQuery: wireQuery,
                    socksHost: socksHost,
                    socksPort: socksPort,
                    overallDeadline: overallDeadline
                )
                let validated = try SecureDNSWire.validateResponse(
                    response,
                    for: wireQuery,
                    expectedID: queryID
                )
                return ResolutionValue(
                    response: response,
                    lifetime: SecureDNSWire.cacheLifetime(for: validated)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SecureDNSWireError {
                throw SecureDNSTransportError.invalidDNSResponse(error.localizedDescription)
            }
        }
        try Task.checkCancellation()

        let payload: Data
        do {
            payload = try SecureDNSWire.responseWithID(value.response, id: queryID)
            _ = try SecureDNSWire.validateResponse(payload, for: wireQuery, expectedID: queryID)
        } catch let error as SecureDNSWireError {
            throw SecureDNSTransportError.invalidDNSResponse(error.localizedDescription)
        }
        return Result(payload: payload, usedSecurePath: true)
    }

}
