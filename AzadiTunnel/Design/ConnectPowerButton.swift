import SwiftUI

struct ConnectPowerButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: VPNStatusDisplay
    let isEnabled: Bool
    let action: () -> Void

    @State private var pressed = false

    private var accent: Color {
        AppTheme.statusColor(for: status, scheme: colorScheme)
    }

    private var isBusy: Bool {
        status == .connecting || status == .disconnecting
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) { pressed = true }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { pressed = false }
            }
        } label: {
            ZStack {
                ambientGlow

                if status == .connected {
                    connectedPulseRings
                } else if status == .disconnected {
                    idlePulseRing
                }

                if isBusy {
                    busySpinner
                }

                outerOrbitRing
                mainDisc
                powerGlyph
            }
            .frame(width: 220, height: 220)
            .scaleEffect(pressed ? 0.93 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .accessibilityIdentifier("connectButton")
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: status)
    }

    // MARK: - Layers

    private var ambientGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [accent.opacity(0.38), accent.opacity(0.08), .clear],
                    center: .center,
                    startRadius: 24,
                    endRadius: 118
                )
            )
            .frame(width: 220, height: 220)
            .blur(radius: 6)
    }

    private var connectedPulseRings: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = sin(t * 2.4) * 0.5 + 0.5

            ZStack {
                Circle()
                    .stroke(AppTheme.iranGreenBright.opacity(0.22 + wave * 0.28), lineWidth: 2.5)
                    .frame(width: 196, height: 196)
                    .scaleEffect(0.94 + wave * 0.1)

                Circle()
                    .stroke(AppTheme.iranWhite.opacity(0.12 + wave * 0.18), lineWidth: 1.5)
                    .frame(width: 176, height: 176)
                    .scaleEffect(0.97 + wave * 0.06)
            }
        }
    }

    private var idlePulseRing: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = sin(t * 1.6) * 0.5 + 0.5

            Circle()
                .stroke(accent.opacity(0.14 + wave * 0.22), lineWidth: 2)
                .frame(width: 188, height: 188)
                .scaleEffect(0.96 + wave * 0.05)
        }
    }

    private var busySpinner: some View {
        TimelineView(.animation(minimumInterval: 1 / 45)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t.truncatingRemainder(dividingBy: 1.05) / 1.05) * 360)

            ZStack {
                Circle()
                    .trim(from: 0.02, to: 0.28)
                    .stroke(
                        AppTheme.iranGreenBright.opacity(0.85),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(angle)

                Circle()
                    .trim(from: 0.38, to: 0.52)
                    .stroke(
                        AppTheme.iranGreen.opacity(0.55),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(angle + .degrees(140))
            }
            .frame(width: 158, height: 158)
        }
    }

    private var outerOrbitRing: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: ringColors,
                    center: .center
                ),
                lineWidth: 3
            )
            .frame(width: 152, height: 152)
            .shadow(color: accent.opacity(0.25), radius: 8, y: 4)
    }

    private var ringColors: [Color] {
        switch status {
        case .connected:
            return [
                AppTheme.iranGreenBright,
                AppTheme.iranWhite.opacity(0.7),
                AppTheme.iranGreen,
                AppTheme.iranGreenBright
            ]
        case .connecting, .disconnecting:
            return [
                Color.white.opacity(0.85),
                AppTheme.iranGreen.opacity(0.6),
                Color.white.opacity(0.5),
                Color.white.opacity(0.85)
            ]
        case .error:
            return [AppTheme.iranRed, AppTheme.iranRedDeep, AppTheme.iranRed, AppTheme.iranRedDeep]
        case .disconnected:
            return [
                AppTheme.iranRed.opacity(0.95),
                AppTheme.iranWhite.opacity(0.45),
                AppTheme.iranRedDeep,
                AppTheme.iranRed.opacity(0.95)
            ]
        }
    }

    private var mainDisc: some View {
        ZStack {
            Circle()
                .fill(AppTheme.connectGradient(for: status, scheme: colorScheme))
                .frame(width: 132, height: 132)

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
                .frame(width: 132, height: 132)
                .blendMode(.overlay)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 132, height: 132)

            Circle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12))
                .frame(width: 92, height: 92)
                .blur(radius: 18)
                .offset(y: 22)
                .mask(
                    Circle()
                        .frame(width: 132, height: 132)
                )
        }
        .shadow(color: accent.opacity(0.55), radius: 20, y: 12)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }

    private var powerGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(isBusy ? 0.08 : 0.14))
                .frame(width: 54, height: 54)
                .blur(radius: 1)

            Image(systemName: "power")
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(powerIconGradient)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .shadow(color: accent.opacity(status == .connected ? 0.45 : 0.2), radius: 8)
        }
    }

    private var powerIconGradient: LinearGradient {
        switch status {
        case .connected:
            return LinearGradient(
                colors: [.white, AppTheme.iranWhite.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .connecting, .disconnecting:
            return LinearGradient(
                colors: [AppTheme.iranGreen, AppTheme.iranGreenBright],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .error, .disconnected:
            return LinearGradient(
                colors: [.white, Color.white.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
