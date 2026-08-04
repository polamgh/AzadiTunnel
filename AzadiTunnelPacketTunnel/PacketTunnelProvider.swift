import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleLock = NSLock()
    private var pendingStartCompletion: ((Error?) -> Void)?
    private var startupTask: Task<Void, Never>?
    private var stopRequested = false
    private var engine: PsiphonTunnelEngine?
    private var packetBridge: PsiphonPacketTunnelFlowBridge?
    private var statsTimer: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private let psiphonDataDirName = "psiphon-data"
    private let lanProxy = LANProxyBridge()
    private let endpointUpdateLock = NSLock()
    private var endpointUpdateTask: Task<Void, Never>?
    private var pendingEndpointUpdate: PsiphonLocalProxyEndpoints?
    private var endpointUpdateGeneration: UInt64 = 0
    private var endpointUpdatesActive = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard registerStartCompletion(completionHandler) else { return }

        SharedLogger.shared.log(.extensionBoot)
        PsiphonInproxyBuildInfo.logFrameworkProbe()
        SharedLogger.shared.log(.extensionStartEntered)

        SharedSettingsStore.shared.migrateServerEntriesFromDefaultsIfNeeded()

        guard SharedSettingsStore.shared.extensionCanReadSettings() else {
            SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=app_group_unavailable")
            completeStart(NSError(domain: "AzadiTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group unavailable"]))
            return
        }
        SharedLogger.shared.log(.extensionSettingsLoaded)

        guard let configJSON = SharedSettingsStore.shared.psiphonConfigJSON else {
            SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=no_config")
            completeStart(NSError(domain: "AzadiTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Psiphon configuration not installed"]))
            return
        }

        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit,
           !SharedSettingsStore.shared.conduitConnectAllowed {
            let readiness = SharedSettingsStore.shared.conduitDistributorReadiness
            SharedLogger.shared.logRaw("CONDUIT_BLOCKED", detail: "missing_distributor_keys \(readiness.logDetail)")
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: true)
            completeStart(NSError(
                domain: "AzadiTunnel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: PsiphonDistributorKeys.conduitBlockedStatusLine]
            ))
            return
        }

        if SharedSettingsStore.shared.usesBundledConfig {
            SharedLogger.shared.log(.psiphonConnectUsingBundledConfig)
        }
        if SharedSettingsStore.shared.psiphonServerEntriesLineCount > 0 {
            SharedLogger.shared.log(
                .psiphonServerEntriesLoaded,
                detail: "lines=\(SharedSettingsStore.shared.psiphonServerEntriesLineCount)"
            )
        }

        if let configJSON = SharedSettingsStore.shared.psiphonConfigJSON {
            let limit = PsiphonConfigComposer.parseLimitProtocols(from: configJSON)
            let proto = SharedSettingsStore.shared.appSettings.protocolSelection.rawValue
            let beast = SharedSettingsStore.shared.appSettings.beastModeEnabled
            SharedLogger.shared.logRaw(
                "PSIPHON_PROTOCOL_LIMIT",
                detail: "selection=\(proto) beast=\(beast) limits=\(limit)"
            )
            SharedLogger.shared.logRaw(
                "PSIPHON_SHIRO_CONFIG",
                detail: PsiphonShiroTunnelConfig.logSummary(
                    settings: SharedSettingsStore.shared.appSettings,
                    composedJSON: configJSON,
                    embeddedServerEntryLines: SharedSettingsStore.shared.psiphonServerEntriesLineCount
                )
            )
            let selection = SharedSettingsStore.shared.appSettings.protocolSelection
            if selection == .cdnFronting {
                let limits = PsiphonConfigComposer.parseLimitProtocols(from: configJSON)
                SharedLogger.shared.logRaw(
                    "CDN_FRONTING_CONFIG",
                    detail: PsiphonShiroCDNFrontingConfig.logSummary(
                        settings: SharedSettingsStore.shared.appSettings,
                        composedJSON: configJSON
                    )
                )
                SharedLogger.shared.logRaw(
                    "CDN_FRONTING_PROTOCOL_LIMITS",
                    detail: "count=\(PsiphonShiroCDNFrontingConfig.cdnFrontingModeProtocols.count) values=\(limits)"
                )
                let customIPs = PsiphonShiroCDNFrontingConfig.parseIPList(
                    SharedSettingsStore.shared.appSettings.cdnFrontingCustomIpList
                )
                let customSNIs = PsiphonShiroCDNFrontingConfig.parseSNIList(
                    SharedSettingsStore.shared.appSettings.cdnFrontingCustomSni
                )
                SharedLogger.shared.logRaw(
                    "CDN_FRONTING_EDGE_IPS",
                    detail: "builtin=\(PsiphonShiroCDNFrontingConfig.builtInEdgeIPs.count) custom=\(customIPs.count)"
                )
                SharedLogger.shared.logRaw(
                    "CDN_FRONTING_SNI_HOSTNAMES",
                    detail: "count=\(customSNIs.count)"
                )
            }
            if selection == .conduit {
                let settings = SharedSettingsStore.shared.appSettings
                let mode = settings.conduitMode.rawValue
                let compartment = PsiphonConduitConfig.usesPersonalCompartment(settings: settings)
                let hasPersonalID = PsiphonConfigComposer.hasPersonalConduitCompartment(in: configJSON)
                let dict = (try? JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any]) ?? [:]
                let geo = (dict["GeoIPDatabasePath"] as? String) ?? ""
                let reject = dict["InproxyRejectProxyCountryCodes"] as? [String]
                let disableTactics = dict["DisableTactics"] as? Bool == true
                let readiness = SharedSettingsStore.shared.conduitDistributorReadiness
                SharedLogger.shared.logRaw(
                    "CONDUIT_CONFIG",
                    detail: "mode=\(mode) personal_compartment=\(compartment) compartment_in_json=\(hasPersonalID) protocols=\(PsiphonProtocolSets.conduit.count) geoip=\(!geo.isEmpty) reject_countries=\(reject?.count ?? 0) disable_tactics=\(disableTactics) \(readiness.logDetail)"
                )
                PsiphonShiroConduitCompare.logComposedConfig(
                    dict: dict,
                    settings: settings,
                    embeddedServerEntryLines: SharedSettingsStore.shared.psiphonServerEntriesLineCount
                )
                PsiphonCommunityDiagnostics.logCompareStarted(
                    composedJSON: configJSON,
                    settings: settings
                )
            }
        }

        let region = SharedSettingsStore.shared.appSettings.egressRegion
        if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled,
           LocalNetworkAddress.wifiIPv4() == nil {
            SharedLogger.shared.log(.proxyOnlyBlockedNoWifi, detail: "source=extension")
            completeStart(NSError(
                domain: "AzadiTunnel",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Proxy Only Mode requires Wi-Fi."]
            ))
            return
        }

        TunnelStatisticsStore.resetSession()
        SharedSettingsStore.shared.lastInternetTestOK = false
        SharedSettingsStore.shared.psiphonTunnelEstablished = false

        let task = Task {
            do {
                SharedLogger.shared.log(.psiphonCoreSelected, detail: "impl=PsiphonTunnel")
                let dataDir = try self.psiphonDataDirectory()
                let psiphonEngine = PsiphonTunnelEngine(core: ExtensionPsiphonCore.make())
                self.installEngine(psiphonEngine)
                psiphonEngine.onLocalProxyEndpointsChanged = { [weak self, weak psiphonEngine] endpoints in
                    guard let psiphonEngine else { return }
                    self?.scheduleEndpointUpdate(endpoints, for: psiphonEngine)
                }
                let entriesPath = SharedSettingsStore.shared.psiphonServerEntriesPath
                let packetEngineCapabilities = psiphonEngine.packetEngineCapabilities
                SharedLogger.shared.logRaw(
                    "PACKET_ENGINE_CAPABILITIES",
                    detail: "ipv6=\(packetEngineCapabilities.logValue)"
                )
                let appSettings = SharedSettingsStore.shared.appSettings
                let proxyOnly = appSettings.proxyOnlyModeEnabled

                if proxyOnly {
                    SharedLogger.shared.log(.proxyOnlyModeEnabled)
                    SharedLogger.shared.log(.proxyOnlyWarningNotFullVPN)
                } else {
                    SharedLogger.shared.log(.proxyOnlyModeDisabled)
                }

                let bridge = proxyOnly ? nil : PsiphonPacketTunnelFlowBridge(packetFlow: self.packetFlow)
                bridge?.setFailureHandler { [weak self] error in
                    self?.handlePacketBridgeFailure(error)
                }
                self.packetBridge = bridge
                try await psiphonEngine.start(
                    configJSON: configJSON,
                    serverEntriesPath: entriesPath,
                    dataDir: dataDir,
                    packetTunnel: bridge
                )
                try Task.checkCancellation()

                let endpoints = psiphonEngine.localProxyEndpoints
                guard proxyOnly == false || endpoints.hasSocks else {
                    throw PsiphonTunnelCoreError.proxyNotReady
                }

                let secureDnsSettings = SharedSettingsStore.shared.tunnelEffectiveAppSettings
                if !proxyOnly,
                   SecureDNSConfiguration.isActive(secureDnsSettings),
                   !endpoints.hasSocks {
                    throw PsiphonTunnelCoreError.startFailed(
                        "secure_dns_requires_psiphon_socks_for_local_dns_interception"
                    )
                }

                let networkSettings = proxyOnly
                    ? Self.makeProxyOnlyNetworkSettings()
                    : Self.makeNetworkSettings(packetEngineCapabilities: packetEngineCapabilities)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.setTunnelNetworkSettings(networkSettings) { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
                }
                try Task.checkCancellation()

                if !proxyOnly {
                    SecureDNSConfiguration.logStartupStatus(SharedSettingsStore.shared.tunnelEffectiveAppSettings)
                    bridge?.setDNSHandler { [weak self] packet, protocolNumber in
                        guard let self,
                              let dnsEndpoints = self.engine?.localProxyEndpoints,
                              dnsEndpoints.hasSocks else {
                            return false
                        }
                        return TunnelDnsForwarder.handleIfDnsQuery(
                            packet: packet,
                            protocolNumber: protocolNumber,
                            packetFlow: self.packetFlow,
                            socksHost: dnsEndpoints.host,
                            socksPort: dnsEndpoints.socksPort,
                            httpPort: dnsEndpoints.httpPort,
                            packetEngineCapabilities: packetEngineCapabilities
                        )
                    }
                    bridge?.start()
                    SharedLogger.shared.logRaw(
                        "PSIPHON_NATIVE_PACKET_TUNNEL_READY",
                        detail: "capability=\(packetEngineCapabilities.logValue) transports=tcp,udp dns=core_plus_secure_dns_callback"
                    )
                }

                TunnelStatisticsStore.markConnected(
                    region: region.isEmpty ? "Any" : region,
                    proxyOnly: proxyOnly
                )
                self.startStatsSampler()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                if endpoints.hasSocks || endpoints.hasHttp {
                    self.startConnectivityProbe(endpoints: endpoints)
                } else {
                    SharedLogger.shared.logRaw(
                        "TUNNEL_CONNECTIVITY_PROBE_SKIPPED",
                        detail: "reason=no_local_proxy native_packet_mode=true"
                    )
                }

                SharedSettingsStore.shared.vpnStatus = .connected
                SharedLogger.shared.log(.tunnelConnected)

                if endpoints.hasSocks {
                    await self.startProxyBridge(using: endpoints, proxyOnly: proxyOnly)
                }

                self.activateEndpointUpdates(for: psiphonEngine)

                if proxyOnly {
                    Task {
                        let ip = await ProxyOnlyPublicIPService.fetch(endpoints: endpoints)
                        if !ip.isEmpty {
                            TunnelStatisticsStore.setPublicIP(ip)
                        }
                    }
                }

                self.completeStart(nil)
            } catch {
                SharedLogger.shared.log(.psiphonConnectFailed, detail: "reason=\(error.localizedDescription)")
                SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=\(error.localizedDescription)")
                await self.cleanup()
                self.completeStart(error)
            }
        }
        lifecycleLock.lock()
        let cancelImmediately = stopRequested
        if !cancelImmediately {
            startupTask = task
        }
        lifecycleLock.unlock()
        if cancelImmediately {
            task.cancel()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SharedLogger.shared.log(.extensionStopEntered, detail: "reason=\(reason.rawValue)")
        cancelPendingStart()
        stopLANProxy(reason: .vpnDisconnected)
        stopPacketForwarding()
        TunnelStatisticsStore.markDisconnected()
        SharedSettingsStore.shared.vpnStatus = .disconnected
        SharedLogger.shared.log(.tunnelStopCleanup)
        completionHandler()

        let engineToStop = detachEngineAndStopEndpointUpdates()
        guard let engineToStop else { return }
        Task {
            await engineToStop.stopWithTimeout(seconds: 10)
            SharedLogger.shared.log(.psiphonStopped)
        }
    }

    private func registerStartCompletion(_ completion: @escaping (Error?) -> Void) -> Bool {
        lifecycleLock.lock()
        guard pendingStartCompletion == nil else {
            lifecycleLock.unlock()
            completion(Self.lifecycleError(code: 10, reason: "tunnel_start_already_in_progress"))
            return false
        }
        stopRequested = false
        pendingStartCompletion = completion
        lifecycleLock.unlock()
        return true
    }

    /// Delivers the Network Extension start completion at most once. A stop
    /// wins over a racing success so a callback-device failure cannot leave a
    /// tunnel reported as started after the provider has begun shutting down.
    private func completeStart(_ error: Error?) {
        lifecycleLock.lock()
        guard let completion = pendingStartCompletion else {
            lifecycleLock.unlock()
            return
        }
        let finalError = error ?? (stopRequested ? Self.lifecycleError(code: 11, reason: "tunnel_start_cancelled") : nil)
        pendingStartCompletion = nil
        lifecycleLock.unlock()
        completion(finalError)
    }

    private func cancelPendingStart() {
        lifecycleLock.lock()
        stopRequested = true
        let task = startupTask
        startupTask = nil
        lifecycleLock.unlock()
        task?.cancel()
        completeStart(Self.lifecycleError(code: 11, reason: "tunnel_start_cancelled"))
    }

    private func handlePacketBridgeFailure(_ error: NSError) {
        cancelPendingStart()
        cancelTunnelWithError(error)
    }

    private static func lifecycleError(code: Int, reason: String) -> NSError {
        NSError(
            domain: "AzadiTunnel.PacketTunnelLifecycle",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private func startConnectivityProbe(endpoints: PsiphonLocalProxyEndpoints) {
        connectivityTask?.cancel()
        connectivityTask = Task {
            _ = await TunnelConnectivityProbe.verifyGenerate204(endpoints: endpoints)
        }
    }

#if false
    private func startSecureDnsSystemProxyIfUsable(
        settings: AppSettings,
        endpoints: PsiphonLocalProxyEndpoints
    ) async -> Bool {
        let upstream = LANProxyBridge.Endpoints(
            psiphonHost: endpoints.host,
            psiphonHttpPort: endpoints.httpPort,
            psiphonSocksPort: endpoints.socksPort
        )
        guard await secureDnsSystemProxy.startLoopbackHTTPProxy(upstream: upstream) else {
            return false
        }

        let query = SecureDNSConfiguration.exampleComWireQuery
        let queryId = SecureDNSResolver.queryId(from: query)
        guard let endpoint = SecureDNSConfiguration.dohEndpoint(for: settings) else {
            secureDnsSystemProxy.stopLoopbackHTTPProxy()
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY_FAILED",
                detail: "reason=no_doh_endpoint mode=\(settings.secureDNSMode.rawValue)"
            )
            return false
        }

        do {
            let payload = try await SecureDNSDoHClient.post(
                endpoint: endpoint,
                provider: settings.secureDNSProvider,
                wireQuery: query,
                socksPort: endpoints.socksPort,
                httpPort: endpoints.httpPort,
                queryId: queryId,
                qname: "example.com"
            )
            _ = try SecureDNSResolver.validateDNSWireResponse(payload, expectedId: queryId)
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY_READY",
                detail: "secure_dns_probe=ok provider=\(settings.secureDNSProvider.rawValue)"
            )
            return true
        } catch {
            secureDnsSystemProxy.stopLoopbackHTTPProxy()
            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY_FAILED",
                detail: "reason=doh_probe_failed provider=\(settings.secureDNSProvider.rawValue) error=\(error.localizedDescription)"
            )
            if settings.blockCleartextDNS {
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_PROXY",
                    detail: "disabled_bridge_probe_failed block_cleartext=true mode=\(settings.secureDNSMode.rawValue)"
                )
            } else {
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_HTTP_PROXY_FALLBACK",
                    detail: "using_psiphon_http reason=doh_probe_failed block_cleartext=false"
                )
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_BRIDGE_FALLBACK_TO_PSIPHON_PROXY",
                    detail: "reason=system_http_bridge_doh_probe_failed block_cleartext=false"
                )
            }
            return false
        }
    }

    private func startSecureDnsSystemProxyActivationIfNeeded(
        settings: AppSettings,
        endpoints: PsiphonLocalProxyEndpoints,
        packetEngineCapabilities: PacketEngineCapabilities,
        proxyOnly: Bool
    ) {
        secureDnsSystemProxyTask?.cancel()
        guard !proxyOnly,
              settings.secureDNSMode == .doh,
              SecureDNSConfiguration.usesSystemHTTPProxyBridge(for: settings) else {
            return
        }

        secureDnsSystemProxyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            SharedLogger.shared.logRaw(
                "SECURE_DNS_SYSTEM_HTTP_PROXY_PROBE",
                detail: "mode=\(settings.secureDNSMode.rawValue) provider=\(settings.secureDNSProvider.rawValue)"
            )
            let usable = await self.startSecureDnsSystemProxyIfUsable(
                settings: settings,
                endpoints: endpoints
            )
            guard usable, !Task.isCancelled else { return }

            let updatedSettings = Self.makeNetworkSettings(
                endpoints: endpoints,
                packetEngineCapabilities: packetEngineCapabilities,
                secureDnsSystemProxyActive: true
            )
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.setTunnelNetworkSettings(updatedSettings) { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
                }
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_PROXY_ACTIVATED",
                    detail: "using_loopback_bridge port=\(SecureDNSConfiguration.systemHTTPProxyPort)"
                )
            } catch {
                self.secureDnsSystemProxy.stopLoopbackHTTPProxy()
                SharedLogger.shared.logRaw(
                    "SECURE_DNS_SYSTEM_HTTP_PROXY_FAILED",
                    detail: "reason=apply_network_settings_failed error=\(error.localizedDescription)"
                )
            }
        }
    }

