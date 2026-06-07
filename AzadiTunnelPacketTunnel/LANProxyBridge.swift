import Darwin
import Foundation
import Network

/// Bridges incoming Wi-Fi/LAN TCP connections to the in-process Psiphon local proxy.
///
/// The Psiphon core itself only exposes HTTP/SOCKS5 listeners on `127.0.0.1`. This actor
/// opens a parallel pair of listeners on the Wi-Fi address (or `0.0.0.0` fallback) and
/// blindly relays bytes between the LAN peer and Psiphon's loopback ports. Because the
/// data plane is unchanged, all traffic still leaves the device through the AzadiTunnel
/// VPN tunnel — there is no bypass path.
///
/// `iOS` note: a packet-tunnel extension is allowed to open `NWListener`s on its host
/// interfaces (en0). Listeners are stopped immediately when the VPN tears down or the
/// user disables the toggle.
final class LANProxyBridge: @unchecked Sendable {
    struct Endpoints {
        let psiphonHost: String
        let psiphonHttpPort: Int
        let psiphonSocksPort: Int
    }

    struct Configuration {
        let bindHost: String
        let httpPort: Int
        let socksPort: Int
        let upstream: Endpoints
    }

    private let queue = DispatchQueue(label: "com.polamgh.ali.AzadiTunnel.lanproxy", qos: .userInitiated)
    private var httpListener: NWListener?
    private var socksListener: NWListener?
    /// Loopback HTTP CONNECT proxy used as the iOS system proxy when Secure DNS (Cloudflare) is on.
    private var loopbackHttpListener: NWListener?
    /// POSIX fallback when `NWListener` cannot pin `127.0.0.1` inside the extension (NWError 22).
    private var loopbackHttpListenFD: Int32 = -1
    private var loopbackHttpAcceptSource: DispatchSourceRead?
    private var loopbackUpstream: Endpoints?
    /// Actual interface a listener bound to ("0.0.0.0" after a Wi-Fi-IP fallback). For logs only.
    private var httpBoundInterface: String?
    private var socksBoundInterface: String?
    /// Live client connections / relay sessions, guarded by `stateLock` because protocol
    /// handshakes run on detached Tasks while accepts arrive on the listener queue.
    private let stateLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeSessions: [ObjectIdentifier: RelaySession] = [:]
    private var activeFDRelaySessions: [ObjectIdentifier: FDRelaySession] = [:]
    private var config: Configuration?
    private(set) var lastError: String?

    /// Both listeners must be live for the bridge to be considered fully running.
    var isRunning: Bool {
        httpListener?.state == .ready && socksListener?.state == .ready
    }

    /// Result of a single listener bind, including the interface actually bound.
    private struct ListenerResult {
        let listener: NWListener?
        let posixListenFD: Int32?
        let posixAcceptSource: DispatchSourceRead?
        /// Technical bind interface: Wi-Fi IP, loopback, or "0.0.0.0" when we fell back to any-interface.
        let boundInterface: String

        init(listener: NWListener, boundInterface: String) {
            self.listener = listener
            self.posixListenFD = nil
            self.posixAcceptSource = nil
            self.boundInterface = boundInterface
        }

        init(posixListenFD: Int32, posixAcceptSource: DispatchSourceRead, boundInterface: String) {
            self.listener = nil
            self.posixListenFD = posixListenFD
            self.posixAcceptSource = posixAcceptSource
            self.boundInterface = boundInterface
        }
    }

    // MARK: - Lifecycle

    func start(configuration: Configuration) async -> Result<Void, LANProxyBridgeError> {
        stop()
        config = configuration
        lastError = nil

        // Start HTTP and SOCKS independently — one failing must not block the other.
        let httpOutcome = await startListener(
            port: configuration.httpPort,
            preferredHost: configuration.bindHost,
            label: "http",
            onAccept: { [weak self] conn in self?.handleHttpAccept(conn) }
        )
        switch httpOutcome {
        case .success(let res):
            httpListener = res.listener
            httpBoundInterface = res.boundInterface
            SharedLogger.shared.log(
                .lanProxyHttpListening,
                detail: "display_ip=\(configuration.bindHost) bind_iface=\(res.boundInterface) port=\(configuration.httpPort)"
            )
        case .failure(let err):
            logBindFailure(kind: "http", port: configuration.httpPort, error: err, event: .lanProxyHttpBindFailed)
        }

        let socksOutcome = await startListener(
            port: configuration.socksPort,
            preferredHost: configuration.bindHost,
            label: "socks",
            onAccept: { [weak self] conn in self?.handleSocksAccept(conn) }
        )
        switch socksOutcome {
        case .success(let res):
            socksListener = res.listener
            socksBoundInterface = res.boundInterface
            SharedLogger.shared.log(
                .lanProxySocksListening,
                detail: "display_ip=\(configuration.bindHost) bind_iface=\(res.boundInterface) port=\(configuration.socksPort)"
            )
        case .failure(let err):
            logBindFailure(kind: "socks", port: configuration.socksPort, error: err, event: .lanProxySocksBindFailed)
        }

        return publishStartOutcome(
            configuration: configuration,
            httpOutcome: httpOutcome,
            socksOutcome: socksOutcome
        )
    }

    /// Maps the two listener outcomes onto the App-Group runtime status the UI observes.
    ///
    /// - both ready → `.running`
    /// - any port-in-use → `.portInUse`
    /// - otherwise (≥1 failed) → `.failedToStart`
    ///
    /// We always advertise the Wi-Fi IP (`configuration.bindHost`) for the address rows even
    /// when a listener fell back to `0.0.0.0`, because `0.0.0.0` still accepts connections on
    /// en0 and the user needs a concrete IP to type into the other device.
    private func publishStartOutcome(
        configuration: Configuration,
        httpOutcome: Result<ListenerResult, LANProxyBridgeError>,
        socksOutcome: Result<ListenerResult, LANProxyBridgeError>
    ) -> Result<Void, LANProxyBridgeError> {
        let store = SharedSettingsStore.shared
        let httpOK = isSuccess(httpOutcome)
        let socksOK = isSuccess(socksOutcome)

        store.lanProxyActiveHttpPort = httpOK ? configuration.httpPort : 0
        store.lanProxyActiveSocksPort = socksOK ? configuration.socksPort : 0

        if httpOK && socksOK {
            store.lanProxyBoundHost = configuration.bindHost
            store.lanProxyRuntimeStatus = .running
            store.lanProxyStatusDetail = nil
            return .success(())
        }

        let anyPortInUse = isPortInUse(httpOutcome) || isPortInUse(socksOutcome)
        let detail = "http=\(outcomeText(httpOutcome)) socks=\(outcomeText(socksOutcome))"
        store.lanProxyStatusDetail = detail

        if httpOK || socksOK {
            // Partial start: keep the working listener live so it still serves traffic,
            // but report failure so the UI never shows "Running" for a half-broken bridge.
            store.lanProxyBoundHost = configuration.bindHost
            store.lanProxyRuntimeStatus = anyPortInUse ? .portInUse : .failedToStart
            SharedLogger.shared.logRaw("LAN_PROXY_PARTIAL_START", detail: detail)
            return .failure(.other("partial_start \(detail)"))
        }

        // Nothing came up — clean everything and surface the failure status.
        stop()
        store.lanProxyBoundHost = nil
        store.lanProxyRuntimeStatus = anyPortInUse ? .portInUse : .failedToStart
        store.lanProxyStatusDetail = detail
        return .failure(anyPortInUse ? .portInUse : .other("failed_to_start \(detail)"))
    }

