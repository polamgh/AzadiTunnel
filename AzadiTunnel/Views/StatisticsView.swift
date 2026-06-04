import SwiftUI
import Charts

struct StatisticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared
    @State private var downHistory: [TrafficSample] = []
    @State private var upHistory: [TrafficSample] = []

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.t(.session))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                            Text(sessionDurationLabel)
                                .font(.title.weight(.bold))
                                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                            HStack {
                                Text("↓ \(ByteCountFormatter.formatTotal(vpn.statistics.bytesDown))")
                                Text("↑ \(ByteCountFormatter.formatTotal(vpn.statistics.bytesUp))")
                            }
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }

                    if !downHistory.isEmpty {
                        GlassCard {
                            downloadSpeedCard
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(L10n.t(.statisticsTitle))
        .id(lang.revision)
        .task {
            while !Task.isCancelled {
                vpn.refreshStatistics()
                appendSample()
                try? await TaskSleep.seconds(1)
            }
        }
    }

    @ViewBuilder
    private var downloadSpeedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download speed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            if #available(iOS 16, *) {
                Chart(downHistory) { sample in
                    LineMark(
                        x: .value("t", sample.time),
                        y: .value("bps", sample.bytesPerSecond)
                    )
                    .foregroundStyle(AppTheme.accent)
                }
                .frame(height: 140)
            } else {
                let peak = downHistory.map(\.bytesPerSecond).max() ?? 1
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(downHistory.suffix(12).enumerated()), id: \.offset) { _, sample in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.accent)
                                .frame(
                                    width: max(4, CGFloat(sample.bytesPerSecond) / CGFloat(max(peak, 1)) * 120),
                                    height: 6
                                )
                            Text(ByteCountFormatter.formatSpeed(sample.bytesPerSecond))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .frame(minHeight: 140, alignment: .topLeading)
            }
        }
    }

    private func appendSample() {
        let now = Date()
        downHistory.append(TrafficSample(time: now, bytesPerSecond: vpn.statistics.downloadSpeedBps))
        upHistory.append(TrafficSample(time: now, bytesPerSecond: vpn.statistics.uploadSpeedBps))
        if downHistory.count > 60 {
            downHistory.removeFirst(downHistory.count - 60)
            upHistory.removeFirst(upHistory.count - 60)
        }
    }

    private var sessionDurationLabel: String {
        guard vpn.status == .connected else { return "00:00:00" }
        return ByteCountFormatter.formatDuration(vpn.statistics.sessionDuration)
    }
}

private struct TrafficSample: Identifiable {
    let id = UUID()
    let time: Date
    let bytesPerSecond: UInt64
}