#endif
    private func startStatsSampler() {
        statsTimer?.cancel()
        statsTimer = Task {
            var lastDown: UInt64 = 0
            var lastUp: UInt64 = 0
            let tick: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tick)
                let s = TunnelStatisticsStore.load()
                let dDown = s.bytesDown &- lastDown
                let dUp = s.bytesUp &- lastUp
                lastDown = s.bytesDown
                lastUp = s.bytesUp
                TunnelStatisticsStore.updateSpeeds(downloadBps: dDown, uploadBps: dUp)
            }
        }
    }

    private func stopPacketForwarding() {
        connectivityTask?.cancel()
        connectivityTask = nil
        statsTimer?.cancel()
        statsTimer = nil
        packetBridge?.close()
        packetBridge = nil
    }

    private func withEndpointUpdateLock<T>(_ body: () -> T) -> T {
        endpointUpdateLock.lock()
        defer { endpointUpdateLock.unlock() }
        return body()
    }

    private func installEngine(_ newEngine: PsiphonTunnelEngine) {
        let previousTask = withEndpointUpdateLock { () -> Task<Void, Never>? in
            let previousTask = endpointUpdateTask
            endpointUpdateTask = nil
            pendingEndpointUpdate = nil
            endpointUpdatesActive = false
            endpointUpdateGeneration = endpointUpdateGeneration == UInt64.max
                ? 1
                : endpointUpdateGeneration + 1
            engine = newEngine
            return previousTask
        }
        previousTask?.cancel()
    }

    private func detachEngineAndStopEndpointUpdates() -> PsiphonTunnelEngine? {
        let detached = withEndpointUpdateLock {
            let detached = (engine: engine, task: endpointUpdateTask)
            engine = nil
            endpointUpdateTask = nil
            pendingEndpointUpdate = nil
            endpointUpdatesActive = false
            endpointUpdateGeneration = endpointUpdateGeneration == UInt64.max
                ? 1
                : endpointUpdateGeneration + 1
            return detached
        }
        detached.task?.cancel()
        return detached.engine
    }

    private func scheduleEndpointUpdate(
        _ endpoints: PsiphonLocalProxyEndpoints,
        for expectedEngine: PsiphonTunnelEngine
    ) {
        withEndpointUpdateLock {
            guard engine === expectedEngine else { return }
            pendingEndpointUpdate = endpoints
            guard endpointUpdatesActive, endpointUpdateTask == nil else { return }
            let generation = endpointUpdateGeneration
            endpointUpdateTask = Task { [weak self, weak expectedEngine] in
                guard let expectedEngine else { return }
                await self?.drainEndpointUpdates(for: expectedEngine, generation: generation)
            }
        }
    }

    private func activateEndpointUpdates(for expectedEngine: PsiphonTunnelEngine) {
        withEndpointUpdateLock {
            guard engine === expectedEngine else { return }
            endpointUpdatesActive = true
            guard pendingEndpointUpdate != nil, endpointUpdateTask == nil else { return }
            let generation = endpointUpdateGeneration
            endpointUpdateTask = Task { [weak self, weak expectedEngine] in
                guard let expectedEngine else { return }
                await self?.drainEndpointUpdates(for: expectedEngine, generation: generation)
            }
        }
    }

    private func drainEndpointUpdates(
        for expectedEngine: PsiphonTunnelEngine,
        generation updateGeneration: UInt64
    ) async {
        while !Task.isCancelled {
            let snapshot = withEndpointUpdateLock {
                () -> (isCurrent: Bool, endpoints: PsiphonLocalProxyEndpoints?) in
                guard endpointUpdateGeneration == updateGeneration,
                      endpointUpdatesActive,
                      engine === expectedEngine else {
                    if endpointUpdateGeneration == updateGeneration {
                        endpointUpdateTask = nil
                    }
                    return (false, nil)
                }
                let endpoints = pendingEndpointUpdate
                pendingEndpointUpdate = nil
                return (true, endpoints)
            }
            guard snapshot.isCurrent else { return }

            guard let endpoints = snapshot.endpoints else {
                withEndpointUpdateLock {
                    if endpointUpdateGeneration == updateGeneration {
                        endpointUpdateTask = nil
                    }
                }
                return
            }

            await reapplyEndpointSettings(
                endpoints,
                for: expectedEngine,
                generation: updateGeneration
            )
        }

        withEndpointUpdateLock {
            if endpointUpdateGeneration == updateGeneration {
                endpointUpdateTask = nil
            }
        }
    }

    private func reapplyEndpointSettings(
        _ endpoints: PsiphonLocalProxyEndpoints,
        for expectedEngine: PsiphonTunnelEngine,
        generation updateGeneration: UInt64
    ) async {
        guard !Task.isCancelled, isCurrentEndpointUpdate(expectedEngine, generation: updateGeneration) else {
            return
        }

        let settings = SharedSettingsStore.shared.appSettings
        let proxyOnly = settings.proxyOnlyModeEnabled
        let upstream = LANProxyBridge.Endpoints(
            psiphonHost: endpoints.host,
            psiphonHttpPort: endpoints.httpPort,
            psiphonSocksPort: endpoints.socksPort
        )
        // Native packet forwarding remains attached to the Psiphon packet transport. Only
        // extension-local SOCKS/HTTP consumers need their upstream snapshot refreshed.
        lanProxy.updateUpstream(upstream)
        startConnectivityProbe(endpoints: endpoints)

        SharedLogger.shared.logRaw(
            "PSIPHON_ENDPOINT_REAPPLY",
            detail: "socks=\(endpoints.socksPort) http=\(endpoints.httpPort) proxy_only=\(proxyOnly)"
        )

        guard !Task.isCancelled, isCurrentEndpointUpdate(expectedEngine, generation: updateGeneration) else {
            return
        }
        if proxyOnly || settings.shareProxyOnLocalNetworkEnabled {
            if !lanProxy.isRunning {
                await startProxyBridge(using: endpoints, proxyOnly: proxyOnly)
            }
        }
    }

    private func isCurrentEndpointUpdate(
        _ expectedEngine: PsiphonTunnelEngine,
        generation updateGeneration: UInt64
    ) -> Bool {
        withEndpointUpdateLock {
            endpointUpdateGeneration == updateGeneration
                && endpointUpdatesActive
                && engine === expectedEngine
        }
    }

    private func cleanup() async {
        stopPacketForwarding()
        if let engine = detachEngineAndStopEndpointUpdates() {
            await engine.stopWithTimeout(seconds: 10)
        }
        TunnelStatisticsStore.markDisconnected()
    }

    private func psiphonDataDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConstants.suiteName
        ) else {
            throw NSError(domain: "AzadiTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "App Group container missing"])
        }
        let dir = container.appendingPathComponent(psiphonDataDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - LAN proxy bridge

    /// Sent from the main app via `NETunnelProviderSession.sendProviderMessage`.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let cmd = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        switch cmd {
        case "lan-proxy:start", "lan-proxy:restart", "proxy-bridge:restart":
            Task { [weak self] in
                guard let self else { completionHandler?(nil); return }
                if let endpoints = self.engine?.localProxyEndpoints, endpoints.hasSocks {
                    let proxyOnly = SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled
                    await self.startProxyBridge(using: endpoints, proxyOnly: proxyOnly)
                } else {
                    SharedSettingsStore.shared.lanProxyRuntimeStatus = .vpnDisconnected
                }
                completionHandler?(SharedSettingsStore.shared.lanProxyRuntimeStatus.rawValue.data(using: .utf8))
            }
        case "lan-proxy:stop":
            if SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
                Task { [weak self] in
                    guard let self else { completionHandler?(nil); return }
                    if let endpoints = self.engine?.localProxyEndpoints, endpoints.hasSocks {
                        await self.startProxyBridge(using: endpoints, proxyOnly: true)
                    }
                    completionHandler?(SharedSettingsStore.shared.lanProxyRuntimeStatus.rawValue.data(using: .utf8))
                }
            } else {
                stopLANProxy(reason: .userToggle)
                completionHandler?(LANProxyRuntimeStatus.stopped.rawValue.data(using: .utf8))
            }
        case "lan-proxy:status":
            completionHandler?(SharedSettingsStore.shared.lanProxyRuntimeStatus.rawValue.data(using: .utf8))
        case "proxy-only:socks-self-test":
            Task {
                let port = SharedSettingsStore.shared.appSettings.lanSocksProxyPort
                let result = await ProxyOnlySocksSelfTest.probe(host: "127.0.0.1", port: port)
                SharedLogger.shared.log(.proxyOnlySocksSelfTestExtension, detail: result.logDetail)
                if result.handshakeOK {
                    SharedLogger.shared.log(.proxyOnlySocksHandshakeOk, detail: "source=extension_self_test")
                } else {
                    SharedLogger.shared.log(.proxyOnlySocksHandshakeFailed, detail: "source=extension_self_test \(result.logDetail)")
                }
                completionHandler?(result.logDetail.data(using: .utf8))
            }
        case "proxy-only:fetch-public-ip":
            Task { [weak self] in
                guard let self, let endpoints = self.engine?.localProxyEndpoints else {
                    completionHandler?(nil)
                    return
                }
                let ip = await ProxyOnlyPublicIPService.fetch(endpoints: endpoints)
                if !ip.isEmpty {
                    TunnelStatisticsStore.setPublicIP(ip)
                }
                completionHandler?(ip.data(using: .utf8))
            }
        case "secure-dns:test":
            Task { [weak self] in
                guard let self, let endpoints = self.engine?.localProxyEndpoints else {
                    completionHandler?("vpn_not_ready".data(using: .utf8))
                    return
                }
                let result = await TunnelDnsForwarder.runTest(
                    socksHost: endpoints.host,
                    socksPort: endpoints.socksPort,
                    httpPort: endpoints.httpPort
                )
                let text = result.ok ? "ok:\(result.detail)" : "fail:\(result.detail)"
                completionHandler?(text.data(using: .utf8))
            }
        default:
            completionHandler?(nil)
        }
    }

    private enum LANProxyStopReason {
        case vpnDisconnected
        case userToggle
    }

    /// Starts the HTTP/SOCKS bridge to Psiphon loopback ports.
    /// - Proxy Only: always starts (127.0.0.1, or Wi-Fi when LAN share is on).
    /// - Full VPN: only when Share Proxy on Local Network is enabled.
    private func startProxyBridge(using endpoints: PsiphonLocalProxyEndpoints, proxyOnly: Bool) async {
        let settings = SharedSettingsStore.shared.appSettings
        guard proxyOnly || settings.shareProxyOnLocalNetworkEnabled else { return }

        let bindHost = resolveProxyBindHost(proxyOnly: proxyOnly, shareLAN: settings.shareProxyOnLocalNetworkEnabled)
        guard let bindHost else {
            if proxyOnly {
                SharedSettingsStore.shared.lanProxyRuntimeStatus = .noWifiIP
                SharedLogger.shared.log(.proxyOnlyBlockedNoWifi, detail: "source=extension_bridge")
            } else {
                SharedSettingsStore.shared.lanProxyRuntimeStatus = .noWifiIP
            }
            return
        }

        if proxyOnly {
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_HTTP_LISTENING",
                detail: "host=\(bindHost) port=\(settings.lanHttpProxyPort)"
            )
            SharedLogger.shared.logRaw(
                "PROXY_ONLY_SOCKS_LISTENING",
                detail: "host=\(bindHost) port=\(settings.lanSocksProxyPort)"
            )
        } else {
            SharedLogger.shared.log(.lanProxyEnabled, detail: "http=\(settings.lanHttpProxyPort) socks=\(settings.lanSocksProxyPort)")
        }

        let configuration = LANProxyBridge.Configuration(
            bindHost: bindHost,
            httpPort: settings.lanHttpProxyPort,
            socksPort: settings.lanSocksProxyPort,
            upstream: LANProxyBridge.Endpoints(
                psiphonHost: endpoints.host,
                psiphonHttpPort: endpoints.httpPort,
                psiphonSocksPort: endpoints.socksPort
            )
        )
        let outcome = await lanProxy.start(configuration: configuration)
        if proxyOnly, case .success = outcome {
            SharedLogger.shared.log(
                .proxyOnlyHttpListening,
                detail: "host=\(bindHost) port=\(settings.lanHttpProxyPort)"
            )
            SharedLogger.shared.log(
                .proxyOnlySocksListening,
                detail: "host=\(bindHost) port=\(settings.lanSocksProxyPort)"
            )
        }
        _ = outcome
    }

    /// Proxy Only: bind Wi-Fi IP only — same-device apps cannot reach extension loopback.
    private func resolveProxyBindHost(proxyOnly: Bool, shareLAN: Bool) -> String? {
        if proxyOnly {
            if let wifi = LocalNetworkAddress.wifiIPv4() {
                SharedLogger.shared.log(
                    .lanProxyWifiDetected,
                    detail: "ip=\(wifi) context=proxy_only_same_device share_lan=\(shareLAN)"
                )
                return wifi
            }
            SharedLogger.shared.log(.lanProxyWifiMissing, detail: "context=proxy_only_blocked")
            return nil
        }
        guard shareLAN else { return nil }
        if let wifi = LocalNetworkAddress.wifiIPv4() {
            SharedLogger.shared.log(.lanProxyWifiDetected, detail: "ip=\(wifi)")
            return wifi
        }
        SharedLogger.shared.log(.lanProxyWifiMissing)
        return nil
    }

    private func startLANProxy(using endpoints: PsiphonLocalProxyEndpoints) async {
        await startProxyBridge(
            using: endpoints,
            proxyOnly: SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled
        )
    }

    private func stopLANProxy(reason: LANProxyStopReason) {
        let store = SharedSettingsStore.shared
        let wasRunning = lanProxy.isRunning
        lanProxy.stop()
        switch reason {
        case .vpnDisconnected:
            if wasRunning {
                SharedLogger.shared.log(.lanProxyVpnDisconnected)
            }
            store.lanProxyRuntimeStatus = .vpnDisconnected
        case .userToggle:
            if wasRunning {
                SharedLogger.shared.log(.lanProxyDisabled)
            }
            store.lanProxyRuntimeStatus = .stopped
        }
    }

    private static func makeNetworkSettings(
        packetEngineCapabilities: PacketEngineCapabilities
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]

        // Iran / custom / domain bypass: matching destination IPs leave through the device's normal
        // interface instead of the tunnel. iOS honors excludedRoutes at the IP layer.
        let store = SharedSettingsStore.shared
        let appSettings = store.appSettings
        let bypassEnabled = appSettings.bypassIranIPsEnabled
        let (excluded, excludedBypassRoutes) = bypassEnabled
            ? Self.buildBypassExcludedRoutes()
            : (neRoutes: [NEIPv4Route](), bypassRoutes: [BypassRoute]())
        let mtu = MessagingAppsConfiguration.tunnelMTU(for: appSettings)
        if !excluded.isEmpty {
            ipv4.excludedRoutes = excluded
        }
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: mtu)
        let routePlan = PacketEngineRoutePlan.fullTunnel(for: packetEngineCapabilities)
        SharedLogger.shared.logRaw(
            "TUNNEL_MTU",
            detail: "mtu=\(mtu) messaging_compat=\(appSettings.messagingAppsCompatibilityModeEnabled)"
        )

        if routePlan.installsIPv6CaptureRoute {
            let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
            let route = routePlan.installsIPv6DefaultRoute
                ? NEIPv6Route.default()
                : NEIPv6Route(destinationAddress: "::", networkPrefixLength: NSNumber(value: 0))
            ipv6.includedRoutes = [route]
            settings.ipv6Settings = ipv6
            if routePlan.installsIPv6DefaultRoute {
                SharedLogger.shared.logRaw(
                    "TUNNEL_IPV6_ROUTE",
                    detail: "enabled=true policy=engine_relay capability=\(packetEngineCapabilities.logValue)"
                )
            } else {
                SharedLogger.shared.logRaw(
                    "TUNNEL_IPV6_CAPTURE_REJECT",
                    detail: "enabled=true policy=icmpv6_unreachable aaaa_suppressed=true capability=\(packetEngineCapabilities.logValue)"
                )
            }
        } else {
            // A packet engine may opt out of capture only if its Network Extension integration
            // provides an equivalent global IPv6 firewall. The current plan always captures so
            // literal IPv6 cannot bypass the tunnel.
            SharedLogger.shared.logRaw(
                "TUNNEL_IPV6_UNAVAILABLE",
                detail: "enabled=false policy=engine_declined_capture capability=\(packetEngineCapabilities.logValue)"
            )
        }

        // IPv4 UDP/53 is intercepted by TunnelDnsForwarder when Secure DNS is
        // active; Psiphon's native packet transport handles the core DNS path.
        let tunnelSettings = store.tunnelEffectiveAppSettings
        let dnsServers = SecureDNSConfiguration.advertisedDnsServers(for: tunnelSettings)
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        if SecureDNSConfiguration.isActive(tunnelSettings) {
            SharedLogger.shared.logRaw(
                "TUNNEL_DNS_ADVERTISED",
                detail: "servers=\(dnsServers.joined(separator: ",")) mode=\(tunnelSettings.secureDNSMode.rawValue) provider=\(tunnelSettings.secureDNSProvider.rawValue) messaging_compat=\(appSettings.messagingAppsCompatibilityModeEnabled)"
            )
        }
        MessagingAppsDiagnostics.logCompatibilityStartup(
            settings: appSettings,
            excludedRoutes: excludedBypassRoutes,
            mtu: mtu,
            packetEngineCapabilities: packetEngineCapabilities
        )
        MessagingAppsDiagnostics.runDomainChecks(excludedRoutes: excludedBypassRoutes)

        // Full packet mode intentionally leaves proxySettings unset. A system
        // HTTP proxy would make HTTP-only apps appear healthy while masking a
        // broken packet path and would not cover UDP or non-HTTP traffic.
        SharedLogger.shared.logRaw(
            "TUNNEL_HTTP_PROXY",
            detail: "disabled native_packet_mode=true reason=packet_flow_is_authoritative"
        )

        return settings
    }

    /// Collect Iran (cached) + custom + resolved-domain destinations into NE excluded routes.
    ///
    /// Reads everything from App Group storage so it works even if the app was killed while the
    /// tunnel kept running. De-duplicates across all three sources and publishes the applied count.
    private static func buildBypassExcludedRoutes() -> (neRoutes: [NEIPv4Route], bypassRoutes: [BypassRoute]) {
        let store = SharedSettingsStore.shared
        let settings = store.appSettings
        let messagingCompat = MessagingAppsConfiguration.usesMessagingOverlays(settings)

        var collected: [BypassRoute] = []
        var seen = Set<BypassRoute>()
        func add(_ routes: [BypassRoute]) {
            for r in routes where seen.insert(r).inserted { collected.append(r) }
        }

        // 1) Iran CIDR list: fetched cache if present, otherwise the bundled snapshot (never empty).
        let iranLines = store.effectiveBypassIranCidrLines
        if iranLines.isEmpty {
            SharedLogger.shared.log(.bypassIranNoListWarning, detail: "reason=cache_and_bundle_empty action=connect_normally")
        } else {
            let usingBundled = store.bypassIranListIsBundledFallback
            SharedLogger.shared.log(.bypassIranListCacheUsed, detail: "count=\(iranLines.count) source=\(usingBundled ? "bundled" : "cache")")
            add(BypassRoutes.parseList(iranLines))
        }

        // 2) User custom IPs / CIDRs.
        let customRoutes = BypassRoutes.parseBlob(settings.bypassCustomRoutes)
        for r in customRoutes {
            SharedLogger.shared.log(.bypassCustomRouteAdded, detail: "value=\(r.cidr)")
        }
        add(customRoutes)

        // 3) Resolved domain IPs (as /32).
        let domainMap = store.bypassDomainResolvedIPs
        for (domain, ips) in domainMap {
            if messagingCompat, MessagingAppsConfiguration.isProtectedDomain(domain) {
                SharedLogger.shared.logRaw(
                    "MESSAGING_BYPASS_DOMAIN_SKIPPED",
                    detail: "domain=\(domain) ips=\(ips.joined(separator: ","))"
                )
                continue
            }
            add(BypassRoutes.parseList(ips))
        }

        let filtered = MessagingAppsConfiguration.filterExcludedRoutes(collected, compatibilityMode: messagingCompat)
        if !filtered.removed.isEmpty {
            SharedLogger.shared.logRaw(
                "MESSAGING_BYPASS_PROTECTED",
                detail: "removed=\(filtered.removed.count) sample=\(filtered.removed.prefix(4).map(\.cidr).joined(separator: ","))"
            )
        }

        let neRoutes = filtered.filtered.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }
        store.bypassRoutesAppliedCount = neRoutes.count
        SharedLogger.shared.log(
            .bypassIranRoutesApplied,
            detail: "count=\(neRoutes.count) iran=\(iranLines.count) custom=\(customRoutes.count) domains=\(domainMap.count) messaging_compat=\(messagingCompat)"
        )
        return (neRoutes, filtered.filtered)
    }

    /// Minimal tunnel settings for Proxy Only — extension stays alive; no routes, DNS, or system proxy.
    ///
    /// Apps must opt in manually (HTTP/SOCKS on Wi-Fi IP:8087/:1088). `NEProxySettings` with
    /// `matchDomains=[""]` would force system-wide HTTP/HTTPS through the tunnel proxy.
    private static func makeProxyOnlyNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        SharedLogger.shared.log(.proxyOnlyNoDefaultRoute, detail: "no_ipv4_routes")
        SharedLogger.shared.log(.proxyOnlyNoSystemProxy, detail: "manual_proxy_only")
        return settings
    }
}