    private func logBindFailure(kind: String, port: Int, error: LANProxyBridgeError, event: SharedLogEvent) {
        switch error {
        case .portInUse:
            SharedLogger.shared.log(event, detail: "port=\(port) reason=port_in_use")
            SharedLogger.shared.log(.lanProxyPortInUse, detail: "kind=\(kind) port=\(port)")
        default:
            SharedLogger.shared.log(event, detail: "port=\(port) reason=\(error.shortDescription)")
        }
    }

    private func isSuccess(_ outcome: Result<ListenerResult, LANProxyBridgeError>) -> Bool {
        if case .success = outcome { return true }
        return false
    }

    private func isPortInUse(_ outcome: Result<ListenerResult, LANProxyBridgeError>) -> Bool {
        if case .failure(.portInUse) = outcome { return true }
        return false
    }

    private func outcomeText(_ outcome: Result<ListenerResult, LANProxyBridgeError>) -> String {
        switch outcome {
        case .success(let res): return "ok(\(res.boundInterface))"
        case .failure(let err): return err.shortDescription
        }
    }

    func stop() {
        stopLoopbackHTTPProxy()
        if httpListener != nil {
            SharedLogger.shared.log(.lanProxyHttpStopped)
        }
        if socksListener != nil {
            SharedLogger.shared.log(.lanProxySocksStopped)
        }
        httpListener?.cancel()
        httpListener = nil
        socksListener?.cancel()
        socksListener = nil
        httpBoundInterface = nil
        socksBoundInterface = nil
        stateLock.lock()
        let conns = activeConnections.values
        let sessions = activeSessions.values
        let fdSessions = activeFDRelaySessions.values
        activeConnections.removeAll()
        activeSessions.removeAll()
        activeFDRelaySessions.removeAll()
        stateLock.unlock()
        for conn in conns { conn.cancel() }
        for session in sessions { session.cancel() }
        for session in fdSessions { session.cancel() }
        config = nil

        let store = SharedSettingsStore.shared
        let current = store.lanProxyRuntimeStatus
        // Preserve diagnostic states (portInUse / failedToStart) so the UI can show the
        // last error after stop(); only blank the bound host to disable copy actions.
        store.lanProxyBoundHost = nil
        if current == .running {
            store.lanProxyRuntimeStatus = .stopped
        }
    }

    // MARK: - Loopback system HTTP proxy (Secure DNS)

    var isLoopbackHttpProxyRunning: Bool {
        loopbackHttpListener != nil || loopbackHttpListenFD >= 0
    }

