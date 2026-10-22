import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared
    @State private var configReady = SharedSettingsStore.shared.hasActivePsiphonConfig
    @State private var showDisclosure = false
    @State private var durationText = "00:00:00"
    @State private var didRunConnectBootstrap = false
    @State private var sheetExpanded = false
    @State private var collapsedSheetHeight: CGFloat = 360
    @State private var sheetContentHeight: CGFloat = 340
    @State private var showCopyToast = false
    @State private var toastMessage = ""
    @State private var copyToastHideTask: Task<Void, Never>?
    @State private var displayedPingMs: Int = -1
    @State private var pingRefreshing = false
    @State private var pingRefreshInFlight = false
    @State private var showRegionPicker = false
    @State private var selectedProtocol = SharedSettingsStore.shared.appSettings.protocolSelection
    @State private var connectingStartedAt: TimeInterval?
    @State private var showSlowConnectionHelp = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 640
            ZStack(alignment: .bottom) {
                mapSurface
                    .ignoresSafeArea()

                VPNWorldMapBackground(
                    originCoordinate: originMapCoordinate,
                    destinationCoordinate: egressMapCoordinate,
                    originCountryCode: originCountryCode,
                    destinationCountryCode: destinationCountryCode,
                    isConnected: isMapConnectionVisible,
                    isConnecting: vpn.status == .connecting
                )
                .frame(height: max(120, proxy.size.height - collapsedSheetHeight - DashboardLayout.headerHeight - 12))
                .padding(.top, DashboardLayout.headerHeight)
                .frame(maxHeight: .infinity, alignment: .top)

                VStack(spacing: 10) {
                    header
                    routeCaption
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                if sheetExpanded {
                    Color.black
                        .opacity(colorScheme == .dark ? 0.4 : 0.14)
                        .ignoresSafeArea()
                        .onTapGesture { setSheetExpanded(false) }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }

                controlSheet(maxHeight: proxy.size.height - 24, powerSize: compact ? 104 : 124)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

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
            .onPreferenceChange(CollapsedSheetHeightKey.self) { height in
                if height > 0 { collapsedSheetHeight = height }
            }
        }
        .id(lang.revision)
        .navigationBarHidden(true)
        .animation(.spring(duration: 0.3), value: showCopyToast)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: sheetExpanded)
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
        .sheet(isPresented: $showRegionPicker) {
            RegionPickerSheet(
                selectedCode: SharedSettingsStore.shared.appSettings.egressRegion,
                onSelect: updateEgressRegion
            )
        }
        .alert(L10n.t(.proxyOnlyRequiresWifiTitle), isPresented: $vpn.showProxyOnlyNoWiFiPrompt) {
            Button(L10n.t(.proxyOnlyTurnOffMode)) {
                Task { await vpn.disableProxyOnlyModeAndConnect() }
            }
            Button(L10n.t(.cancel), role: .cancel) {
                vpn.cancelProxyOnlyNoWiFiConnect()
            }
        } message: {
            Text(L10n.t(.proxyOnlyRequiresWifiMessage))
        }
        .task {
            await vpn.refreshStatusFromSystem()
            refreshConfigFlag()
            if vpn.status == .disconnected,
               !ProcessInfo.processInfo.arguments.contains("-UITestMode") {
                Task {
                    await OriginGeoLookup.shared.captureBeforeConnect()
                    vpn.refreshStatistics()
                }
            }
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
                if ProcessInfo.processInfo.arguments.contains("-UITestRunPostConnect") {
                    try? await TaskSleep.seconds(8)
                    await vpn.runPostConnectDiagnostics()
                }
                if ProcessInfo.processInfo.arguments.contains("-UITestVerifyFeatures") {
                    // SwiftUI may cancel this view task while the VPN status redraws the
                    // dashboard. Keep the device verifier independent so URLSession requests
                    // measure the tunnel instead of inheriting a cancelled parent task.
                    await Task.detached(priority: .userInitiated) {
                        await UITestFeatureVerifier.runIfRequested()
                    }.value
                }
            }
            while !Task.isCancelled {
                vpn.syncStatusFromSharedStore()
                refreshConfigFlag()
                refreshProtocolSelection()
                updateDuration()
                updateSlowConnectionHelp()
                try? await TaskSleep.seconds(1)
            }
        }
        .task(id: vpn.status) {
            await runPingRefreshLoop()
        }
    }

    // MARK: - Map hero

    private var statusTint: Color {
        AppTheme.statusColor(for: vpn.status, scheme: colorScheme)
    }

    private var mapSurface: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.03, green: 0.05, blue: 0.09), Color(red: 0.05, green: 0.08, blue: 0.14)]
                    : [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.97, green: 0.98, blue: 0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [statusTint.opacity(colorScheme == .dark ? 0.22 : 0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.32),
                startRadius: 10,
                endRadius: 360
            )
            .animation(.easeInOut(duration: 0.6), value: vpn.status)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconImage(size: 32, shadow: false)
            wordmark
            Spacer(minLength: 8)
            NavigationLink {
                SupportAzadiTunnelView()
            } label: {
                Label(L10n.t(.supportButton), systemImage: "heart.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.iranGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(AppTheme.iranGreen.opacity(0.25), lineWidth: 1))
            }
            .accessibilityIdentifier("dashboardSupportButton")
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .frame(height: 44)
    }

    /// Script wordmark in a single ink color: white on dark, near-black on light.
    private var wordmark: some View {
        Text("AzadiTunnel")
            .font(.custom(AppFonts.wordmark, size: 32, relativeTo: .title))
            .foregroundColor(AppTheme.primaryText(for: colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, 2)
            .background(alignment: .topLeading) {
                GeometryReader { geometry in
                    PeekingLion(trackWidth: geometry.size.width)
                        .offset(y: -PeekingLion.windowHeight + PeekingLion.hideLine)
                }
            }
            .accessibilityLabel(Text("AzadiTunnel"))
            .accessibilityAddTraits(.isHeader)
    }

    /// Where traffic exits: origin → egress while connected, otherwise the exposed origin IP.
    private var routeCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: isProtected ? "lock.shield.fill" : "shield.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isProtected ? AppTheme.success : AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
            if isProtected {
                // Connected: the map labels already show both flags, so the caption stays text-only.
                Text(regionSubtitle ?? L10n.t(.dashboardProtected))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
            } else {
                if let origin = VPNWorldMapBackground.flagEmoji(for: originCountryCode) {
                    Text(origin).accessibilityHidden(true)
                }
                Text(L10n.t(.dashboardUnprotected))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
            }
            Rectangle()
                .fill(AppTheme.secondaryText(for: colorScheme).opacity(0.35))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
            Text(publicIPLabel)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(Text(L10n.t(.publicIP)))
                .accessibilityValue(Text(publicIPLabel))
                .accessibilityIdentifier("publicIPLabel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(AppTheme.cardStroke(for: colorScheme), lineWidth: 1))
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.3), value: isProtected)
    }

    private var isProtected: Bool {
        vpn.status == .connected
    }

    // MARK: - Control sheet

    private func controlSheet(maxHeight: CGFloat, powerSize: CGFloat) -> some View {
        // One persistent stack: the primary controls never re-mount, the details slide in
        // underneath, and the scroll area is exactly as tall as its content (up to the cap).
        VStack(spacing: 0) {
            sheetGrabber
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    primaryControls(powerSize: powerSize)
                    if sheetExpanded {
                        detailsContent
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: SheetContentHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            .frame(height: min(sheetContentHeight, maxHeight - DashboardLayout.grabberHeight))
            .onPreferenceChange(SheetContentHeightKey.self) { height in
                if height > 0 { sheetContentHeight = height }
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CollapsedSheetHeightKey.self,
                    value: sheetExpanded ? 0 : geometry.size.height
                )
            }
        )
        .overlay(alignment: .top) { flagBand }
        .modifier(DashboardGlassSurface(cornerRadius: DashboardLayout.sheetCornerRadius))
        // While collapsed the whole sheet answers a swipe up; once expanded only the
        // grabber does, so the details ScrollView keeps its own vertical scrolling.
        .simultaneousGesture(sheetDragGesture, including: sheetExpanded ? .subviews : .all)
    }

    private var sheetGrabber: some View {
        Capsule()
            .fill(AppTheme.secondaryText(for: colorScheme).opacity(0.35))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: DashboardLayout.grabberHeight)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .gesture(sheetDragGesture)
            .onTapGesture { setSheetExpanded(!sheetExpanded) }
            .accessibilityHidden(true)
    }

    /// Edge-to-edge Iran flag ribbon along the top of the sheet; the sheet's
    /// rounded clip bends it around the corners.
    private var flagBand: some View {
        HStack(spacing: 0) {
            AppTheme.iranGreen
            AppTheme.iranWhite
            AppTheme.iranRed
        }
        .frame(height: 4)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private var sheetDragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onEnded { value in
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width), abs(dy) > 36 else { return }
                setSheetExpanded(dy < 0)
            }
    }

    private func setSheetExpanded(_ expanded: Bool) {
        guard sheetExpanded != expanded else { return }
        HapticFeedback.light()
        sheetExpanded = expanded
    }

    /// DEBUG-only: `-UITestPowerPreview connecting|connected|disconnected|error` renders the
    /// power button in that state so its animations can be reviewed without a live tunnel.
    private var powerPreviewStatus: VPNStatusDisplay? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "UITestPowerPreview") {
        case "connecting": return .connecting
        case "connected": return .connected
        case "disconnected": return .disconnected
        case "error": return .error
        default: return nil
        }
        #else
        return nil
        #endif
    }

    private func primaryControls(powerSize: CGFloat) -> some View {
        VStack(spacing: 14) {
            noticeStack
            statusRow
            ConnectPowerButton(
                status: powerPreviewStatus ?? vpn.status,
                isEnabled: configReady || vpn.status != .disconnected,
                size: powerSize
            ) {
                if !SharedSettingsStore.shared.appSettings.hasAcceptedConnectionDisclaimer {
                    SharedLogger.shared.logRaw("CONNECT_BLOCKED_PENDING_DISCLAIMER", detail: "source=connect_button")
                    showDisclosure = true
                    return
                }
                if shouldDisconnectOnPowerTap {
                    Task {
                        await vpn.prepareForUserToggle()
                        await vpn.disconnect()
                    }
                } else {
                    vpn.beginUserConnectFeedback()
                    Task {
                        await vpn.connect()
                    }
                }
            }
            .padding(.vertical, 2)
            controlChips
            trafficRow
        }
    }

    @ViewBuilder
    private var noticeStack: some View {
        if !configReady { ConfigSetupBanner() }
        if vpn.banner != .none { ErrorBanner(kind: vpn.banner, message: vpn.lastError) }
        if showSlowConnectionHelp {
            DashboardNotice(
                icon: "hourglass",
                tint: .orange,
                title: L10n.t(.slowConnectionTitle),
                message: L10n.t(.slowConnectionMessage)
            )
            .accessibilityIdentifier("slowConnectionHelp")
        }
        if showProxyOnlyWarning {
            DashboardNotice(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: nil,
                message: L10n.t(.proxyOnlyWarningDashboard)
            )
            .accessibilityIdentifier("proxyOnlyWarningBanner")
        }
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusOrb(status: vpn.status, tint: statusTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .leading) {
                    Text(localizedStatusMessage)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(statusTint)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel(Text(L10n.t(.status)))
                        .accessibilityValue(Text(localizedStatusMessage))
                        .accessibilityIdentifier("statusLabel")
                        .id(localizedStatusMessage)
                        .transition(.statusSwap)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.78), value: localizedStatusMessage)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(durationText)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .modifier(RollingText(value: durationText))
                        .accessibilityLabel(Text(L10n.t(.session)))
                        .accessibilityValue(Text(durationText))
                        .accessibilityIdentifier("durationLabel")
                    if let protocolLabel = connectedProtocolLabel {
                        Text("·")
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        Text(protocolLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.iranGreen)
                            .lineLimit(1)
                            .modifier(RollingText(value: protocolLabel))
                            .accessibilityLabel(Text(L10n.t(.connectedProtocol)))
                            .accessibilityValue(Text(protocolLabel))
                            .accessibilityIdentifier("connectedProtocolLabel")
                            .transition(.move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                }
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: connectedProtocolLabel)
            }
            Spacer(minLength: 0)
            Button {
                setSheetExpanded(!sheetExpanded)
            } label: {
                Image(systemName: sheetExpanded ? "chevron.down" : "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.primaryText(for: colorScheme).opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t(sheetExpanded ? .dashboardHideDetails : .dashboardDetails)))
            .accessibilityIdentifier("dashboardDetailsToggle")
        }
    }

    private var controlChips: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AppSettings.ProtocolSelection.allCases) { protocolSelection in
                    Button {
                        updateProtocol(protocolSelection)
                    } label: {
                        HStack {
                            Text(SettingsLabels.protocolName(protocolSelection))
                            if selectedProtocol == protocolSelection {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(
                        protocolSelection == .conduit
                            && !SharedSettingsStore.shared.conduitConnectAllowed
                    )
                }
            } label: {
                DashboardChip(
                    title: L10n.t(.settingsProtocol),
                    value: SettingsLabels.protocolName(selectedProtocol),
                    icon: "arrow.triangle.branch",
                    showsChevron: true
                )
            }
            .accessibilityLabel(Text(L10n.t(.settingsProtocol)))
            .accessibilityValue(Text(SettingsLabels.protocolName(selectedProtocol)))
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
            .accessibilityIdentifier("dashboardProtocolMenu")

            Button {
                showRegionPicker = true
            } label: {
                DashboardChip(
                    title: L10n.t(.region),
                    value: regionTitle,
                    icon: "globe",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.t(.changeRegion)))
            .accessibilityValue(Text(regionTitle))
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
            .accessibilityIdentifier("dashboardRegionMenu")

            Button {
                Task { await refreshPing() }
            } label: {
                DashboardChip(
                    title: L10n.t(.vpnPing),
                    value: pingDisplayText,
                    icon: "dot.radiowaves.left.and.right",
                    trailingSymbol: "arrow.clockwise",
                    trailingSymbolSpinning: pingRefreshing
                )
            }
            .buttonStyle(.plain)
            .disabled(vpn.status != .connected || pingRefreshing)
            .accessibilityLabel(Text(L10n.t(.vpnPing)))
            .accessibilityValue(Text(pingDisplayText))
            .accessibilityHint(Text(L10n.t(.refreshPing)))
            .accessibilityIdentifier("pingRefreshButton")
        }
        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
    }

    private var trafficRow: some View {
        HStack(spacing: 0) {
            TrafficMeter(
                title: L10n.t(.download),
                speed: ByteCountFormatter.formatSpeed(vpn.statistics.downloadSpeedBps),
                total: ByteCountFormatter.formatTotal(vpn.statistics.bytesDown),
                totalTitle: L10n.t(.totalDownload),
                icon: "arrow.down",
                tint: AppTheme.iranGreen,
                speedID: "downloadSpeedLabel",
                totalID: "totalDownloadLabel"
            )
            Rectangle()
                .fill(AppTheme.cardStroke(for: colorScheme))
                .frame(width: 1, height: 34)
                .accessibilityHidden(true)
            TrafficMeter(
                title: L10n.t(.upload),
                speed: ByteCountFormatter.formatSpeed(vpn.statistics.uploadSpeedBps),
                total: ByteCountFormatter.formatTotal(vpn.statistics.bytesUp),
                totalTitle: L10n.t(.totalUpload),
                icon: "arrow.up",
                tint: AppTheme.iranRed,
                speedID: "uploadSpeedLabel",
                totalID: "totalUploadLabel"
            )
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.primaryText(for: colorScheme).opacity(0.05))
        )
    }

    // MARK: - Details (expanded sheet)

    @ViewBuilder
    private var detailsContent: some View {
        if showConduitProgress { conduitProgressSection }
        if vpn.status == .connected, showProxyOnlyCard { proxyOnlyCard }
        connectionSection
        if vpn.status == .connected, hasDiagnosticsContent { diagnosticsSection }
        Text(L10n.t(.trafficFootnote))
            .font(.caption2)
            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isStaticText)
    }

    private var connectionSection: some View {
        DashboardSection(title: L10n.t(.publicIP), icon: "network") {
            CopyableIPRow(
                label: L10n.t(.publicIP),
                value: publicIPLabel,
                onCopied: notifyCopiedToClipboard
            )
            if let subtitle = regionSubtitle {
                diagnosticsRow(L10n.t(.region), subtitle)
            }
            if let protocolLabel = connectedProtocolLabel {
                diagnosticsRow(L10n.t(.connectedProtocol), protocolLabel)
            }
        }
    }

    private func runPingRefreshLoop() async {
        guard vpn.status == .connected else {
            displayedPingMs = -1
            return
        }
        displayedPingMs = ConnectionDiagnosticsStore.loadQuality()?.latencyMs ?? -1
        while !Task.isCancelled, vpn.status == .connected {
            try? await TaskSleep.seconds(5)
            guard !Task.isCancelled, vpn.status == .connected else { break }
            await refreshPing()
        }
    }

    private func refreshPing() async {
        guard vpn.status == .connected else {
            displayedPingMs = -1
            return
        }
        guard !pingRefreshInFlight else { return }
        pingRefreshInFlight = true
        pingRefreshing = true
        defer {
            pingRefreshInFlight = false
            pingRefreshing = false
        }
        displayedPingMs = await ConnectionQualityService.refreshLatency()
    }

    private var pingDisplayText: String {
        guard vpn.status == .connected else { return "—" }
        if pingRefreshing, displayedPingMs < 0 { return "…" }
        let ms = displayedPingMs >= 0
            ? displayedPingMs
            : (ConnectionDiagnosticsStore.loadQuality()?.latencyMs ?? -1)
        return ms >= 0 ? "\(ms) ms" : "—"
    }

    private var hasDiagnosticsContent: Bool {
        ConnectionDiagnosticsStore.loadLeak() != nil
            || ConnectionDiagnosticsStore.loadQuality() != nil
            || {
                let f = ConnectionDiagnosticsStore.loadFallback()
                return f.isActive || f.succeededStep != nil || f.exhausted
            }()
            || {
                let r = ConnectionDiagnosticsStore.loadSmartRecovery()
                return r.isActive || r.succeededPhase != nil || r.exhausted
            }()
    }

    private var diagnosticsSection: some View {
        DashboardSection(title: L10n.t(.diagnosticsSection), icon: "stethoscope") {
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
                let recovery = ConnectionDiagnosticsStore.loadSmartRecovery()
                if recovery.isActive || recovery.succeededPhase != nil || recovery.exhausted {
                    diagnosticsSubsection(title: L10n.t(.smartRecoveryTitle)) {
                        diagnosticsRow(
                            L10n.t(.smartRecoveryPhase),
                            SmartRecoveryLabels.phaseName(recovery.currentPhase ?? recovery.succeededPhase)
                        )
                        if recovery.totalAttempts > 0 {
                            diagnosticsRow(
                                L10n.t(.smartRecoveryProgress),
                                "\(recovery.attemptIndex)/\(recovery.totalAttempts)"
                            )
                        }
                        if let succeeded = recovery.succeededPhase {
                            diagnosticsRow(
                                L10n.t(.smartRecoverySuccess),
                                SmartRecoveryLabels.phaseName(succeeded)
                            )
                        } else if recovery.exhausted {
                            diagnosticsRow(L10n.t(.smartRecoveryExhausted), "—")
                        }
                        if let reason = recovery.lastFailureReason.nilIfEmpty {
                            diagnosticsRow(L10n.t(.fallbackReason), reason)
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
        }
        .accessibilityIdentifier("diagnosticsCard")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
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

    private var showConduitProgress: Bool {
        guard SharedSettingsStore.shared.appSettings.protocolSelection == .conduit else { return false }
        guard vpn.status == .connecting || vpn.status == .connected else { return false }
        return !vpn.statistics.conduitStatusLine.isEmpty || !vpn.statistics.conduitStatusHistory.isEmpty
    }

    private var conduitProgressSection: some View {
        DashboardSection(title: L10n.t(.conduitProgress), icon: "point.3.connected.trianglepath.dotted") {
            Text(L10n.t(.conduitProgressHint))
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Text(vpn.statistics.conduitStatusLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.iranGreen)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(L10n.t(.conduitProgress)))
                .accessibilityValue(Text(vpn.statistics.conduitStatusLine))
                .accessibilityIdentifier("conduitStatusLine")
            if !vpn.statistics.conduitStatusHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(vpn.statistics.conduitStatusHistory.prefix(4).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                .accessibilityHidden(true)
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityIdentifier("conduitStatusHistory")
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var showProxyOnlyWarning: Bool {
        SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled
            && vpn.status == .connected
            && (vpn.statistics.proxyOnlyModeActive || SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled)
    }

    private var showProxyOnlyCard: Bool {
        vpn.statistics.proxyOnlyModeActive
            || (SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled && vpn.status == .connected)
    }

    private var proxyOnlyCard: some View {
        DashboardSection(title: L10n.t(.proxyOnlyModeProxyOnly), icon: "arrow.left.arrow.right.circle", tint: .orange) {
            Text(L10n.t(.proxyOnlySameDeviceAddresses))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            if let host = proxySameDeviceHost {
                proxyOnlyAddressRow(
                    title: L10n.t(.shareProxyHttpAddressTitle),
                    value: "\(host):\(proxyHttpPort)"
                )
                proxyOnlyAddressRow(
                    title: L10n.t(.shareProxySocksAddressTitle),
                    value: "\(host):\(proxySocksPort)"
                )
            } else {
                Text(L10n.t(.proxyOnlyNoWifiSameDevice))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(L10n.t(.proxyOnlyLoopbackNotReachable))
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Text(L10n.t(.proxyOnlyWarningFull))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .accessibilityIdentifier("proxyOnlyDashboardCard")
    }

    private var proxySameDeviceHost: String? {
        SameDeviceProxyAddress.reachableHost(
            boundHost: SharedSettingsStore.shared.lanProxyBoundHost
        ) ?? LocalNetworkAddress.wifiIPv4()
    }

    private var proxyHttpPort: Int {
        let active = SharedSettingsStore.shared.lanProxyActiveHttpPort
        return active > 0 ? active : SharedSettingsStore.shared.appSettings.lanHttpProxyPort
    }

    private var proxySocksPort: Int {
        let active = SharedSettingsStore.shared.lanProxyActiveSocksPort
        return active > 0 ? active : SharedSettingsStore.shared.appSettings.lanSocksProxyPort
    }

    private func proxyOnlyAddressRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            Button {
                UIPasteboard.general.string = value
                presentCopyToast(L10n.t(.copiedToClipboard))
            } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(L10n.t(.copy)) \(title)"))
            .accessibilityHint(Text(L10n.t(.accessibilityCopy)))
        }
    }

    private func presentCopyToast(_ message: String) {
        copyToastHideTask?.cancel()
        toastMessage = message
        showCopyToast = true
        copyToastHideTask = Task {
            try? await TaskSleep.seconds(2)
            guard !Task.isCancelled else { return }
            await MainActor.run { showCopyToast = false }
        }
    }

    private var localizedStatusMessage: String {
        let recovery = ConnectionDiagnosticsStore.loadSmartRecovery()
        if recovery.isActive {
            let phase = SmartRecoveryLabels.phaseName(recovery.currentPhase)
            if recovery.totalAttempts > 0, recovery.attemptIndex > 0 {
                return "\(L10n.t(.smartRecoveryWorking)) (\(recovery.attemptIndex)/\(recovery.totalAttempts) · \(phase))"
            }
            return L10n.t(.smartRecoveryWorking)
        }
        if showConduitProgress, vpn.status == .connecting,
           !vpn.statistics.conduitStatusLine.isEmpty {
            return vpn.statistics.conduitStatusLine
        }
        switch vpn.status {
        case .connected:
            if vpn.statistics.proxyOnlyModeActive
                || SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled {
                return L10n.t(.proxyOnlyStatusConnected)
            }
            return L10n.t(.connected)
        case .connecting: return L10n.t(.connecting)
        case .disconnecting: return L10n.t(.disconnecting)
        case .disconnected: return L10n.t(.disconnected)
        case .error: return vpn.statusMessage == "Setup required" ? L10n.t(.setupRequired) : L10n.t(.failed)
        }
    }

    /// Disconnect only when our tunnel session is active. Failed → retry connect (not hide the banner).
    private var shouldDisconnectOnPowerTap: Bool {
        switch vpn.status {
        case .connected, .connecting, .disconnecting:
            return true
        case .disconnected, .error:
            return false
        }
    }

    private var regionTitle: String {
        let r = SharedSettingsStore.shared.appSettings.egressRegion
        if r.isEmpty { return L10n.t(.regionAny) }
        return RegionDisplayNames.pickerLabel(for: r, locale: AppLanguageController.shared.locale)
    }

    private var regionSubtitle: String? {
        guard vpn.status == .connected else { return nil }
        let loc = vpn.statistics.egressLocationSubtitle
        return loc.isEmpty ? nil : loc
    }

    private var publicIPLabel: String {
        let ip = vpn.statistics.lastPublicIP
        if !ip.isEmpty { return ip }
        if vpn.status != .connected,
           let originIP = PublicIPAddress.normalized(vpn.statistics.originPublicIP ?? "") {
            return originIP
        }
        if vpn.status == .connected,
           SharedSettingsStore.shared.appSettings.proxyOnlyModeEnabled
            || vpn.statistics.proxyOnlyModeActive {
            return L10n.t(.proxyOnlyPublicIPUnavailable)
        }
        return "—"
    }

    private var connectedProtocolLabel: String? {
        guard vpn.status == .connected else { return nil }
        let display = ConnectedTunnelProtocolParser.displayName(
            for: vpn.statistics.connectedTunnelProtocol
        )
        guard !display.isEmpty else { return nil }
        return display
    }

    private var egressMapCoordinate: WorldMapCoordinate? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMapRoutePreview") {
            return WorldMapCoordinate(latitude: 56.1304, longitude: -106.3468)
        }
        guard vpn.status == .connected,
              PublicIPAddress.normalized(vpn.statistics.lastPublicIP) != nil,
              let latitude = vpn.statistics.connectedLatitude,
              let longitude = vpn.statistics.connectedLongitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return nil }
        return WorldMapCoordinate(latitude: latitude, longitude: longitude)
    }

    private var originMapCoordinate: WorldMapCoordinate? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMapRoutePreview") {
            return WorldMapCoordinate(latitude: 35.6892, longitude: 51.3890)
        }
        return WorldMapLocationResolver.originCoordinate(for: vpn.statistics)
    }

    private var originCountryCode: String? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMapRoutePreview") {
            return "IR"
        }
        return vpn.statistics.originCountryCode
    }

    private var destinationCountryCode: String? {
        if ProcessInfo.processInfo.arguments.contains("-UITestMapRoutePreview") {
            return "CA"
        }
        return vpn.statistics.connectedCountryCode
    }

    private var isMapConnectionVisible: Bool {
        vpn.status == .connected
            || ProcessInfo.processInfo.arguments.contains("-UITestMapRoutePreview")
    }

    private func refreshConfigFlag() {
        configReady = SharedSettingsStore.shared.hasActivePsiphonConfig
    }

    private func refreshProtocolSelection() {
        let stored = SharedSettingsStore.shared.appSettings.protocolSelection
        if selectedProtocol != stored {
            selectedProtocol = stored
        }
    }

    private func updateProtocol(_ protocolSelection: AppSettings.ProtocolSelection) {
        guard protocolSelection != .conduit || SharedSettingsStore.shared.conduitConnectAllowed else {
            return
        }
        selectedProtocol = protocolSelection
        var settings = SharedSettingsStore.shared.appSettings
        guard settings.protocolSelection != protocolSelection else { return }
        settings.protocolSelection = protocolSelection
        SharedSettingsStore.shared.updateAppSettings(
            settings,
            logKey: "dashboard_protocol_selection"
        )
    }

    private func updateSlowConnectionHelp() {
        guard vpn.status == .connecting else {
            connectingStartedAt = nil
            showSlowConnectionHelp = false
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if connectingStartedAt == nil {
            connectingStartedAt = now
        }
        let hintDelay = selectedProtocol == .cdnFronting
            ? RecoveryTimingDefaults.cdnSlowConnectionHintDelay
            : RecoveryTimingDefaults.slowConnectionHintDelay
        let shouldShow = now - (connectingStartedAt ?? now) >= hintDelay
        if shouldShow, !showSlowConnectionHelp {
            SharedLogger.shared.logRaw(
                "SLOW_CONNECTION_HELP_SHOWN",
                detail: "delay_s=\(Int(hintDelay))"
            )
        }
        showSlowConnectionHelp = shouldShow
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
        SharedSettingsStore.shared.egressRegionUnavailable = false
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: "dashboard_egress_region")
    }
}

