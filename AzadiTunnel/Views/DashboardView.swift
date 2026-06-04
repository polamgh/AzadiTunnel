import SwiftUI

struct DashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared
    @State private var configReady = SharedSettingsStore.shared.hasActivePsiphonConfig
    @State private var showDisclosure = false
    @State private var durationText = "00:00:00"
    @State private var didRunConnectBootstrap = false
    @State private var diagnosticsExpanded = false
    @State private var showCopyToast = false
    @State private var toastMessage = ""
    @State private var copyToastHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header
                    IranFlagStripe()
                        .padding(.horizontal, 8)
                    if !configReady { ConfigSetupBanner() }
                    if vpn.banner != .none { ErrorBanner(kind: vpn.banner, message: vpn.lastError) }
                    statusHero
                    ConnectPowerButton(
                        status: vpn.status,
                        isEnabled: configReady || vpn.status == .connected
                    ) {
                        if !SharedSettingsStore.shared.appSettings.hasAcceptedConnectionDisclaimer {
                            SharedLogger.shared.logRaw("CONNECT_BLOCKED_PENDING_DISCLAIMER", detail: "source=connect_button")
                            showDisclosure = true
                            return
                        }
                        Task {
                            if vpn.status == .connected || vpn.status == .connecting {
                                await vpn.disconnect()
                            } else {
                                await vpn.connect()
                            }
                        }
                    }
                    if showConduitProgress { conduitProgressCard }
                    locationCard
                    statsSection
                    if vpn.status == .connected, hasDiagnosticsContent {
                        diagnosticsCollapsibleSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }

            if showCopyToast {
                VStack {
                    Spacer()
                    AppToastBanner(message: toastMessage)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .id(lang.revision)
        .navigationBarHidden(true)
        .animation(.spring(duration: 0.3), value: showCopyToast)
        .sheet(isPresented: $showDisclosure) {
            ConnectionDisclaimerSheet(
                onAccept: {
                    var s = SharedSettingsStore.shared.appSettings
                    s.hasAcceptedConnectionDisclaimer = true
                    s.hasAcceptedVPNDisclosure = true
                    SharedSettingsStore.shared.updateAppSettings(s, logKey: "connection_disclaimer")
                    showDisclosure = false
                    Task { await vpn.connect() }
                },
                onCancel: {
                    showDisclosure = false
                }
            )
        }
        .task {
            await vpn.refreshStatusFromSystem()
            refreshConfigFlag()
            if ProcessInfo.processInfo.arguments.contains("-UITestDisconnect") {
                await vpn.disconnect()
                return
            }
            if !didRunConnectBootstrap {
                didRunConnectBootstrap = true
                if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
                    for _ in 0..<40 {
                        refreshConfigFlag()
                        if configReady { break }
                        try? await TaskSleep.milliseconds(250)
                    }
                }
                let uiTestAuto = ProcessInfo.processInfo.arguments.contains("-UITestAutoConnect")
                let autoConnect = SharedSettingsStore.shared.appSettings.connectOnLaunch || uiTestAuto
                if uiTestAuto {
                    await vpn.disconnect()
                    try? await TaskSleep.seconds(2)
                }
                if autoConnect, configReady {
                    await vpn.connect()
                }
                if ProcessInfo.processInfo.arguments.contains("-UITestVerifyFeatures") {
                    await UITestFeatureVerifier.runIfRequested()
                }
            }
            while !Task.isCancelled {
                vpn.syncStatusFromSharedStore()
                refreshConfigFlag()
                updateDuration()
                try? await TaskSleep.seconds(1)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    AppIconImage(size: 34, shadow: false)
                    Text("AzadiTunnel")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                NavigationLink {
                    SupportAzadiTunnelView()
                } label: {
                    Label(L10n.t(.supportButton), systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.iranGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(AppTheme.iranGreen.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        )
                }
                .accessibilityIdentifier("dashboardSupportButton")
            }
            .environment(\.layoutDirection, .leftToRight)
            Text(L10n.t(.appSubtitle))
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private var statusHero: some View {
        GlassCard(elevated: true) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(AppTheme.statusColor(for: vpn.status, scheme: colorScheme).opacity(0.2))
                        .frame(width: 52, height: 52)
                    Circle()
                        .fill(AppTheme.statusColor(for: vpn.status, scheme: colorScheme))
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t(.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .textCase(.uppercase)
                    Text(localizedStatusMessage)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.statusColor(for: vpn.status, scheme: colorScheme))
                        .accessibilityIdentifier("statusLabel")
                    if let protocolLabel = connectedProtocolLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption.weight(.semibold))
                            Text(protocolLabel)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.iranGreen)
                        .accessibilityIdentifier("connectedProtocolLabel")
                    }
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2.weight(.semibold))
                            Text(durationText)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .lineLimit(1)
                        }
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption2.weight(.semibold))
                            Text(pingLabel)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("durationLabel")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var pingLabel: String {
        guard vpn.status == .connected else { return "—" }
        let ms = ConnectionDiagnosticsStore.loadQuality()?.latencyMs ?? -1
        return ms >= 0 ? "\(ms) ms" : "—"
    }

    private var hasDiagnosticsContent: Bool {
        ConnectionDiagnosticsStore.loadLeak() != nil
            || ConnectionDiagnosticsStore.loadQuality() != nil
            || {
                let f = ConnectionDiagnosticsStore.loadFallback()
                return f.isActive || f.succeededStep != nil || f.exhausted
            }()
    }

    private var diagnosticsCollapsibleSection: some View {
        GlassCard {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    if let leak = ConnectionDiagnosticsStore.loadLeak() {
                        diagnosticsSubsection(title: L10n.t(.leakTestTitle)) {
                            diagnosticsRow(L10n.t(.leakTestStatus), leak.verdict.rawValue)
                            CopyableIPRow(
                                label: L10n.t(.publicIP),
                                value: leak.publicIPAfter.isEmpty ? "—" : leak.publicIPAfter,
                                onCopied: notifyCopiedToClipboard
                            )
                            diagnosticsRow(L10n.t(.leakTestDNS), leak.dnsSummary)
                            if !leak.ipv6Summary.isEmpty {
                                diagnosticsRow(L10n.t(.leakTestIPv6), leak.ipv6Summary)
                            }
                        }
                    }
                    if let quality = ConnectionDiagnosticsStore.loadQuality() {
                        diagnosticsSubsection(title: L10n.t(.qualityReportTitle)) {
                            diagnosticsRow(
                                L10n.t(.connectedProtocol),
                                ConnectedTunnelProtocolParser.displayName(for: quality.connectedProtocol)
                            )
                            CopyableIPRow(
                                label: L10n.t(.publicIP),
                                value: quality.publicIP.isEmpty ? "—" : quality.publicIP,
                                onCopied: notifyCopiedToClipboard
                            )
                            diagnosticsRow(
                                L10n.t(.region),
                                quality.countryRegion.isEmpty ? "—" : quality.countryRegion
                            )
                            diagnosticsRow(
                                L10n.t(.qualityLatency),
                                quality.latencyMs >= 0 ? "\(quality.latencyMs) ms" : "—"
                            )
                            diagnosticsRow(
                                L10n.t(.qualityHTTPS204),
                                quality.https204Passed ? L10n.t(.testPass) : L10n.t(.testFail)
                            )
                            diagnosticsRow(L10n.t(.qualityTransport), quality.transportMode)
                            if !quality.cdnEdgeIP.isEmpty {
                                CopyableIPRow(
                                    label: L10n.t(.qualityCDNEdge),
                                    value: quality.cdnEdgeIP,
                                    onCopied: notifyCopiedToClipboard
                                )
                            }
                            if !quality.cdnSNI.isEmpty {
                                diagnosticsRow(L10n.t(.qualityCDNSNI), quality.cdnSNI)
                            }
                        }
                    }
                    let fallback = ConnectionDiagnosticsStore.loadFallback()
                    if fallback.isActive || fallback.succeededStep != nil || fallback.exhausted {
                        diagnosticsSubsection(title: L10n.t(.fallbackTitle)) {
                            diagnosticsRow(
                                L10n.t(.fallbackCurrent),
                                fallback.currentStep?.rawValue ?? "—"
                            )
                            diagnosticsRow(
                                L10n.t(.fallbackLastFailed),
                                fallback.lastFailedStep?.rawValue ?? "—"
                            )
                            if let reason = fallback.lastFailureReason.nilIfEmpty {
                                diagnosticsRow(L10n.t(.fallbackReason), reason)
                            }
                            diagnosticsRow(
                                L10n.t(.fallbackSuccess),
                                fallback.succeededProtocol.isEmpty
                                    ? (fallback.succeededStep?.rawValue ?? "—")
                                    : "\(fallback.succeededStep?.rawValue ?? "") / \(fallback.succeededProtocol)"
                            )
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(L10n.t(.diagnosticsSection))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            }
            .tint(AppTheme.iranGreen)
        }
    }

    private func diagnosticsSubsection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.iranGreen)
            content()
        }
    }

    private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func notifyCopiedToClipboard() {
        copyToastHideTask?.cancel()
        toastMessage = L10n.t(.copiedToClipboard)
        showCopyToast = true
        copyToastHideTask = Task {
            try? await TaskSleep.seconds(1.6)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showCopyToast = false
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t(.traffic))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(
                    title: L10n.t(.download),
                    value: ByteCountFormatter.formatSpeed(vpn.statistics.downloadSpeedBps),
                    icon: "arrow.down.circle.fill",
                    tint: AppTheme.iranGreen,
                    id: "downloadSpeedLabel"
                )
                StatTile(
                    title: L10n.t(.upload),
                    value: ByteCountFormatter.formatSpeed(vpn.statistics.uploadSpeedBps),
                    icon: "arrow.up.circle.fill",
                    tint: AppTheme.iranRed,
                    id: "uploadSpeedLabel"
                )
                StatTile(
                    title: L10n.t(.totalDownload),
                    value: ByteCountFormatter.formatTotal(vpn.statistics.bytesDown),
                    icon: "internaldrive.fill",
                    tint: AppTheme.iranGreenBright,
                    id: "totalDownloadLabel"
                )
                StatTile(
                    title: L10n.t(.totalUpload),
                    value: ByteCountFormatter.formatTotal(vpn.statistics.bytesUp),
                    icon: "icloud.and.arrow.up.fill",
                    tint: AppTheme.iranRedDeep,
                    id: "totalUploadLabel"
                )
            }

            Text(L10n.t(.trafficFootnote))
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .padding(.horizontal, 4)
        }
    }

    private var locationCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "globe.americas.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.iranGreen)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t(.region))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        Menu {
                            Button(L10n.t(.regionAny)) { updateEgressRegion("") }
                            ForEach(PsiphonRegionList.all, id: \.self) { code in
                                Button(code) { updateEgressRegion(code) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(regionTitle)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.iranGreen)
                            }
                        }
                        .accessibilityIdentifier("dashboardRegionMenu")
                        if let subtitle = regionSubtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.iranGreen)
                        }
                    }
                    Divider().overlay(AppTheme.cardStroke(for: colorScheme))
                    HStack {
                        Text(L10n.t(.publicIP))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        Spacer()
                        Text(publicIPLabel)
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                            .foregroundStyle(AppTheme.primaryText(for: colorScheme).opacity(0.9))
                            .accessibilityIdentifier("publicIPLabel")
                    }
                }
            }
        }
    }

    private var showConduitProgress: Bool {
        guard SharedSettingsStore.shared.appSettings.protocolSelection == .conduit else { return false }
        guard vpn.status == .connecting || vpn.status == .connected else { return false }
        return !vpn.statistics.conduitStatusLine.isEmpty || !vpn.statistics.conduitStatusHistory.isEmpty
    }

    private var conduitProgressCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.iranGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t(.conduitProgress))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        Text(L10n.t(.conduitProgressHint))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    }
                }
                Text(vpn.statistics.conduitStatusLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.iranGreen)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("conduitStatusLine")
                if !vpn.statistics.conduitStatusHistory.isEmpty {
                    Divider().overlay(AppTheme.cardStroke(for: colorScheme))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(vpn.statistics.conduitStatusHistory.prefix(4).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("·")
                                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityIdentifier("conduitStatusHistory")
                }
            }
        }
    }

    private var localizedStatusMessage: String {
        if showConduitProgress, vpn.status == .connecting,
           !vpn.statistics.conduitStatusLine.isEmpty {
            return vpn.statistics.conduitStatusLine
        }
        switch vpn.status {
        case .connected: return L10n.t(.connected)
        case .connecting: return L10n.t(.connecting)
        case .disconnecting: return L10n.t(.disconnecting)
        case .disconnected: return L10n.t(.disconnected)
        case .error: return vpn.statusMessage == "Setup required" ? L10n.t(.setupRequired) : L10n.t(.failed)
        }
    }

    private var regionTitle: String {
        let r = SharedSettingsStore.shared.appSettings.egressRegion
        return r.isEmpty ? L10n.t(.regionAny) : r
    }

    private var regionSubtitle: String? {
        guard vpn.status == .connected else { return nil }
        let loc = vpn.statistics.egressLocationSubtitle
        return loc.isEmpty ? nil : loc
    }

    private var publicIPLabel: String {
        let ip = vpn.statistics.lastPublicIP
        return ip.isEmpty ? "—" : ip
    }

    private var connectedProtocolLabel: String? {
        guard vpn.status == .connected else { return nil }
        let display = ConnectedTunnelProtocolParser.displayName(
            for: vpn.statistics.connectedTunnelProtocol
        )
        guard !display.isEmpty else { return nil }
        return "\(L10n.t(.connectedProtocol)): \(display)"
    }

    private func refreshConfigFlag() {
        configReady = SharedSettingsStore.shared.hasActivePsiphonConfig
    }

    private func updateDuration() {
        guard vpn.status == .connected else {
            durationText = "00:00:00"
            return
        }
        durationText = ByteCountFormatter.formatDuration(vpn.statistics.sessionDuration)
    }

    private func updateEgressRegion(_ code: String) {
        var settings = SharedSettingsStore.shared.appSettings
        settings.egressRegion = code
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: "dashboard_egress_region")
    }
}

