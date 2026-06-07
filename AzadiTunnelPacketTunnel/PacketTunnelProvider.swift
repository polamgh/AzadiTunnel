import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: PsiphonTunnelEngine?
    private var forwarder: PacketTunnelTrafficForwarder?
    private var statsTimer: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private let psiphonDataDirName = "psiphon-data"
    private let lanProxy = LANProxyBridge()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        SharedLogger.shared.log(.extensionBoot)
        PsiphonInproxyBuildInfo.logFrameworkProbe()
        SharedLogger.shared.log(.extensionStartEntered)

        SharedSettingsStore.shared.migrateServerEntriesFromDefaultsIfNeeded()

        guard SharedSettingsStore.shared.extensionCanReadSettings() else {
            SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=app_group_unavailable")
            completionHandler(NSError(domain: "AzadiTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group unavailable"]))
            return
        }
        SharedLogger.shared.log(.extensionSettingsLoaded)

        guard let configJSON = SharedSettingsStore.shared.psiphonConfigJSON else {
            SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=no_config")
            completionHandler(NSError(domain: "AzadiTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Psiphon configuration not installed"]))
            return
        }

        if SharedSettingsStore.shared.appSettings.protocolSelection == .conduit,
           !SharedSettingsStore.shared.conduitConnectAllowed {
            let readiness = SharedSettingsStore.shared.conduitDistributorReadiness
            SharedLogger.shared.logRaw("CONDUIT_BLOCKED", detail: "missing_distributor_keys \(readiness.logDetail)")
            TunnelStatisticsStore.seedConduitConnecting(missingDistributorKeys: true)
            completionHandler(NSError(
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
        TunnelStatisticsStore.resetSession()
        SharedSettingsStore.shared.lastInternetTestOK = false
        SharedSettingsStore.shared.psiphonTunnelEstablished = false

        Task {
            do {
                SharedLogger.shared.log(.psiphonCoreSelected, detail: "impl=PsiphonTunnel")
                let dataDir = try self.psiphonDataDirectory()
                let psiphonEngine = PsiphonTunnelEngine(core: ExtensionPsiphonCore.make())
                self.engine = psiphonEngine
                let entriesPath = SharedSettingsStore.shared.psiphonServerEntriesPath
                try await psiphonEngine.start(
                    configJSON: configJSON,
                    serverEntriesPath: entriesPath,
                    dataDir: dataDir
                )

                let endpoints = psiphonEngine.localProxyEndpoints
                guard endpoints.hasSocks else {
                    throw PsiphonTunnelCoreError.proxyNotReady
                }

                let settings = Self.makeNetworkSettings(endpoints: endpoints)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.setTunnelNetworkSettings(settings) { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
                }

                SharedLogger.shared.log(.packetForwardingStartRequested)
                let forwarder = PacketTunnelTrafficForwarder(
                    packetFlow: self.packetFlow,
                    socksHost: endpoints.host,
                    socksPort: endpoints.socksPort,
                    httpPort: endpoints.httpPort,
                    proxyType: endpoints.hasHttp ? .dual : .socks
                )
                try forwarder.start()
                self.forwarder = forwarder
                SharedLogger.shared.log(.packetForwardingStarted)
#if canImport(tun2socks)
                TunnelStackProbe.runAfterForwardingStarted()
#endif

                TunnelStatisticsStore.markConnected(region: region.isEmpty ? "Any" : region)
                self.startStatsSampler()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.startConnectivityProbe(endpoints: endpoints)

                SharedSettingsStore.shared.vpnStatus = .connected
                SharedLogger.shared.log(.tunnelConnected)

                let appSettings = SharedSettingsStore.shared.appSettings
                if appSettings.shareProxyOnLocalNetworkEnabled {
                    SharedLogger.shared.log(.lanProxyVpnReconnected)
                    await self.startLANProxy(using: endpoints)
                }

                completionHandler(nil)
            } catch {
                SharedLogger.shared.log(.psiphonConnectFailed, detail: "reason=\(error.localizedDescription)")
                SharedLogger.shared.log(.tunnelStartFailed, detail: "reason=\(error.localizedDescription)")
                await self.cleanup()
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SharedLogger.shared.log(.extensionStopEntered, detail: "reason=\(reason.rawValue)")
        stopLANProxy(reason: .vpnDisconnected)
        stopPacketForwarding()
        TunnelStatisticsStore.markDisconnected()
        SharedSettingsStore.shared.vpnStatus = .disconnected
        SharedLogger.shared.log(.tunnelStopCleanup)
        completionHandler()

        let engineToStop = engine
        engine = nil
        guard let engineToStop else { return }
        Task {
            await engineToStop.stopWithTimeout(seconds: 10)
            SharedLogger.shared.log(.psiphonStopped)
        }
    }

    private func startConnectivityProbe(endpoints: PsiphonLocalProxyEndpoints) {
        connectivityTask?.cancel()
        connectivityTask = Task {
            _ = await TunnelConnectivityProbe.verifyGenerate204(endpoints: endpoints)
        }
    }

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
        forwarder?.stop()
        forwarder = nil
    }

    private func cleanup() async {
        stopPacketForwarding()
        if let engine {
            await engine.stopWithTimeout(seconds: 10)
        }
        engine = nil
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
        case "lan-proxy:start", "lan-proxy:restart":
            Task { [weak self] in
                guard let self else { completionHandler?(nil); return }
                if let endpoints = self.engine?.localProxyEndpoints, endpoints.hasSocks {
                    await self.startLANProxy(using: endpoints)
                } else {
                    SharedSettingsStore.shared.lanProxyRuntimeStatus = .vpnDisconnected
                }
                completionHandler?(SharedSettingsStore.shared.lanProxyRuntimeStatus.rawValue.data(using: .utf8))
            }
        case "lan-proxy:stop":
            stopLANProxy(reason: .userToggle)
            completionHandler?(LANProxyRuntimeStatus.stopped.rawValue.data(using: .utf8))
        case "lan-proxy:status":
            completionHandler?(SharedSettingsStore.shared.lanProxyRuntimeStatus.rawValue.data(using: .utf8))
        default:
            completionHandler?(nil)
        }
    }

    private enum LANProxyStopReason {
        case vpnDisconnected
        case userToggle
    }

    private func startLANProxy(using endpoints: PsiphonLocalProxyEndpoints) async {
        let settings = SharedSettingsStore.shared.appSettings
        guard settings.shareProxyOnLocalNetworkEnabled else { return }

        guard endpoints.hasSocks else {
            SharedSettingsStore.shared.lanProxyRuntimeStatus = .vpnDisconnected
            return
        }

        // Prefer Wi-Fi address (en0); fall back to 0.0.0.0 so binding still succeeds when
        // the device is on Wi-Fi via shared connection / personal hotspot client.
        let bindHost: String
        if let wifi = LocalNetworkAddress.wifiIPv4() {
            SharedLogger.shared.log(.lanProxyWifiDetected, detail: "ip=\(wifi)")
            bindHost = wifi
        } else {
            SharedLogger.shared.log(.lanProxyWifiMissing)
            SharedSettingsStore.shared.lanProxyRuntimeStatus = .noWifiIP
            return
        }

        SharedLogger.shared.log(.lanProxyEnabled, detail: "http=\(settings.lanHttpProxyPort) socks=\(settings.lanSocksProxyPort)")

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
        _ = await lanProxy.start(configuration: configuration)
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
        endpoints: PsiphonLocalProxyEndpoints
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: 1500)

        // Virtual DNS on the tunnel; UDP/53 is answered in TunnelDnsForwarder.
        let dns = NEDNSSettings(servers: ["10.0.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        // iOS routes Safari/NSURLSession HTTP(S) through the local Psiphon HTTP proxy (bypasses tun2socks).
        if endpoints.hasHttp {
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            proxy.excludeSimpleHostnames = false
            proxy.matchDomains = [""]
            let server = NEProxyServer(address: endpoints.host, port: endpoints.httpPort)
            proxy.httpServer = server
            proxy.httpsServer = server
            settings.proxySettings = proxy
            SharedLogger.shared.logRaw(
                "TUNNEL_HTTP_PROXY",
                detail: "enabled host=\(endpoints.host) port=\(endpoints.httpPort)"
            )
        }

        return settings
    }
}