/// A small lion living behind the wordmark: it pops up at random spots, breathes and
/// glances around, ducks to its ear tips to scurry behind the letters to another spot,
/// sometimes hops, then hides for a few seconds. Skipped entirely with Reduce Motion.
struct PeekingLion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trackWidth: CGFloat
    /// Delay before the first appearance.
    var startDelay: Double = 1.5
    /// When false the lion performs a single visit (used by the splash) and stays hidden.
    var repeats = true
    /// How many spots the lion visits per appearance (1 = pop up once in place).
    var maxSpots = 3

    /// Clip window above the hide line; the line sits inside the letters so the
    /// lion appears to rise from behind them.
    static let windowHeight: CGFloat = 42
    static let hideLine: CGFloat = 21
    private static let lionSize: CGFloat = 26

    private enum Pose {
        case hidden, ears, peek, hop

        /// Top of the lion inside the clip window (window bottom = hide line).
        var top: CGFloat {
            switch self {
            case .hidden: return PeekingLion.windowHeight + 2
            case .ears: return PeekingLion.windowHeight - 9
            case .peek: return PeekingLion.windowHeight - 25
            case .hop: return PeekingLion.windowHeight - 34
            }
        }
    }

    @State private var pose: Pose = .hidden
    @State private var position: CGFloat = 0.7
    @State private var tilt: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: pose == .hidden)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breathing = pose == .peek ? sin(time * 5.5) : 0
            Text("\u{1F981}")
                .font(.system(size: 22))
                .scaleEffect(x: 1 - 0.02 * breathing, y: 1 + 0.04 * breathing, anchor: .bottom)
                .rotationEffect(.degrees(tilt), anchor: .bottom)
                .offset(
                    x: max(0, trackWidth - Self.lionSize) * position,
                    y: pose.top + CGFloat(breathing)
                )
        }
        .frame(width: max(trackWidth, Self.lionSize), height: Self.windowHeight, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task { await live() }
    }

    private func live() async {
        guard !reduceMotion else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestLionPeek") {
            pose = .peek
            return
        }
        #endif
        try? await TaskSleep.seconds(startDelay)
        while !Task.isCancelled {
            let count = maxSpots <= 1 ? 1 : Int.random(in: 2...maxSpots)
            var spots = (0..<count).map { _ in CGFloat.random(in: 0.05...0.95) }
            position = spots.removeFirst()
            await popUp()
            for spot in spots {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.22)) { pose = .ears }
                try? await TaskSleep.seconds(0.22)
                let lean: Double = spot > position ? 14 : -14
                let travel = Double(abs(spot - position)) * 1.1 + 0.35
                withAnimation(.easeInOut(duration: travel)) {
                    position = spot
                    tilt = lean
                }
                try? await TaskSleep.seconds(travel)
                await popUp()
            }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
                pose = .hidden
                tilt = 0
            }
            guard repeats else { return }
            try? await TaskSleep.seconds(Double.random(in: 2.5...5))
        }
    }

    /// Spring up, maybe hop, then glance around before the next move.
    private func popUp() async {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
            pose = .peek
            tilt = 0
        }
        try? await TaskSleep.seconds(0.45)
        if Bool.random() {
            withAnimation(.easeOut(duration: 0.16)) { pose = .hop }
            try? await TaskSleep.seconds(0.16)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { pose = .peek }
            try? await TaskSleep.seconds(0.35)
        }
        for _ in 0..<Int.random(in: 1...3) {
            withAnimation(.easeInOut(duration: 0.26)) { tilt = Double.random(in: -16...16) }
            try? await TaskSleep.seconds(Double.random(in: 0.35...0.7))
        }
        withAnimation(.easeInOut(duration: 0.2)) { tilt = 0 }
        try? await TaskSleep.seconds(0.25)
    }
}

