import SwiftUI

// Hand-drawn charts for the Stats tab (works on iOS 15, matches the app's look).

enum ChartPath {
    /// Smooth curve through the points (Catmull-Rom converted to cubic Béziers).
    static func smoothLine(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }

    static func area(_ points: [CGPoint], baseline: CGFloat) -> Path {
        var path = smoothLine(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.addLine(to: CGPoint(x: first.x, y: baseline))
        path.closeSubpath()
        return path
    }
}

/// Download as a glowing filled area, upload as a thinner line, with three guide lines.
struct SpeedAreaChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let samples: [SpeedSample]
    /// Y-axis ceiling supplied by the store (recent peak, eased); values above it are clipped.
    let scaleMax: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let labelWidth: CGFloat = 58
            let plot = CGRect(x: 0, y: 6, width: size.width - labelWidth, height: size.height - 12)
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { line in
                    let fraction = CGFloat(line + 1) / 3
                    let y = plot.maxY - plot.height * fraction
                    Path { path in
                        path.move(to: CGPoint(x: plot.minX, y: y))
                        path.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    .stroke(AppTheme.secondaryText(for: colorScheme).opacity(0.18), style: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                    Text(ByteCountFormatter.formatSpeed(UInt64(scaleMax * Double(fraction))))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .frame(width: labelWidth - 6, alignment: .trailing)
                        .position(x: plot.maxX + labelWidth / 2, y: y)
                }

                let downPoints = points(\.down, in: plot)
                let upPoints = points(\.up, in: plot)

                ChartPath.area(downPoints, baseline: plot.maxY)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.iranGreenBright.opacity(0.45), AppTheme.iranGreenBright.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                ChartPath.smoothLine(downPoints)
                    .stroke(AppTheme.iranGreenBright, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .shadow(color: AppTheme.iranGreenBright.opacity(0.6), radius: 4)
                ChartPath.area(upPoints, baseline: plot.maxY)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.iranRed.opacity(0.22), AppTheme.iranRed.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                ChartPath.smoothLine(upPoints)
                    .stroke(AppTheme.iranRed, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                if let head = downPoints.last {
                    Circle()
                        .fill(AppTheme.iranGreenBright)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .shadow(color: AppTheme.iranGreenBright, radius: 5)
                        .position(head)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private func points(_ value: KeyPath<SpeedSample, UInt64>, in plot: CGRect) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let step = plot.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, sample in
            CGPoint(
                x: plot.minX + CGFloat(index) * step,
                y: plot.maxY - plot.height * CGFloat(min(Double(sample[keyPath: value]) / max(scaleMax, 1), 1.04))
            )
        }
    }
}

/// Ping over time: a smooth line with small markers.
struct LatencyLineChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let samples: [LatencySample]
    var tint: Color = .orange

    var body: some View {
        GeometryReader { geometry in
            let values = samples.map(\.milliseconds)
            let low = Double(values.min() ?? 0)
            let high = Double(values.max() ?? 1)
            let span = max(high - low, 20)
            let plot = CGRect(x: 4, y: 6, width: geometry.size.width - 8, height: geometry.size.height - 12)
            let points: [CGPoint] = samples.count > 1 ? samples.enumerated().map { index, sample in
                CGPoint(
                    x: plot.minX + plot.width * CGFloat(index) / CGFloat(samples.count - 1),
                    y: plot.maxY - plot.height * CGFloat((Double(sample.milliseconds) - low + span * 0.1) / (span * 1.2))
                )
            } : []
            ZStack {
                ChartPath.area(points, baseline: plot.maxY)
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                ChartPath.smoothLine(points)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(index == points.count - 1 ? tint : tint.opacity(0.55))
                        .frame(width: index == points.count - 1 ? 7 : 3.5, height: index == points.count - 1 ? 7 : 3.5)
                        .position(point)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// Seven stacked day bars (download + upload) with weekday labels; today is highlighted.
struct WeeklyUsageBars: View {
    @Environment(\.colorScheme) private var colorScheme
    let days: [DailyUsage]
    let locale: Locale
    @State private var grown = false

    var body: some View {
        let totals = days.map { Double($0.bytesDown + $0.bytesUp) }
        let peak = max(totals.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 6) {
                    GeometryReader { geometry in
                        let height = geometry.size.height
                        let total = Double(day.bytesDown + day.bytesUp)
                        let barHeight = max(total > 0 ? 6 : 3, height * CGFloat(total / peak))
                        let upShare = total > 0 ? CGFloat(Double(day.bytesUp) / total) : 0
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(AppTheme.iranRed.opacity(isToday ? 0.95 : 0.6))
                                    .frame(height: barHeight * upShare)
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [AppTheme.iranGreenBright.opacity(isToday ? 1 : 0.65), AppTheme.iranGreen.opacity(isToday ? 1 : 0.55)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                            .frame(height: grown ? barHeight : 3)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: isToday ? AppTheme.iranGreenBright.opacity(0.45) : .clear, radius: 6)
                        }
                    }
                    Text(weekday(day.day))
                        .font(.system(size: 10, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? AppTheme.primaryText(for: colorScheme) : AppTheme.secondaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(Double(index) * 0.05), value: grown)
            }
        }
        .onAppear { grown = true }
        .accessibilityHidden(true)
    }

    private func weekday(_ day: String) -> String {
        guard let date = StatsHistoryStore.date(forDay: day) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

/// Animated ring for a 0…1 ratio with the percentage in the middle.
struct RatioRing: View {
    @Environment(\.colorScheme) private var colorScheme
    let ratio: Double
    var lineWidth: CGFloat = 10
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.primaryText(for: colorScheme).opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown ? ratio : 0)
                .stroke(
                    AngularGradient(
                        colors: [AppTheme.iranGreen, AppTheme.iranGreenBright, AppTheme.iranGreen],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: AppTheme.iranGreenBright.opacity(0.45), radius: 6)
            Text("\(Int((ratio * 100).rounded()))%")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
        }
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.8).delay(0.15)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}
