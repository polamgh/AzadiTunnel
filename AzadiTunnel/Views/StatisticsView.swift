import SwiftUI

struct StatisticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var history = StatsHistoryStore.shared
    @State private var appeared = false

    private var isConnected: Bool { history.status == .connected }
    private var latestSpeed: SpeedSample? { history.speedSamples.last }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    statusPill
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(StatsAppear(index: 0, appeared: appeared))
                    liveSpeedCard
                        .modifier(StatsAppear(index: 1, appeared: appeared))
                    sessionTiles
                        .modifier(StatsAppear(index: 2, appeared: appeared))
                    if !history.latencySamples.isEmpty {
                        latencyCard
                            .modifier(StatsAppear(index: 3, appeared: appeared))
                    }
                    weeklyCard
                        .modifier(StatsAppear(index: 4, appeared: appeared))
                    connectionsCard
                        .modifier(StatsAppear(index: 5, appeared: appeared))
                    if !history.protocolBreakdown.isEmpty {
                        protocolsCard
                            .modifier(StatsAppear(index: 6, appeared: appeared))
                    }
                    recentCard
                        .modifier(StatsAppear(index: 7, appeared: appeared))
                    allTimeCard
                        .modifier(StatsAppear(index: 8, appeared: appeared))
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(SettingsSurface())
            .navigationTitle(L10n.t(.statisticsTitle))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .id(lang.revision)
        .accessibilityIdentifier("statisticsScreen")
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
    }

    // MARK: - Header

    private var statusPill: some View {
        let tint = AppTheme.statusColor(for: history.status, scheme: colorScheme)
        return HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint, radius: isConnected ? 4 : 0)
            Text(statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            if isConnected {
                Text("·").foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                Text(ByteCountFormatter.formatDuration(history.statistics.sessionDuration))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .modifier(StatsRollingText(value: ByteCountFormatter.formatDuration(history.statistics.sessionDuration)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch history.status {
        case .connected: return L10n.t(.connected)
        case .connecting: return L10n.t(.connecting)
        case .disconnecting: return L10n.t(.disconnecting)
        case .disconnected: return L10n.t(.disconnected)
        case .error: return L10n.t(.failed)
        }
    }

    // MARK: - Live speed

    private var liveSpeedCard: some View {
        StatsCard(title: L10n.t(.statsLiveSpeed), icon: "waveform.path.ecg", trailing: L10n.t(.statsLastTwoMinutes)) {
            HStack(spacing: 18) {
                speedReadout(
                    icon: "arrow.down",
                    tint: AppTheme.iranGreenBright,
                    title: L10n.t(.download),
                    value: ByteCountFormatter.formatSpeed(latestSpeed?.down ?? 0)
                )
                speedReadout(
                    icon: "arrow.up",
                    tint: AppTheme.iranRed,
                    title: L10n.t(.upload),
                    value: ByteCountFormatter.formatSpeed(latestSpeed?.up ?? 0)
                )
                Spacer(minLength: 0)
            }
            SpeedAreaChart(samples: history.speedSamples, scaleMax: history.speedChartScale)
                .frame(height: 150)
                .padding(.top, 4)
        }
    }

    private func speedReadout(icon: String, tint: Color, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .modifier(StatsRollingText(value: value))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Session tiles

    private var sessionTiles: some View {
        let sessionDown = history.currentSessionDown
        let sessionUp = history.currentSessionUp
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatsTile(
                icon: "clock.fill",
                tint: .blue,
                title: L10n.t(.statsSessionTime),
                value: isConnected ? ByteCountFormatter.formatDuration(history.statistics.sessionDuration) : "—"
            )
            StatsTile(
                icon: "arrow.up.arrow.down",
                tint: AppTheme.iranGreen,
                title: L10n.t(.statsSessionData),
                value: isConnected ? ByteCountFormatter.formatTotal(sessionDown + sessionUp) : "—",
                detail: isConnected ? "↓ \(ByteCountFormatter.formatTotal(sessionDown))  ↑ \(ByteCountFormatter.formatTotal(sessionUp))" : nil
            )
            StatsTile(
                icon: "speedometer",
                tint: .orange,
                title: L10n.t(.statsPeakSpeed),
                value: ByteCountFormatter.formatSpeed(history.sessionPeakDown),
                detail: "↑ \(ByteCountFormatter.formatSpeed(history.sessionPeakUp))"
            )
            StatsTile(
                icon: "dot.radiowaves.left.and.right",
                tint: .purple,
                title: L10n.t(.statsAvgPing),
                value: history.averageLatency.map { "\($0) ms" } ?? "—"
            )
        }
    }

    // MARK: - Latency

    private var latencyCard: some View {
        let values = history.latencySamples.map(\.milliseconds)
        return StatsCard(title: L10n.t(.statsLatency), icon: "timer", trailing: nil) {
            HStack(spacing: 22) {
                miniStat(L10n.t(.statsNow), values.last.map { "\($0) ms" } ?? "—", tint: .orange)
                miniStat(L10n.t(.statsMin), values.min().map { "\($0) ms" } ?? "—", tint: AppTheme.iranGreenBright)
                miniStat(L10n.t(.statsAvg), history.averageLatency.map { "\($0) ms" } ?? "—", tint: .blue)
                Spacer(minLength: 0)
            }
            LatencyLineChart(samples: history.latencySamples)
                .frame(height: 90)
        }
    }

    private func miniStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .modifier(StatsRollingText(value: value))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Weekly usage

    private var weeklyCard: some View {
        let week = history.lastSevenDays
        let total = week.reduce(UInt64(0)) { $0 &+ $1.bytesDown &+ $1.bytesUp }
        return StatsCard(title: L10n.t(.statsDailyUsage), icon: "chart.bar.fill", trailing: nil) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ByteCountFormatter.formatTotal(total))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                Text(L10n.t(.statsThisWeek))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                Spacer(minLength: 0)
                legendDot(AppTheme.iranGreenBright, L10n.t(.download))
                legendDot(AppTheme.iranRed, L10n.t(.upload))
            }
            WeeklyUsageBars(days: week, locale: lang.locale)
                .frame(height: 140)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
        }
    }

    // MARK: - Connections

    private var connectionsCard: some View {
        StatsCard(title: L10n.t(.statsConnections), icon: "point.3.filled.connected.trianglepath.dotted", trailing: nil) {
            if let rate = history.successRate {
                HStack(spacing: 20) {
                    VStack(spacing: 6) {
                        RatioRing(ratio: rate)
                            .frame(width: 92, height: 92)
                        Text(L10n.t(.statsSuccessRate))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        connectionFact(icon: "number", title: L10n.t(.statsTotalSessions), value: "\(history.sessions.count)")
                        connectionFact(
                            icon: "bolt.fill",
                            title: L10n.t(.statsAvgConnect),
                            value: history.averageTimeToConnect.map { String(format: "%.0f s", $0) } ?? "—"
                        )
                        connectionFact(
                            icon: "shield.lefthalf.filled",
                            title: L10n.t(.statsProtectedTime),
                            value: protectedTimeText
                        )
                    }
                    Spacer(minLength: 0)
                }
            } else {
                emptyHint
            }
        }
    }

    private var protectedTimeText: String {
        let total = Int(history.totalProtectedTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func connectionFact(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.iranGreenBright)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Protocols

    private var protocolsCard: some View {
        let breakdown = Array(history.protocolBreakdown.prefix(5))
        let total = max(breakdown.reduce(0) { $0 + $1.count }, 1)
        let palette: [Color] = [AppTheme.iranGreenBright, .blue, .orange, .purple, .pink]
        return StatsCard(title: L10n.t(.statsProtocols), icon: "arrow.triangle.branch", trailing: nil) {
            VStack(spacing: 10) {
                ForEach(Array(breakdown.enumerated()), id: \.offset) { index, item in
                    let share = Double(item.count) / Double(total)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                            Spacer()
                            Text("\(Int((share * 100).rounded()))%  ·  \(item.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppTheme.primaryText(for: colorScheme).opacity(0.07))
                                Capsule()
                                    .fill(palette[index % palette.count])
                                    .frame(width: appeared ? geometry.size.width * CGFloat(share) : 0)
                                    .shadow(color: palette[index % palette.count].opacity(0.5), radius: 4)
                                    .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.2 + Double(index) * 0.08), value: appeared)
                            }
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Recent sessions

    private var recentCard: some View {
        StatsCard(title: L10n.t(.statsRecent), icon: "clock.arrow.circlepath", trailing: nil) {
            if history.sessions.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.sessions.prefix(6).enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider().overlay(AppTheme.cardStroke(for: colorScheme))
                        }
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: ConnectionSessionRecord) -> some View {
        HStack(spacing: 12) {
            Text(session.succeeded ? RegionDisplayNames.flagEmoji(for: session.countryCode) : "⚠️")
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppTheme.primaryText(for: colorScheme).opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.succeeded
                     ? ConnectedTunnelProtocolParser.displayName(for: session.tunnelProtocol)
                     : L10n.t(.statsFailed))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.succeeded ? AppTheme.primaryText(for: colorScheme) : AppTheme.iranRed)
                Text(relativeDate(session.attemptStartedAt))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            }
            Spacer(minLength: 0)
            if session.succeeded {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.formatDuration(session.duration))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(ByteCountFormatter.formatTotal(session.bytesDown + session.bytesUp))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = lang.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - All time

    private var allTimeCard: some View {
        StatsCard(title: L10n.t(.statsAllTime), icon: "infinity", trailing: nil) {
            HStack(spacing: 10) {
                totalBlock(icon: "arrow.down.circle.fill", tint: AppTheme.iranGreenBright, title: L10n.t(.totalDownload), value: history.statistics.bytesDown)
                totalBlock(icon: "arrow.up.circle.fill", tint: AppTheme.iranRed, title: L10n.t(.totalUpload), value: history.statistics.bytesUp)
            }
        }
    }

    private func totalBlock(icon: String, tint: Color, title: String, value: UInt64) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(ByteCountFormatter.formatTotal(value))
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .modifier(StatsRollingText(value: ByteCountFormatter.formatTotal(value)))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.primaryText(for: colorScheme).opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private var emptyHint: some View {
        Text(L10n.t(.statsNoData))
            .font(.footnote)
            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// MARK: - Building blocks

private struct StatsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: icon).foregroundStyle(AppTheme.iranGreenBright)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.82))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial.opacity(0.5)))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1)
                )
        )
    }
}

private struct StatsTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsIconTile(systemName: icon, tint: tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .modifier(StatsRollingText(value: value))
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct StatsRollingText: ViewModifier {
    let value: String

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: value)
        } else {
            content
        }
    }
}

private struct StatsAppear: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.05), value: appeared)
    }
}