/// Rolls changed characters (timers, speeds, protocol names) on iOS 16+, fades otherwise.
private struct RollingText: ViewModifier {
    let value: String

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .contentTransition(.numericText())
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: value)
        } else {
            content.animation(.easeInOut(duration: 0.25), value: value)
        }
    }
}

private extension AnyTransition {
    /// New status text rises in from below while the old one lifts away, slightly blurred.
    static var statusSwap: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .leading)),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

/// Animated status badge: radar ripples around a lock when connected, a spinning
/// arc while connecting, a slow breath when idle and a pulse on error.
private struct StatusOrb: View {
    let status: VPNStatusDisplay
    let tint: Color

    private var icon: String {
        switch status {
        case .connected: return "lock.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "lock.open.fill"
        case .error: return "exclamationmark"
        }
    }

    private var isBusy: Bool {
        status == .connecting || status == .disconnecting
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breath = sin(time * (status == .error ? 5 : 1.6)) * 0.5 + 0.5
            ZStack {
                if status == .connected {
                    ForEach(0..<2, id: \.self) { ring in
                        let phase = (time / 2.2 + Double(ring) / 2).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(tint.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                            .frame(width: 24 + 30 * phase, height: 24 + 30 * phase)
                    }
                }
                Circle()
                    .fill(tint.opacity(0.14 + (status == .connected ? 0.06 : 0.08) * breath))
                    .frame(width: 42, height: 42)
                if isBusy {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(colors: [tint.opacity(0), tint], center: .center),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 36, height: 36)
                        .rotationEffect(.radians(time * 5.5))
                }
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.95), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 24, height: 24)
                    .scaleEffect(isBusy ? 0.86 + 0.1 * breath : (status == .error ? 0.94 + 0.08 * breath : 1))
                    .shadow(color: tint.opacity(status == .connected ? 0.75 : 0.3), radius: status == .connected ? 7 : 3)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .rotationEffect(.radians(isBusy ? time * 3 : 0))
                    .id(icon)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .animation(.spring(response: 0.42, dampingFraction: 0.55), value: status)
    }
}