    /// Accept iOS system HTTP/HTTPS proxy traffic on loopback and resolve CONNECT targets through DoH.
    /// Returns false instead of failing the tunnel when bind is rejected inside the extension (NWError 22).
    func startLoopbackHTTPProxy(
        port: Int = SecureDNSConfiguration.systemHTTPProxyPort,
        upstream: Endpoints
    ) async -> Bool {
        stopLoopbackHTTPProxy()
        loopbackUpstream = upstream
        let outcome = await startSystemHttpListener(
            port: port,
            onAccept: { [weak self] conn in self?.handleLoopbackHttpAccept(conn) }
        )
        switch outcome {
        case .success(let res):
            if let listener = res.listener {
                loopbackHttpListener = listener
            }
            if let fd = res.posixListenFD {
                loopbackHttpListenFD = fd
                loopbackHttpAcceptSource = res.posixAcceptSource
            }
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY",
                detail: "display=127.0.0.1 bind_iface=\(res.boundInterface) port=\(port)"
            )
            return true
        case .failure(let err):
            loopbackUpstream = nil
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY_FAILED",
                detail: "port=\(port) reason=\(err.shortDescription)"
            )
            return false
        }
    }

    func stopLoopbackHTTPProxy() {
        if loopbackHttpListener != nil || loopbackHttpListenFD >= 0 {
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_PROXY_STOPPED")
        }
        loopbackHttpListener?.cancel()
        loopbackHttpListener = nil
        loopbackHttpAcceptSource?.cancel()
        loopbackHttpAcceptSource = nil
        if loopbackHttpListenFD >= 0 {
            close(loopbackHttpListenFD)
            loopbackHttpListenFD = -1
        }
        loopbackUpstream = nil
    }

    private func handleLoopbackHttpAccept(_ incoming: NWConnection) {
        guard loopbackUpstream != nil else { incoming.cancel(); return }
        track(incoming)
        SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_CLIENT_CONNECTED")
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                incoming.stateUpdateHandler = nil
                Task { [weak self] in await self?.serveLoopbackHTTP(incoming) }
            case .failed(let e):
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_HTTP_ERROR",
                    detail: "stage=accept err=\(e.localizedDescription)"
                )
                self?.untrack(incoming)
                incoming.cancel()
            case .cancelled:
                self?.untrack(incoming)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func serveLoopbackHTTP(_ client: NWConnection) async {
        guard let upstream = loopbackUpstream else { untrack(client); client.cancel(); return }
        do {
            let head = try await readHTTPHead(client)
            guard let firstLineEnd = head.range(of: Data("\r\n".utf8)) else {
                throw BridgeIOError.protocolError("no_request_line")
            }
            let requestLine = String(decoding: head.subdata(in: head.startIndex..<firstLineEnd.lowerBound), as: UTF8.self)
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_REQUEST", detail: sanitize(requestLine))
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { throw BridgeIOError.protocolError("bad_request_line") }
            let method = parts[0].uppercased()

            if method == "CONNECT" {
                try await serveHTTPConnect(client: client, target: String(parts[1]), upstream: upstream, logLabel: "system-http")
            } else if upstream.psiphonHttpPort > 0 {
                try await serveHTTPPlain(client: client, initialData: head, upstream: upstream)
            } else {
                throw BridgeIOError.protocolError("no_http_upstream")
            }
        } catch {
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_FAILED", detail: errText(error))
            untrack(client)
            client.cancel()
        }
    }

    // MARK: - Listener factory

    /// System HTTP proxy must be reachable at `127.0.0.1` — iOS routes `NEProxySettings` there.
    /// Binding only to `0.0.0.0` leaves the proxy advertised but unreachable, so app traffic stalls.
    private func startSystemHttpListener(
        port: Int,
        onAccept: @escaping (NWConnection) -> Void
    ) async -> Result<ListenerResult, LANProxyBridgeError> {
        if let posix = startPOSIXLoopbackListener(port: port, onAcceptFD: { [weak self] fd in
            Task { await self?.serveLoopbackHTTPPosix(fd) }
        }) {
            return .success(posix)
        }

        let pinned = await attemptListener(port: port, host: "127.0.0.1", label: "system-http", onAccept: onAccept)
        if case .success(let listener) = pinned {
            return .success(ListenerResult(listener: listener, boundInterface: "127.0.0.1"))
        }

        let loopbackIface = await attemptLoopbackInterfaceListener(
            port: port,
            label: "system-http",
            onAccept: onAccept
        )
        if case .success(let listener) = loopbackIface {
            return .success(ListenerResult(listener: listener, boundInterface: "loopback"))
        }

        return .failure(.bindFailed("loopback_unavailable"))
    }

    /// Bind on the loopback interface without pinning an IP (works when `requiredLocalEndpoint` fails).
    private func attemptLoopbackInterfaceListener(
        port: Int,
        label: String,
        onAccept: @escaping (NWConnection) -> Void
    ) async -> Result<NWListener, LANProxyBridgeError> {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure(.invalidPort(port))
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredInterfaceType = .loopback

        SharedLogger.shared.logRaw(
            "LAN_PROXY_BIND_ATTEMPT",
            detail: "kind=\(label) bind_host=loopback bind_port=\(port)"
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            SharedLogger.shared.logRaw(
                "LAN_PROXY_LISTENER_INIT_FAILED",
                detail: "kind=\(label) bind_host=loopback bind_port=\(port) error=\(error.localizedDescription)"
            )
            return .failure(.bindFailed(error.localizedDescription))
        }
        listener.service = nil
        listener.newConnectionHandler = { connection in onAccept(connection) }

        let started: Result<NWListener, LANProxyBridgeError> = await withCheckedContinuation { cont in
            let gate = OneShotFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_STATE",
                        detail: "kind=\(label) bind_host=loopback bind_port=\(port) state=ready"
                    )
                    cont.resume(returning: .success(listener))
                case .failed(let error):
                    guard gate.claim() else { return }
                    listener.cancel()
                    cont.resume(returning: .failure(.bindFailed(error.localizedDescription)))
                case .cancelled:
                    guard gate.claim() else { return }
                    cont.resume(returning: .failure(.bindFailed("cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return started
    }

    /// BSD `bind(127.0.0.1)` — Psiphon's Go stack uses the same mechanism and succeeds in-extension.
    private func startPOSIXLoopbackListener(
        port: Int,
        onAcceptFD: @escaping (Int32) -> Void
    ) -> ListenerResult? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOk else {
            close(fd)
            SharedLogger.shared.logRaw(
                "LAN_PROXY_LISTENER_INIT_FAILED",
                detail: "kind=system-http bind_host=127.0.0.1-posix bind_port=\(port) error=posix_bind_failed"
            )
            return nil
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            return nil
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        SharedLogger.shared.logRaw(
            "LAN_PROXY_LISTENER_STATE",
            detail: "kind=system-http bind_host=127.0.0.1-posix bind_port=\(port) state=ready"
        )

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPOSIXLoopbackConnections(listenFD: fd, onAcceptFD: onAcceptFD)
        }
        source.resume()
        return ListenerResult(posixListenFD: fd, posixAcceptSource: source, boundInterface: "127.0.0.1-posix")
    }

    private func acceptPOSIXLoopbackConnections(listenFD: Int32, onAcceptFD: @escaping (Int32) -> Void) {
        while true {
            var clientAddr = sockaddr()
            var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &clientAddr, &addrLen)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_HTTP_ERROR",
                    detail: "stage=posix_accept err=\(String(cString: strerror(errno)))"
                )
                break
            }
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_CLIENT_CONNECTED")
            onAcceptFD(clientFD)
        }
    }

    private func serveLoopbackHTTPPosix(_ clientFD: Int32) async {
        guard let upstream = loopbackUpstream else { close(clientFD); return }
        do {
            let head = try await readHTTPHead(fd: clientFD)
            guard let firstLineEnd = head.range(of: Data("\r\n".utf8)) else {
                throw BridgeIOError.protocolError("no_request_line")
            }
            let requestLine = String(decoding: head.subdata(in: head.startIndex..<firstLineEnd.lowerBound), as: UTF8.self)
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_REQUEST", detail: sanitize(requestLine))
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { throw BridgeIOError.protocolError("bad_request_line") }
            let method = parts[0].uppercased()

            if method == "CONNECT" {
                try await serveHTTPConnectPosix(
                    clientFD: clientFD,
                    target: String(parts[1]),
                    upstream: upstream
                )
            } else if upstream.psiphonHttpPort > 0 {
                try await serveHTTPPlainPosix(clientFD: clientFD, initialData: head, upstream: upstream)
            } else {
                throw BridgeIOError.protocolError("no_http_upstream")
            }
        } catch {
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_FAILED", detail: errText(error))
            close(clientFD)
        }
    }

    private func serveHTTPConnectPosix(
        clientFD: Int32,
        target: String,
        upstream: Endpoints
    ) async throws {
        let (host, port) = Self.splitHostPort(target, defaultPort: 443)
        SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_CONNECT", detail: "\(host):\(port)")

        let tunnel: NWConnection
        do {
            tunnel = try await dialViaPsiphonSOCKS(
                host: host,
                port: port,
                upstream: upstream,
                logLabel: "system-http"
            )
        } catch {
            try? await sendData(fd: clientFD, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw error
        }
        try await sendData(fd: clientFD, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_ESTABLISHED", detail: "\(host):\(port)")
        startRelay(clientFD: clientFD, upstream: tunnel, label: "system-http")
    }

    private func serveHTTPPlainPosix(
        clientFD: Int32,
        initialData: Data,
        upstream: Endpoints
    ) async throws {
        guard upstream.psiphonHttpPort > 0 else {
            try? await sendData(fd: clientFD, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw BridgeIOError.protocolError("no_http_upstream")
        }
        let psiphonHttp = try await connectTCP(host: upstream.psiphonHost, port: upstream.psiphonHttpPort)
        try await sendData(psiphonHttp, initialData)
        startRelay(clientFD: clientFD, upstream: psiphonHttp, label: "http-plain")
    }

    /// Bind a listener, preferring the Wi-Fi IP and falling back to any-interface on error.
    ///
    /// Inside a `NEPacketTunnelProvider`, `NWListener` with `requiredLocalEndpoint` pinned to the
    /// host's Wi-Fi address (en0) can be rejected with `NWError 22 (POSIXErrorCode EINVAL —
    /// "Invalid argument")`. When that happens we retry with a port-only listener, which binds to
    /// all interfaces (`0.0.0.0`). `0.0.0.0` still accepts connections arriving on en0, so other
    /// Wi-Fi devices can reach the proxy at the iPhone's Wi-Fi IP. We never fall back for a genuine
    /// port-in-use error, since the same port on `0.0.0.0` would also be occupied.
    private func startListener(
        port: Int,
        preferredHost: String,
        label: String,
        onAccept: @escaping (NWConnection) -> Void
    ) async -> Result<ListenerResult, LANProxyBridgeError> {
        // Attempt 1: pin to the specific Wi-Fi IP.
        if IPv4Address(preferredHost) != nil {
            let pinned = await attemptListener(port: port, host: preferredHost, label: label, onAccept: onAccept)
            switch pinned {
            case .success(let listener):
                return .success(ListenerResult(listener: listener, boundInterface: preferredHost))
            case .failure(.portInUse):
                return .failure(.portInUse)
            case .failure(let err):
                SharedLogger.shared.logRaw(
                    "LAN_PROXY_BIND_WIFI_IP_FAILED_FALLING_BACK_TO_ANY",
                    detail: "kind=\(label) wifi_ip=\(preferredHost) port=\(port) reason=\(err.shortDescription)"
                )
                // fall through to any-interface attempt
            }
        }

        // Attempt 2: bind the port only (all interfaces, 0.0.0.0).
        let anyBind = await attemptListener(port: port, host: nil, label: label, onAccept: onAccept)
        switch anyBind {
        case .success(let listener):
            return .success(ListenerResult(listener: listener, boundInterface: "0.0.0.0"))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Single bind attempt. `host == nil` binds the port on all interfaces; otherwise it pins
    /// `requiredLocalEndpoint` to `host:port`. Resolves only after the listener reaches a terminal
    /// state (`.ready` or `.failed`), logging the bind host, port, and NWError details.
    private func attemptListener(
        port: Int,
        host: String?,
        label: String,
        onAccept: @escaping (NWConnection) -> Void
    ) async -> Result<NWListener, LANProxyBridgeError> {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure(.invalidPort(port))
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let host, let ipAddress = IPv4Address(host) {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(ipAddress), port: nwPort)
        }

        let bindHostLabel = host ?? "0.0.0.0"
        SharedLogger.shared.logRaw(
            "LAN_PROXY_BIND_ATTEMPT",
            detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port)"
        )

        let listener: NWListener
        do {
            // Always pass the port via `on:` (the spec-recommended form); requiredLocalEndpoint
            // in `parameters` adds the host pin when present.
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            SharedLogger.shared.logRaw(
                "LAN_PROXY_LISTENER_INIT_FAILED",
                detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port) error=\(error.localizedDescription)"
            )
            return .failure(.bindFailed(error.localizedDescription))
        }
        listener.service = nil
        listener.newConnectionHandler = { connection in
            onAccept(connection)
        }

        let started: Result<NWListener, LANProxyBridgeError> = await withCheckedContinuation { cont in
            let gate = OneShotFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_STATE",
                        detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port) state=ready"
                    )
                    cont.resume(returning: .success(listener))
                case .failed(let error):
                    guard gate.claim() else { return }
                    let mapped = LANProxyBridgeError.from(nwError: error)
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_STATE",
                        detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port) state=failed nwerror=\(Self.describe(error)) mapped=\(mapped.shortDescription)"
                    )
                    listener.cancel()
                    cont.resume(returning: .failure(mapped))
                case .cancelled:
                    guard gate.claim() else { return }
                    cont.resume(returning: .failure(.bindFailed("cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        if case .success = started {
            // Keep watching for post-ready failures (e.g. interface drop) once live.
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_FAILED",
                        detail: "kind=\(label) reason=\(Self.describe(err))"
                    )
                    self?.lastError = err.localizedDescription
                }
            }
        }
        return started
    }

    /// Human-readable NWError including the POSIX errno when present (e.g. `posix:EINVAL(22)`).
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "posix:\(code)(\(code.rawValue)) - \(error.localizedDescription)"
        case .dns(let code):
            return "dns:\(code) - \(error.localizedDescription)"
        case .tls(let code):
            return "tls:\(code) - \(error.localizedDescription)"
        case .wifiAware(let code):
            return "wifiAware:\(code) - \(error.localizedDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: - Connection tracking

    private func track(_ conn: NWConnection) {
        stateLock.lock()
        activeConnections[ObjectIdentifier(conn)] = conn
        stateLock.unlock()
    }

    private func untrack(_ conn: NWConnection) {
        stateLock.lock()
        activeConnections.removeValue(forKey: ObjectIdentifier(conn))
        stateLock.unlock()
    }

    private func track(session: RelaySession) {
        stateLock.lock()
        activeSessions[ObjectIdentifier(session)] = session
        stateLock.unlock()
    }

    private func untrack(session: RelaySession) {
        stateLock.lock()
        activeSessions.removeValue(forKey: ObjectIdentifier(session))
        stateLock.unlock()
    }

    private func track(session: FDRelaySession) {
        stateLock.lock()
        activeFDRelaySessions[ObjectIdentifier(session)] = session
        stateLock.unlock()
    }

    private func untrack(session: FDRelaySession) {
        stateLock.lock()
        activeFDRelaySessions.removeValue(forKey: ObjectIdentifier(session))
        stateLock.unlock()
    }

    // MARK: - Accept handlers

    /// Why we terminate the proxy protocol instead of doing a transparent byte relay:
    ///
    /// A naive TCP relay that just shovels bytes to Psiphon's loopback HTTP/SOCKS proxy fails for
    /// HTTPS. Browsers send `CONNECT host:443` for TLS, and the relay must answer
    /// `200 Connection Established` and only then start the bidirectional tunnel. Apps like Telegram
    /// don't honor the system HTTP proxy at all (they connect directly), which is why they appeared
    /// to "work" while Safari / X / Instagram (which DO use the HTTP proxy for HTTPS) failed.
    ///
    /// Both listeners now parse the client's request to extract the target `host:port`, dial it
    /// **through Psiphon's local SOCKS5 proxy** (which natively supports CONNECT to domain names,
    /// so DNS is resolved remotely through the tunnel — no leak), and then run a proper half-close
    /// relay. Plain HTTP (absolute-URI, non-CONNECT) is forwarded transparently to Psiphon's HTTP
    /// proxy, which already handles it.

    private func handleHttpAccept(_ incoming: NWConnection) {
        guard config != nil else { incoming.cancel(); return }
        track(incoming)
        SharedLogger.shared.log(.lanProxyHttpClientConnected)
        if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
            SharedLogger.shared.log(.proxyOnlyClientConnected, detail: "kind=http")
        }
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                incoming.stateUpdateHandler = nil
                Task { [weak self] in await self?.serveHTTP(incoming) }
            case .failed(let e):
                SharedLogger.shared.log(.lanProxyRelayError, detail: "stage=http_accept err=\(e.localizedDescription)")
                self?.untrack(incoming)
                incoming.cancel()
            case .cancelled:
                self?.untrack(incoming)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func handleSocksAccept(_ incoming: NWConnection) {
        guard config != nil else { incoming.cancel(); return }
        track(incoming)
        SharedLogger.shared.log(.lanProxySocksClientConnected)
        if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
            SharedLogger.shared.log(.proxyOnlySocksClientConnected)
        }
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                incoming.stateUpdateHandler = nil
                Task { [weak self] in await self?.serveSOCKS(incoming) }
            case .failed(let e):
                SharedLogger.shared.log(.lanProxyRelayError, detail: "stage=socks_accept err=\(e.localizedDescription)")
                self?.untrack(incoming)
                incoming.cancel()
            case .cancelled:
                self?.untrack(incoming)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    // MARK: - HTTP proxy (CONNECT + absolute-URI)

    private func serveHTTP(_ client: NWConnection) async {
        guard config != nil else { untrack(client); client.cancel(); return }
        do {
            let head = try await readHTTPHead(client)
            guard let firstLineEnd = head.range(of: Data("\r\n".utf8)) else {
                throw BridgeIOError.protocolError("no_request_line")
            }
            let requestLine = String(decoding: head.subdata(in: head.startIndex..<firstLineEnd.lowerBound), as: UTF8.self)
            SharedLogger.shared.log(.lanProxyHttpRequestLine, detail: sanitize(requestLine))
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { throw BridgeIOError.protocolError("bad_request_line") }
            let method = parts[0].uppercased()

            if method == "CONNECT" {
                try await serveHTTPConnect(client: client, target: String(parts[1]))
            } else {
                try await serveHTTPPlain(client: client, initialData: head)
            }
        } catch {
            SharedLogger.shared.log(.lanProxyHttpConnectFailed, detail: errText(error))
            untrack(client)
            client.cancel()
        }
    }

    /// `CONNECT host:port` → dial via Psiphon SOCKS5 → `200` → bidirectional relay.
    private func serveHTTPConnect(client: NWConnection, target: String) async throws {
        guard let cfg = config else { throw BridgeIOError.protocolError("no_config") }
        try await serveHTTPConnect(
            client: client,
            target: target,
            upstream: cfg.upstream,
            logLabel: "http-connect"
        )
    }

    private func serveHTTPConnect(
        client: NWConnection,
        target: String,
        upstream: Endpoints,
        logLabel: String
    ) async throws {
        let (host, port) = Self.splitHostPort(target, defaultPort: 443)
        if logLabel == "system-http" {
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_CONNECT", detail: "\(host):\(port)")
        } else {
            SharedLogger.shared.log(.lanProxyHttpConnectHost, detail: "\(host):\(port)")
        }

        let tunnel: NWConnection
        do {
            tunnel = try await dialViaPsiphonSOCKS(
                host: host,
                port: port,
                upstream: upstream,
                logLabel: logLabel
            )
        } catch {
            try? await sendData(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw error
        }
        try await sendData(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        if logLabel == "system-http" {
            SharedLogger.shared.logRaw("SECURE_DNS_SYSTEM_HTTP_ESTABLISHED", detail: "\(host):\(port)")
        } else {
            SharedLogger.shared.log(.lanProxyHttpConnectEstablished, detail: "\(host):\(port)")
        }
        untrack(client)
        startRelay(client: client, upstream: tunnel, label: logLabel)
    }

    /// Plain HTTP (e.g. `GET http://host/path`) → transparent relay to Psiphon's HTTP proxy,
    /// which natively handles absolute-URI requests and keep-alive.
    private func serveHTTPPlain(client: NWConnection, initialData: Data) async throws {
        guard let cfg = config else { throw BridgeIOError.protocolError("no_config") }
        try await serveHTTPPlain(client: client, initialData: initialData, upstream: cfg.upstream)
    }

    private func serveHTTPPlain(client: NWConnection, initialData: Data, upstream: Endpoints) async throws {
        guard upstream.psiphonHttpPort > 0 else {
            try? await sendData(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw BridgeIOError.protocolError("no_http_upstream")
        }
        let psiphonHttp = try await connectTCP(host: upstream.psiphonHost, port: upstream.psiphonHttpPort)
        try await sendData(psiphonHttp, initialData)
        untrack(client)
        startRelay(client: client, upstream: psiphonHttp, label: "http-plain")
    }

    // MARK: - SOCKS5 proxy

    /// Terminate the client SOCKS5 handshake locally, then re-dial the target through Psiphon's
    /// SOCKS5 proxy. We advertise no-auth and support IPv4 / IPv6 / domain address types.
    private func serveSOCKS(_ client: NWConnection) async {
        guard let cfg = config else { untrack(client); client.cancel(); return }
        do {
            // Greeting: VER=5, NMETHODS, METHODS[NMETHODS]
            let greetingHead = try await receiveExactly(client, 2)
            guard greetingHead[greetingHead.startIndex] == 0x05 else {
                throw BridgeIOError.protocolError("socks_version")
            }
            let nMethods = Int(greetingHead[greetingHead.startIndex + 1])
            if nMethods > 0 { _ = try await receiveExactly(client, nMethods) }
            SharedLogger.shared.log(.lanProxySocksGreetingReceived, detail: "methods=\(nMethods)")
            // Reply: VER=5, METHOD=0 (no auth)
            try await sendData(client, Data([0x05, 0x00]))

            // Request: VER=5, CMD, RSV, ATYP, ADDR, PORT
            let reqHead = try await receiveExactly(client, 4)
            let ver = reqHead[reqHead.startIndex]
            let cmd = reqHead[reqHead.startIndex + 1]
            let atyp = reqHead[reqHead.startIndex + 3]
            guard ver == 0x05 else { throw BridgeIOError.protocolError("socks_req_version") }
            guard cmd == 0x01 else { // only CONNECT
                try? await sendSOCKSReply(client, code: 0x07) // command not supported
                throw BridgeIOError.protocolError("socks_cmd_\(cmd)")
            }
            let host: String
            switch atyp {
            case 0x01: // IPv4
                let addr = try await receiveExactly(client, 4)
                host = addr.map { String($0) }.joined(separator: ".")
            case 0x03: // domain
                let lenByte = try await receiveExactly(client, 1)
                let len = Int(lenByte[lenByte.startIndex])
                let domain = try await receiveExactly(client, len)
                host = String(decoding: domain, as: UTF8.self)
            case 0x04: // IPv6
                let addr = try await receiveExactly(client, 16)
                host = Self.formatIPv6(addr)
            default:
                try? await sendSOCKSReply(client, code: 0x08) // address type not supported
                throw BridgeIOError.protocolError("socks_atyp_\(atyp)")
            }
            let portData = try await receiveExactly(client, 2)
            let port = Int(portData[portData.startIndex]) << 8 | Int(portData[portData.startIndex + 1])
            SharedLogger.shared.log(.lanProxySocksConnectHost, detail: "\(host):\(port) atyp=\(atyp)")

            let upstream: NWConnection
            do {
                upstream = try await dialViaPsiphonSOCKS(
                    host: host,
                    port: port,
                    upstream: cfg.upstream,
                    logLabel: "socks"
                )
            } catch {
                try? await sendSOCKSReply(client, code: 0x05) // connection refused
                throw error
            }
            try await sendSOCKSReply(client, code: 0x00) // success
            SharedLogger.shared.log(.lanProxySocksConnectEstablished, detail: "\(host):\(port)")
            if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
                SharedLogger.shared.log(.proxyOnlySocksHandshakeOk, detail: "\(host):\(port)")
            }
            untrack(client)
            startRelay(client: client, upstream: upstream, label: "socks")
        } catch {
            if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
                SharedLogger.shared.log(.proxyOnlySocksHandshakeFailed, detail: errText(error))
            }
            SharedLogger.shared.log(.lanProxyRelayError, detail: "stage=socks_handshake \(errText(error))")
            untrack(client)
            client.cancel()
        }
    }

    /// SOCKS5 reply with BND.ADDR = 0.0.0.0, BND.PORT = 0 (clients ignore these for CONNECT).
    private func sendSOCKSReply(_ client: NWConnection, code: UInt8) async throws {
        try await sendData(client, Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    }

    // MARK: - Upstream dial via Psiphon SOCKS5

    /// Perform a SOCKS5 CONNECT handshake against Psiphon's loopback SOCKS proxy and hand back the
    /// resulting tunnel.
    private func dialViaPsiphonSOCKS(
        host: String,
        port: Int,
        upstream: Endpoints,
        logLabel: String
    ) async throws -> NWConnection {
        let dialHost = try await secureDNSDialHostIfNeeded(
            host: host,
            upstream: upstream,
            logLabel: logLabel
        )
        if dialHost != host {
            SharedLogger.shared.logRaw(
                "LAN_PROXY_SOCKS_DIAL_HOST",
                detail: "label=\(logLabel) requested=\(host) dial=\(dialHost):\(port)"
            )
        }
        let conn = try await connectTCP(host: upstream.psiphonHost, port: upstream.psiphonSocksPort)
        do {
            // Greeting: VER=5, 1 method, no-auth
            try await sendData(conn, Data([0x05, 0x01, 0x00]))
            let methodSel = try await receiveExactly(conn, 2)
            guard methodSel[methodSel.startIndex] == 0x05,
                  methodSel[methodSel.startIndex + 1] == 0x00 else {
                throw BridgeIOError.protocolError("upstream_method")
            }
            // CONNECT request
            var req = Data([0x05, 0x01, 0x00])
            if let v4 = Self.ipv4Bytes(dialHost) {
                req.append(0x01); req.append(contentsOf: v4)
            } else {
                let hostBytes = Array(dialHost.utf8)
                guard hostBytes.count <= 255 else { throw BridgeIOError.protocolError("host_too_long") }
                req.append(0x03); req.append(UInt8(hostBytes.count)); req.append(contentsOf: hostBytes)
            }
            req.append(UInt8((port >> 8) & 0xFF)); req.append(UInt8(port & 0xFF))
            try await sendData(conn, req)

            // Reply: VER REP RSV ATYP + BND.ADDR + BND.PORT
            let head = try await receiveExactly(conn, 4)
            guard head[head.startIndex] == 0x05 else { throw BridgeIOError.protocolError("upstream_reply_ver") }
            let rep = head[head.startIndex + 1]
            guard rep == 0x00 else { throw BridgeIOError.socksReply(rep) }
            let atyp = head[head.startIndex + 3]
            switch atyp {
            case 0x01: _ = try await receiveExactly(conn, 4 + 2)
            case 0x03:
                let l = try await receiveExactly(conn, 1)
                _ = try await receiveExactly(conn, Int(l[l.startIndex]) + 2)
            case 0x04: _ = try await receiveExactly(conn, 16 + 2)
            default: throw BridgeIOError.protocolError("upstream_bnd_atyp")
            }
            return conn
        } catch {
            conn.cancel()
            throw error
        }
    }

    private func secureDNSDialHostIfNeeded(
        host: String,
        upstream: Endpoints,
        logLabel: String
    ) async throws -> String {
        let remapped = Socks5TCPClient.socksTargetHost(for: host)
        guard logLabel == "system-http" else { return remapped }
        guard Self.ipv4Bytes(host) == nil, !host.contains(":") else { return remapped }

        let settings = SharedSettingsStore.shared.appSettings
        guard settings.secureDNSMode == .doh else { return remapped }

        let qname = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let queryId = UInt16.random(in: 1...UInt16.max)
        let query = try SecureDNSResolver.buildAQuery(qname: qname, id: queryId)
        SharedLogger.shared.logRaw(
            "DNS_QUERY_RECEIVED",
            detail: "id=\(queryId) qname=\(qname) type=A qtype=1 source=system-http"
        )

        do {
            let result = try await SecureDNSResolver.resolve(
                wireQuery: query,
                queryId: queryId,
                qname: qname,
                settings: settings,
                socksPort: upstream.psiphonSocksPort,
                httpPort: upstream.psiphonHttpPort
            )
            guard let ip = SecureDNSResolver.ipv4Answers(from: result.payload).first else {
                throw SecureDNSTransportError.dohBadStatus(-13)
            }
            SharedLogger.shared.logRaw(
                "DNS_RESPONSE_SENT",
                detail: "id=\(queryId) secure=true bytes=\(result.payload.count) qname=\(qname) source=system-http"
            )
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_RESOLVED",
                detail: "qname=\(qname) ip=\(ip) secure=true"
            )
            return Socks5TCPClient.socksTargetHost(for: ip)
        } catch {
            if settings.blockCleartextDNS {
                SharedLogger.shared.log(
                    .secureDnsCleartextBlocked,
                    detail: "id=\(queryId) source=system-http qname=\(qname) reason=\(error.localizedDescription)"
                )
                throw error
            }
            SharedLogger.shared.logRaw(
                "DNS_LEGACY_FALLBACK",
                detail: "id=\(queryId) qname=\(qname) source=system-http reason=\(error.localizedDescription)"
            )
            SharedLogger.shared.logRaw(
                "SECURE_DNS_BYPASS_DETECTED",
                detail: "reason=system_http_fallback_to_socks_dns qname=\(qname) block_cleartext=false"
            )
            return remapped
        }
    }

    // MARK: - Relay

    private func startRelay(client: NWConnection, upstream: NWConnection, label: String) {
        let session = RelaySession(client: client, upstream: upstream, queue: queue, label: label)
        track(session: session)
        // Capture `session` weakly to avoid a session → onFinished → session retain cycle;
        // the strong reference lives in `activeSessions` until we untrack it here.
        session.onFinished = { [weak self, weak session] in
            guard let session else { return }
            self?.untrack(session: session)
        }
        session.start()
    }

    private func startRelay(clientFD: Int32, upstream: NWConnection, label: String) {
        let session = FDRelaySession(clientFD: clientFD, upstream: upstream, queue: queue, label: label)
        track(session: session)
        session.onFinished = { [weak self, weak session] in
            guard let session else { return }
            self?.untrack(session: session)
        }
        session.start()
    }

    // MARK: - Low-level IO helpers

    private func connectTCP(host: String, port: Int) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw BridgeIOError.protocolError("bad_port_\(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OneShotFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    cont.resume()
                case .failed(let e):
                    guard gate.claim() else { return }
                    cont.resume(throwing: e)
                case .cancelled:
                    guard gate.claim() else { return }
                    cont.resume(throwing: BridgeIOError.cancelled)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        return conn
    }

    private final class OneShotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Read until the HTTP header terminator `\r\n\r\n` (or EOF / cap), returning everything read.
    private func readHTTPHead(_ conn: NWConnection, limit: Int = 32 * 1024) async throws -> Data {
        var buffer = Data()
        while buffer.count < limit {
            let chunk = try await receiveSome(conn, max: min(4096, limit - buffer.count))
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard !buffer.isEmpty else { throw BridgeIOError.eof }
        return buffer
    }

    /// Read exactly `count` bytes, looping until satisfied or throwing on early EOF.
    private func receiveExactly(_ conn: NWConnection, _ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveSome(conn, max: count - buffer.count)
            if chunk.isEmpty { throw BridgeIOError.eof }
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveSome(_ conn: NWConnection, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: Swift.max(1, max)) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return } // EOF sentinel
                cont.resume(returning: Data())
            }
        }
    }

    private func sendData(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func readHTTPHead(fd: Int32, limit: Int = 32 * 1024) async throws -> Data {
        var buffer = Data()
        while buffer.count < limit {
            let chunk = try await receiveSome(fd: fd, max: min(4096, limit - buffer.count))
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard !buffer.isEmpty else { throw BridgeIOError.eof }
        return buffer
    }

    private func receiveExactly(fd: Int32, _ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveSome(fd: fd, max: count - buffer.count)
            if chunk.isEmpty { throw BridgeIOError.eof }
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveSome(fd: Int32, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                var buf = [UInt8](repeating: 0, count: Swift.max(1, max))
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0 {
                    cont.resume(throwing: BridgeIOError.protocolError(String(cString: strerror(errno))))
                    return
                }
                if n == 0 {
                    cont.resume(returning: Data())
                    return
                }
                cont.resume(returning: Data(buf[0..<n]))
            }
        }
    }

    private func sendData(fd: Int32, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let sent = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                    return send(fd, base, raw.count, 0)
                }
                if sent < 0 {
                    cont.resume(throwing: BridgeIOError.protocolError(String(cString: strerror(errno))))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func sanitize(_ line: String) -> String {
        // Request line carries the target URL only (no credentials) but keep it bounded for logs.
        String(line.prefix(256))
    }

    private func errText(_ error: Error) -> String {
        if let bridgeErr = error as? BridgeIOError { return bridgeErr.shortDescription }
        return error.localizedDescription
    }

    // MARK: - Address helpers

    static func splitHostPort(_ target: String, defaultPort: Int) -> (String, Int) {
        // IPv6 literal: [::1]:443
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { return (host, p) }
            return (host, defaultPort)
        }
        if let colon = target.lastIndex(of: ":"),
           let p = Int(target[target.index(after: colon)...]) {
            return (String(target[target.startIndex..<colon]), p)
        }
        return (target, defaultPort)
    }

    static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes = [UInt8]()
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            bytes.append(v)
        }
        return bytes
    }

    static func formatIPv6(_ data: Data) -> String {
        var groups: [String] = []
        let arr = [UInt8](data)
        var i = 0
        while i + 1 < arr.count {
            groups.append(String(format: "%x", Int(arr[i]) << 8 | Int(arr[i + 1])))
            i += 2
        }
        return groups.joined(separator: ":")
    }
}

