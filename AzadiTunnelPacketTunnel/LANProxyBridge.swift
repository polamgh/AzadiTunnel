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
    /// Actual interface a listener bound to ("0.0.0.0" after a Wi-Fi-IP fallback). For logs only.
    private var httpBoundInterface: String?
    private var socksBoundInterface: String?
    /// Live client connections / relay sessions, guarded by `stateLock` because protocol
    /// handshakes run on detached Tasks while accepts arrive on the listener queue.
    private let stateLock = NSLock()
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeSessions: [ObjectIdentifier: RelaySession] = [:]
    private var config: Configuration?
    private(set) var lastError: String?

    /// Both listeners must be live for the bridge to be considered fully running.
    var isRunning: Bool {
        httpListener?.state == .ready && socksListener?.state == .ready
    }

    /// Result of a single listener bind, including the interface actually bound.
    private struct ListenerResult {
        let listener: NWListener
        /// Technical bind interface: the Wi-Fi IP, or "0.0.0.0" when we fell back to any-interface.
        let boundInterface: String
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
        activeConnections.removeAll()
        activeSessions.removeAll()
        stateLock.unlock()
        for conn in conns { conn.cancel() }
        for session in sessions { session.cancel() }
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

    // MARK: - Listener factory

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
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_STATE",
                        detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port) state=ready"
                    )
                    cont.resume(returning: .success(listener))
                case .failed(let error):
                    resumed = true
                    let mapped = LANProxyBridgeError.from(nwError: error)
                    SharedLogger.shared.logRaw(
                        "LAN_PROXY_LISTENER_STATE",
                        detail: "kind=\(label) bind_host=\(bindHostLabel) bind_port=\(port) state=failed nwerror=\(Self.describe(error)) mapped=\(mapped.shortDescription)"
                    )
                    listener.cancel()
                    cont.resume(returning: .failure(mapped))
                case .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume(returning: .failure(.bindFailed("cancelled")))
                    }
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
        guard let cfg = config else { untrack(client); client.cancel(); return }
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
        let (host, port) = Self.splitHostPort(target, defaultPort: 443)
        SharedLogger.shared.log(.lanProxyHttpConnectHost, detail: "\(host):\(port)")

        let upstream: NWConnection
        do {
            upstream = try await dialViaPsiphonSOCKS(host: host, port: port, upstream: cfg.upstream)
        } catch {
            // Tell the client the tunnel could not be opened so it fails fast instead of hanging.
            try? await sendData(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw error
        }
        try await sendData(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        SharedLogger.shared.log(.lanProxyHttpConnectEstablished, detail: "\(host):\(port)")
        untrack(client) // ownership transfers to the relay session
        startRelay(client: client, upstream: upstream, label: "http-connect")
    }

    /// Plain HTTP (e.g. `GET http://host/path`) → transparent relay to Psiphon's HTTP proxy,
    /// which natively handles absolute-URI requests and keep-alive.
    private func serveHTTPPlain(client: NWConnection, initialData: Data) async throws {
        guard let cfg = config, cfg.upstream.psiphonHttpPort > 0 else {
            try? await sendData(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            throw BridgeIOError.protocolError("no_http_upstream")
        }
        let upstream = try await connectTCP(host: cfg.upstream.psiphonHost, port: cfg.upstream.psiphonHttpPort)
        try await sendData(upstream, initialData) // forward the bytes we already consumed
        untrack(client)
        startRelay(client: client, upstream: upstream, label: "http-plain")
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
                upstream = try await dialViaPsiphonSOCKS(host: host, port: port, upstream: cfg.upstream)
            } catch {
                try? await sendSOCKSReply(client, code: 0x05) // connection refused
                throw error
            }
            try await sendSOCKSReply(client, code: 0x00) // success
            SharedLogger.shared.log(.lanProxySocksConnectEstablished, detail: "\(host):\(port)")
            untrack(client)
            startRelay(client: client, upstream: upstream, label: "socks")
        } catch {
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
    /// resulting tunnel. Domain names are sent as ATYP=3 so Psiphon resolves them through the tunnel.
    private func dialViaPsiphonSOCKS(host: String, port: Int, upstream: Endpoints) async throws -> NWConnection {
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
            if let v4 = Self.ipv4Bytes(host) {
                req.append(0x01); req.append(contentsOf: v4)
            } else {
                let hostBytes = Array(host.utf8)
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

    // MARK: - Low-level IO helpers

    private func connectTCP(host: String, port: Int) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw BridgeIOError.protocolError("bad_port_\(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: BridgeIOError.cancelled)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        return conn
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