private enum DashboardLayout {
    /// Header (44) + route caption (~36) + spacing; the map hero starts below it.
    static let headerHeight: CGFloat = 100
    static let grabberHeight: CGFloat = 22
    static let sheetCornerRadius: CGFloat = 30
}

/// Liquid Glass on iOS 26+, with a translucent material fallback on earlier systems.
private struct DashboardGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 22, y: 8)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(AppTheme.cardStroke(for: colorScheme), lineWidth: 1))
                .clipShape(shape)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 24, y: 8)
        }
    }
}

/// Natural height of the sheet's content, so the scroll area hugs it instead of filling the cap.
private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the collapsed control sheet, so the map hero can center in the space above it.
private struct CollapsedSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DashboardChip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let value: String
    let icon: String
    var showsChevron = false
    var trailingSymbol: String?
    var trailingSymbolSpinning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            HStack(spacing: 4) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .modifier(RollingText(value: value))
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.iranGreen)
                        .accessibilityHidden(true)
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isEnabled ? AppTheme.iranGreen : AppTheme.secondaryText(for: colorScheme).opacity(0.5))
                        .rotationEffect(.degrees(trailingSymbolSpinning ? 360 : 0))
                        .animation(
                            trailingSymbolSpinning
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: trailingSymbolSpinning
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.primaryText(for: colorScheme).opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TrafficMeter: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let speed: String
    let total: String
    let totalTitle: String
    let icon: String
    let tint: Color
    let speedID: String
    let totalID: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(speed)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .modifier(RollingText(value: speed))
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(speed))
                    .accessibilityIdentifier(speedID)
                HStack(spacing: 3) {
                    Text(L10n.t(.dashboardTotal))
                        .accessibilityHidden(true)
                    Text(total)
                        .modifier(RollingText(value: total))
                        .accessibilityLabel(Text(total))
                        .accessibilityIdentifier(totalID)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Grouped content inside the expanded sheet.
private struct DashboardSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    var tint: Color = AppTheme.iranGreen
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.primaryText(for: colorScheme).opacity(0.045))
        )
    }
}