/// Bidirectional relay with independent half-close.
///
/// Each direction pumps until it sees EOF, then sends FIN on the peer's write side but keeps the
/// other direction open — only when BOTH directions finish (or a hard error occurs) are both
/// connections cancelled. This prevents truncating large TLS streams and prevents the classic
/// "close on first EOF" bug that breaks long-lived HTTPS connections.
final class RelaySession: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let label: String
    private let lock = NSLock()
    private var clientToUpstreamDone = false
    private var upstreamToClientDone = false
    private var finished = false
    var onFinished: (() -> Void)?

    init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue, label: String) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
        self.label = label
    }

    func start() {
        SharedLogger.shared.log(.lanProxyRelayStarted, detail: "label=\(label)")
        pump(from: client, to: upstream, clientToUpstream: true)
        pump(from: upstream, to: client, clientToUpstream: false)
    }

    func cancel() {
        finish(reason: "cancelled", isError: false)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, clientToUpstream: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                SharedLogger.shared.log(.lanProxyRelayError, detail: "label=\(self.label) dir=\(clientToUpstream ? "c2u" : "u2c") err=\(error.localizedDescription)")
                self.finish(reason: "read_error", isError: true)
                return
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendErr in
                    guard let self else { return }
                    if let sendErr {
                        SharedLogger.shared.log(.lanProxyRelayError, detail: "label=\(self.label) dir=\(clientToUpstream ? "c2u" : "u2c") stage=write err=\(sendErr.localizedDescription)")
                        self.finish(reason: "write_error", isError: true)
                        return
                    }
                    if isComplete {
                        self.halfClose(destination)
                        self.markDirectionDone(clientToUpstream: clientToUpstream)
                    } else {
                        self.pump(from: source, to: destination, clientToUpstream: clientToUpstream)
                    }
                })
            } else if isComplete {
                self.halfClose(destination)
                self.markDirectionDone(clientToUpstream: clientToUpstream)
            } else {
                self.pump(from: source, to: destination, clientToUpstream: clientToUpstream)
            }
        }
    }

    private func halfClose(_ conn: NWConnection) {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func markDirectionDone(clientToUpstream: Bool) {
        lock.lock()
        if clientToUpstream { clientToUpstreamDone = true } else { upstreamToClientDone = true }
        let bothDone = clientToUpstreamDone && upstreamToClientDone
        lock.unlock()
        if bothDone {
            finish(reason: "eof", isError: false)
        }
    }

    private func finish(reason: String, isError: Bool) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        client.cancel()
        upstream.cancel()
        SharedLogger.shared.log(.lanProxyRelayClosed, detail: "label=\(label) reason=\(reason)")
        onFinished?()
    }
}