private struct StatTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let id: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .accessibilityIdentifier(id)
            }
        }
    }
}

private struct ConfigSetupBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassCard {
            Label {
                Text(L10n.t(.configSetupBanner))
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.iranRed)
            }
        }
        .accessibilityIdentifier("config_setup_banner")
    }
}

private struct ErrorBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let kind: VPNBannerKind
    let message: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.danger)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme).opacity(0.85))
                }
            }
        }
        .accessibilityIdentifier("error_banner")
    }

    private var title: String {
        switch kind {
        case .noConfig: return L10n.t(.errorNoConfig)
        case .conduitBlocked: return L10n.t(.errorConduitBlocked)
        case .vpnPermission: return L10n.t(.errorVPNPermission)
        case .psiphonFailed: return L10n.t(.errorPsiphonFailed)
        case .internetTestFailed: return L10n.t(.errorInternetTest)
        case .none: return ""
        }
    }

    private var subtitle: String {
        switch kind {
        case .noConfig: return L10n.t(.errorNoConfigSub)
        case .conduitBlocked: return L10n.t(.errorConduitBlockedSub)
        case .vpnPermission: return L10n.t(.errorVPNPermissionSub)
        case .psiphonFailed: return L10n.t(.errorPsiphonFailedSub)
        case .internetTestFailed: return L10n.t(.errorInternetTestSub)
        case .none: return ""
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