/// Compact tinted notice that fits inside the control sheet.
private struct DashboardNotice<Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let title: String?
    let message: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme).opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

extension DashboardNotice where Accessory == EmptyView {
    init(icon: String, tint: Color, title: String?, message: String, detail: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, message: message, detail: detail) { EmptyView() }
    }
}

private struct ConfigSetupBanner: View {
    var body: some View {
        DashboardNotice(
            icon: "exclamationmark.triangle.fill",
            tint: AppTheme.iranRed,
            title: nil,
            message: L10n.t(.configSetupBanner)
        )
        .accessibilityIdentifier("config_setup_banner")
    }
}

private struct ErrorBanner: View {
    let kind: VPNBannerKind
    let message: String?

    var body: some View {
        DashboardNotice(
            icon: "exclamationmark.octagon.fill",
            tint: AppTheme.danger,
            title: title,
            message: subtitle,
            detail: message
        ) {
            if showsOpenSettings {
                Button(L10n.t(.openIOSSettings)) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.iranGreen)
                .padding(.top, 2)
                .accessibilityIdentifier("open_ios_settings_button")
            }
        }
        .accessibilityIdentifier("error_banner")
    }

    private var showsOpenSettings: Bool {
        kind == .otherVpnBlocking || kind == .vpnPermission
    }

    private var title: String {
        switch kind {
        case .noConfig: return L10n.t(.errorNoConfig)
        case .conduitBlocked: return L10n.t(.errorConduitBlocked)
        case .vpnPermission: return L10n.t(.errorVPNPermission)
        case .otherVpnBlocking: return L10n.t(.errorOtherVpnBlocking)
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
        case .otherVpnBlocking: return L10n.t(.errorOtherVpnBlockingSub)
        case .psiphonFailed: return L10n.t(.errorPsiphonFailedSub)
        case .internetTestFailed: return L10n.t(.errorInternetTestSub)
        case .none: return ""
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