/// Relay between a POSIX client socket (system HTTP proxy) and an `NWConnection` upstream.
final class FDRelaySession: @unchecked Sendable {
    private let clientFD: Int32
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let label: String
    private let lock = NSLock()
    private var clientToUpstreamDone = false
    private var upstreamToClientDone = false
    private var finished = false
    var onFinished: (() -> Void)?

    init(clientFD: Int32, upstream: NWConnection, queue: DispatchQueue, label: String) {
        self.clientFD = clientFD
        self.upstream = upstream
        self.queue = queue
        self.label = label
    }

    func start() {
        SharedLogger.shared.log(.lanProxyRelayStarted, detail: "label=\(label)")
        pumpClientToUpstream()
        pumpUpstreamToClient()
    }

    func cancel() {
        finish(reason: "cancelled", isError: false)
    }

    private func pumpClientToUpstream() {
        queue.async { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = recv(self.clientFD, &buf, buf.count, 0)
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    self.queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.pumpClientToUpstream()
                    }
                    return
                }
                SharedLogger.shared.log(
                    .lanProxyRelayError,
                    detail: "label=\(self.label) dir=c2u stage=fd_read errno=\(err) err=\(String(cString: strerror(err)))"
                )
                self.finish(reason: "read_error", isError: true)
                return
            }
            if n == 0 {
                self.halfCloseUpstream()
                self.markDirectionDone(clientToUpstream: true)
                return
            }
            let data = Data(buf[0..<n])
            self.upstream.send(content: data, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                if let err {
                    SharedLogger.shared.log(.lanProxyRelayError, detail: "label=\(self.label) dir=c2u err=\(err.localizedDescription)")
                    self.finish(reason: "write_error", isError: true)
                    return
                }
                self.pumpClientToUpstream()
            })
        }
    }

    private func pumpUpstreamToClient() {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                SharedLogger.shared.log(.lanProxyRelayError, detail: "label=\(self.label) dir=u2c err=\(error.localizedDescription)")
                self.finish(reason: "read_error", isError: true)
                return
            }
            if let data, !data.isEmpty {
                self.writeAllToClient(data) { [weak self] ok in
                    guard let self else { return }
                    guard ok else { return }
                    if isComplete {
                        self.halfCloseClient()
                        self.markDirectionDone(clientToUpstream: false)
                    } else {
                        self.pumpUpstreamToClient()
                    }
                }
            } else if isComplete {
                self.halfCloseClient()
                self.markDirectionDone(clientToUpstream: false)
            } else {
                self.pumpUpstreamToClient()
            }
        }
    }

    private func writeAllToClient(_ data: Data, offset: Int = 0, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(false); return }
            guard offset < data.count else {
                completion(true)
                return
            }

            let remaining = data.count - offset
            let sent = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return send(self.clientFD, base.advanced(by: offset), remaining, 0)
            }
            if sent < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    self.queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.writeAllToClient(data, offset: offset, completion: completion)
                    }
                    return
                }
                SharedLogger.shared.log(
                    .lanProxyRelayError,
                    detail: "label=\(self.label) dir=u2c stage=fd_write errno=\(err) err=\(String(cString: strerror(err)))"
                )
                self.finish(reason: "write_error", isError: true)
                completion(false)
                return
            }
            if sent == 0 {
                self.queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.writeAllToClient(data, offset: offset, completion: completion)
                }
                return
            }
            self.writeAllToClient(data, offset: offset + sent, completion: completion)
        }
    }

    private func halfCloseUpstream() {
        upstream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func halfCloseClient() {
        shutdown(clientFD, SHUT_WR)
    }

    private func markDirectionDone(clientToUpstream: Bool) {
        lock.lock()
        if clientToUpstream { clientToUpstreamDone = true } else { upstreamToClientDone = true }
        let bothDone = clientToUpstreamDone && upstreamToClientDone
        lock.unlock()
        if bothDone {
            finish(reason: "eof", isError: false)
        }
    }

    private func finish(reason: String, isError: Bool) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        close(clientFD)
        upstream.cancel()
        SharedLogger.shared.log(.lanProxyRelayClosed, detail: "label=\(label) reason=\(reason)")
        onFinished?()
    }
}

enum BridgeIOError: Error {
    case eof
    case cancelled
    case protocolError(String)
    case socksReply(UInt8)

    var shortDescription: String {
        switch self {
        case .eof: return "eof"
        case .cancelled: return "cancelled"
        case .protocolError(let s): return "protocol:\(s)"
        case .socksReply(let r): return "socks_reply:\(r)"
        }
    }
}

enum LANProxyBridgeError: Error {
    case invalidPort(Int)
    case bindFailed(String)
    case portInUse
    case other(String)

    static func from(nwError: NWError) -> LANProxyBridgeError {
        if case .posix(let code) = nwError, code == .EADDRINUSE {
            return .portInUse
        }
        return .bindFailed(nwError.localizedDescription)
    }

    var shortDescription: String {
        switch self {
        case .invalidPort(let p): return "invalid_port:\(p)"
        case .bindFailed(let s): return "bind_failed:\(s)"
        case .portInUse: return "port_in_use"
        case .other(let s): return s
        }
    }
}
