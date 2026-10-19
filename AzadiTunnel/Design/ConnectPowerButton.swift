import SwiftUI

struct ConnectPowerButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: VPNStatusDisplay
    let isEnabled: Bool
    var size: CGFloat = 220
    let action: () -> Void

    @State private var pressed = false
    /// Start of the one-shot shockwave played when the tunnel comes up.
    @State private var burstStart: Date?

    /// Effects are drawn in a 220pt design space and scaled to `size`; the effect
    /// canvas is larger than the button so waves and particles can spill past it.
    private static let design: CGFloat = 220
    private static let effectCanvas: CGFloat = 320
    private static let discDiameter: CGFloat = 132

    private var accent: Color {
        AppTheme.statusColor(for: status, scheme: colorScheme)
    }

    /// The color of the animated energy around the disc.
    private var energy: Color {
        switch status {
        case .connected, .connecting, .disconnecting: return AppTheme.iranGreenBright
        case .disconnected, .error: return AppTheme.iranRed
        }
    }

    private var isBusy: Bool {
        status == .connecting || status == .disconnecting
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { pressed = true }
            HapticFeedback.light()
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { pressed = false }
            }
        } label: {
            TimelineView(.animation(minimumInterval: isBusy || burstStart != nil ? 1.0 / 60.0 : 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    aura(time)
                    Canvas { context, canvasSize in
                        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                        drawEffects(in: &context, center: center, time: time, now: timeline.date)
                    }
                    .frame(width: Self.effectCanvas, height: Self.effectCanvas)
                    mainDisc(time)
                    powerGlyph(time)
                }
                .frame(width: Self.design, height: Self.design)
            }
            .scaleEffect(size / Self.design)
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.9 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .accessibilityIdentifier("connectButton")
        .accessibilityLabel(Text(powerButtonLabel))
        .accessibilityValue(Text(L10n.t(.status) + ": " + statusAccessibilityValue))
        .accessibilityHint(Text(powerButtonHint))
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: status)
        .onChange(of: status) { newStatus in
            guard newStatus == .connected else { return }
            burstStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstDuration + 0.1) {
                burstStart = nil
            }
        }
    }

    private var powerButtonLabel: String {
        switch status {
        case .connected, .connecting, .disconnecting:
            return L10n.t(.accessibilityDisconnect)
        case .disconnected, .error:
            return L10n.t(.accessibilityConnect)
        }
    }

    private var statusAccessibilityValue: String {
        switch status {
        case .connected: return L10n.t(.connected)
        case .connecting: return L10n.t(.connecting)
        case .disconnecting: return L10n.t(.disconnecting)
        case .disconnected: return L10n.t(.disconnected)
        case .error: return L10n.t(.failed)
        }
    }

    private var powerButtonHint: String {
        switch status {
        case .connected, .connecting, .disconnecting:
            return L10n.t(.accessibilityDisconnect)
        case .disconnected, .error:
            return L10n.t(.accessibilityConnect)
        }
    }

    // MARK: - Aura

    private func aura(_ time: TimeInterval) -> some View {
        let breath: Double
        let strength: Double
        switch status {
        case .connected:
            breath = sin(time * 1.4) * 0.5 + 0.5
            strength = 0.42
        case .connecting, .disconnecting:
            breath = sin(time * 4.2) * 0.5 + 0.5
            strength = 0.36
        case .error:
            breath = sin(time * 3.0) * 0.5 + 0.5
            strength = 0.34
        case .disconnected:
            breath = sin(time * 1.1) * 0.5 + 0.5
            strength = 0.24
        }
        return Circle()
            .fill(
                RadialGradient(
                    colors: [energy.opacity(strength + 0.14 * breath), energy.opacity(0.06), .clear],
                    center: .center,
                    startRadius: 30,
                    endRadius: 124
                )
            )
            .frame(width: Self.design, height: Self.design)
            .scaleEffect(0.94 + 0.08 * breath)
            .blur(radius: 8)
    }

    // MARK: - Canvas effects

    private func drawEffects(in context: inout GraphicsContext, center: CGPoint, time: TimeInterval, now: Date) {
        switch status {
        case .connecting, .disconnecting:
            drawVortex(in: &context, center: center, time: time)
        case .connected:
            drawConnected(in: &context, center: center, time: time)
        case .disconnected:
            drawIdle(in: &context, center: center, time: time, speed: 0.35, alpha: 0.55)
        case .error:
            drawIdle(in: &context, center: center, time: time, speed: 0.9, alpha: 0.8)
        }
        if let burstStart {
            drawBurst(in: &context, center: center, elapsed: now.timeIntervalSince(burstStart))
        }
    }

    /// Idle: a slow sheen sweeping around a hairline ring, plus a breathing outline.
    private func drawIdle(in context: inout GraphicsContext, center: CGPoint, time: TimeInterval, speed: Double, alpha: Double) {
        let ring = Self.circle(center, radius: 88)
        let sweep = Gradient(stops: [
            .init(color: energy.opacity(0.0), location: 0),
            .init(color: energy.opacity(0.9 * alpha), location: 0.18),
            .init(color: Color.white.opacity(0.7 * alpha), location: 0.24),
            .init(color: energy.opacity(0.0), location: 0.5),
            .init(color: energy.opacity(0.0), location: 1)
        ])
        context.stroke(
            ring,
            with: .conicGradient(sweep, center: center, angle: .radians(time * speed * 2 * .pi)),
            lineWidth: 2.4
        )
        let breath = sin(time * 1.6) * 0.5 + 0.5
        context.stroke(
            Self.circle(center, radius: 96 + 3 * breath),
            with: .color(energy.opacity(0.10 + 0.14 * breath)),
            lineWidth: 1.4
        )
    }

    /// Connecting: two counter-rotating comets and particles spiralling into the disc.
    private func drawVortex(in context: inout GraphicsContext, center: CGPoint, time: TimeInterval) {
        let comets: [(radius: CGFloat, speed: Double, color: Color, width: CGFloat)] = [
            (82, 2.8, AppTheme.iranGreenBright, 4.2),
            (98, -2.0, Color.white, 3.0)
        ]
        for comet in comets {
            let head = time * comet.speed
            let segments = 26
            for index in 0..<segments {
                let fade = 1 - Double(index) / Double(segments)
                let direction: Double = comet.speed > 0 ? -1 : 1
                let start = head + direction * Double(index) * 0.055
                let end = start + direction * 0.06
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: comet.radius,
                    startAngle: .radians(min(start, end)),
                    endAngle: .radians(max(start, end)),
                    clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(comet.color.opacity(0.95 * fade * fade)),
                    style: StrokeStyle(lineWidth: comet.width * CGFloat(fade) + 0.4, lineCap: .round)
                )
            }
            let headPoint = Self.point(center, radius: comet.radius, angle: head)
            context.fill(Self.circle(headPoint, radius: 7), with: .color(comet.color.opacity(0.25)))
            context.fill(Self.circle(headPoint, radius: 2.6), with: .color(.white))
        }

        let particles = 16
        for index in 0..<particles {
            let seed = Double(index) / Double(particles)
            let phase = (time * 0.55 + seed).truncatingRemainder(dividingBy: 1)
            let radius = CGFloat(126 - phase * 58)
            let angle = seed * 2 * .pi + time * (0.6 + Double(index % 3) * 0.25) + phase * 2.4
            let alpha = sin(phase * .pi)
            let point = Self.point(center, radius: radius, angle: angle)
            let dot = CGFloat(1.2 + 1.6 * alpha)
            context.fill(
                Self.circle(point, radius: dot),
                with: .color((index.isMultiple(of: 2) ? AppTheme.iranGreenBright : Color.white).opacity(0.85 * alpha))
            )
        }
    }

    /// Connected: calm ripples, a rotating halo and twinkling sparkles.
    private func drawConnected(in context: inout GraphicsContext, center: CGPoint, time: TimeInterval) {
        for ripple in 0..<3 {
            let phase = (time / 2.8 + Double(ripple) / 3).truncatingRemainder(dividingBy: 1)
            context.stroke(
                Self.circle(center, radius: CGFloat(72 + phase * 62)),
                with: .color(AppTheme.iranGreenBright.opacity(0.42 * (1 - phase))),
                lineWidth: CGFloat(1.8 * (1 - phase) + 0.4)
            )
        }

        let halo = Gradient(stops: [
            .init(color: AppTheme.iranGreenBright.opacity(0.95), location: 0),
            .init(color: Color.white.opacity(0.75), location: 0.12),
            .init(color: AppTheme.iranGreenBright.opacity(0.25), location: 0.4),
            .init(color: AppTheme.iranGreen.opacity(0.05), location: 0.7),
            .init(color: AppTheme.iranGreenBright.opacity(0.95), location: 1)
        ])
        context.stroke(
            Self.circle(center, radius: 88),
            with: .conicGradient(halo, center: center, angle: .radians(time * 0.9)),
            lineWidth: 2.6
        )

        for index in 0..<10 {
            let seed = Double(index)
            let angle = seed * 0.628 + time * (index.isMultiple(of: 2) ? 0.35 : -0.25)
            let radius = CGFloat(100 + 8 * sin(time * 0.8 + seed))
            let twinkle = abs(sin(time * 2.2 + seed * 1.7))
            let point = Self.point(center, radius: radius, angle: angle)
            context.fill(
                Self.circle(point, radius: CGFloat(0.8 + 1.4 * twinkle)),
                with: .color(Color.white.opacity(0.25 + 0.65 * twinkle))
            )
        }
    }

    private static let burstDuration: TimeInterval = 1.1

    /// One-shot shockwave and radial particle burst when the tunnel is established.
    private func drawBurst(in context: inout GraphicsContext, center: CGPoint, elapsed: TimeInterval) {
        guard elapsed >= 0, elapsed < Self.burstDuration else { return }
        let progress = elapsed / Self.burstDuration
        let eased = 1 - pow(1 - progress, 3)
        let fade = 1 - progress

        context.stroke(
            Self.circle(center, radius: CGFloat(66 + eased * 92)),
            with: .color(AppTheme.iranGreenBright.opacity(0.9 * fade)),
            lineWidth: CGFloat(5 * fade + 0.5)
        )
        context.stroke(
            Self.circle(center, radius: CGFloat(66 + eased * 64)),
            with: .color(Color.white.opacity(0.7 * fade)),
            lineWidth: CGFloat(2.5 * fade + 0.3)
        )
        for index in 0..<24 {
            let angle = Double(index) / 24 * 2 * .pi + Double(index % 2) * 0.13
            let reach = 66 + eased * (index.isMultiple(of: 3) ? 104 : 82)
            let point = Self.point(center, radius: CGFloat(reach), angle: angle)
            context.fill(
                Self.circle(point, radius: CGFloat(2.8 * fade + 0.4)),
                with: .color((index.isMultiple(of: 2) ? AppTheme.iranGreenBright : Color.white).opacity(fade))
            )
        }
    }

    // MARK: - Disc and glyph

    private func mainDisc(_ time: TimeInterval) -> some View {
        let diameter = Self.discDiameter
        return ZStack {
            Circle()
                .fill(AppTheme.connectGradient(for: status, scheme: colorScheme))

            // Specular sheen that sweeps across the disc while busy, and drifts slowly otherwise.
            Circle()
                .fill(
                    AngularGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0),
                            .init(color: .white.opacity(isBusy ? 0.55 : 0.28), location: 0.08),
                            .init(color: .white.opacity(0.0), location: 0.22),
                            .init(color: .white.opacity(0.0), location: 1)
                        ],
                        center: .center,
                        angle: .radians(time * (isBusy ? 3.2 : 0.5))
                    )
                )
                .blendMode(.overlay)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.22 : 0.35),
                            Color.white.opacity(0.04),
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.overlay)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.06), Color.black.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )

            Circle()
                .strokeBorder(energy.opacity(0.35), lineWidth: 1)
                .padding(9)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: energy.opacity(status == .connected ? 0.6 : 0.45), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }

    private func powerGlyph(_ time: TimeInterval) -> some View {
        let pulse = isBusy ? 0.55 + 0.45 * (sin(time * 5) * 0.5 + 0.5) : 1
        return Image(systemName: "power")
            .font(.system(size: 46, weight: .heavy))
            .foregroundStyle(powerIconGradient)
            .opacity(pulse)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .shadow(color: (status == .connected ? Color.white : energy).opacity(status == .connected ? 0.55 : 0.25), radius: 10)
            .accessibilityHidden(true)
    }

    private var powerIconGradient: LinearGradient {
        switch status {
        case .connected:
            return LinearGradient(colors: [.white, AppTheme.iranWhite.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        case .connecting, .disconnecting:
            return LinearGradient(
                colors: [AppTheme.iranGreen, AppTheme.iranGreenBright],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .error, .disconnected:
            return LinearGradient(colors: [.white, Color.white.opacity(0.88)], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - Geometry helpers

    private static func circle(_ center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func point(_ center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }
}
