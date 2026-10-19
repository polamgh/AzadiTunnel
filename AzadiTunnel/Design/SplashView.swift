import SwiftUI

/// Launch sequence in the dashboard's visual language: the dotted world fades in, the
/// icon springs up inside a flag-colored halo, the script wordmark writes itself, the
/// flag rule grows from the center, the lion takes one peek, then everything lifts away.
struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinished: () -> Void

    @State private var mapVisible = false
    @State private var iconVisible = false
    @State private var haloProgress: CGFloat = 0
    @State private var writeProgress: CGFloat = 0
    @State private var ruleProgress: CGFloat = 0
    @State private var taglineVisible = false
    @State private var loaderVisible = false
    @State private var exiting = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            VPNWorldMapBackground(
                originCoordinate: nil,
                destinationCoordinate: nil,
                originCountryCode: nil,
                destinationCountryCode: nil,
                isConnected: false
            )
            .frame(height: 300)
            .scaleEffect(mapVisible ? 1 : 1.12)
            .opacity(mapVisible ? 0.75 : 0)
            .offset(y: -40)

            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    halo
                    AppIconImage(size: 104)
                        .scaleEffect(iconVisible ? 1 : 0.4)
                        .opacity(iconVisible ? 1 : 0)
                        .shadow(color: AppTheme.iranGreenBright.opacity(iconVisible ? 0.45 : 0), radius: 24, y: 8)
                }
                .frame(width: 200, height: 200)

                wordmark
                    .padding(.top, 6)

                flagRule
                    .padding(.top, 10)

                Text(L10n.t(.splashTagline))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 16)
                    .opacity(taglineVisible ? 1 : 0)
                    .offset(y: taglineVisible ? 0 : 10)
                Spacer()
                loader
                    .opacity(loaderVisible ? 1 : 0)
                    .padding(.bottom, 54)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("AzadiTunnel. \(L10n.t(.splashTagline))"))
        }
        .scaleEffect(exiting ? 1.08 : 1)
        .opacity(exiting ? 0 : 1)
        .accessibilityIdentifier("splashScreen")
        .task { await play() }
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.03, green: 0.05, blue: 0.09), Color(red: 0.05, green: 0.08, blue: 0.14)]
                    : [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.97, green: 0.98, blue: 0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [AppTheme.iranGreenBright.opacity(colorScheme == .dark ? 0.18 : 0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 10,
                endRadius: 380
            )
            .opacity(iconVisible ? 1 : 0)
        }
    }

    /// Flag-colored ring that sweeps open around the icon, then softly glows.
    private var halo: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: haloProgress)
                .stroke(
                    AngularGradient(
                        colors: [
                            AppTheme.iranGreenBright,
                            AppTheme.iranWhite,
                            AppTheme.iranRed,
                            AppTheme.iranGreenBright
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 156, height: 156)
            Circle()
                .stroke(AppTheme.iranGreenBright.opacity(0.18 * Double(haloProgress)), lineWidth: 14)
                .frame(width: 156, height: 156)
                .blur(radius: 10)
        }
        .scaleEffect(0.85 + 0.15 * haloProgress)
    }

    /// The script wordmark is revealed left to right like a pen stroke.
    private var wordmark: some View {
        Text("AzadiTunnel")
            .font(.custom(AppFonts.wordmark, size: 46, relativeTo: .largeTitle))
            .foregroundColor(AppTheme.primaryText(for: colorScheme))
            .padding(.horizontal, 4)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: min(1, max(0, writeProgress - 0.04))),
                        .init(color: .clear, location: min(1, writeProgress + 0.04))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .background(alignment: .topLeading) {
                GeometryReader { geometry in
                    PeekingLion(trackWidth: geometry.size.width, startDelay: 1.35, repeats: false, maxSpots: 1)
                        .offset(y: -PeekingLion.windowHeight + PeekingLion.hideLine + 6)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
    }

    /// Green · white · red rule that grows outward from the center.
    private var flagRule: some View {
        HStack(spacing: 0) {
            AppTheme.iranGreen
            AppTheme.iranWhite
            AppTheme.iranRed
        }
        .frame(width: 150, height: 3)
        .clipShape(Capsule())
        .scaleEffect(x: ruleProgress, y: 1, anchor: .center)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    /// Three flag-colored dots bouncing in sequence.
    private var loader: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !loaderVisible)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 9) {
                ForEach(Array([AppTheme.iranGreenBright, AppTheme.iranWhite, AppTheme.iranRed].enumerated()), id: \.offset) { index, color in
                    let phase = (time * 1.6 - Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
                    let lift = max(0, sin(phase * 2 * .pi))
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black.opacity(color == AppTheme.iranWhite ? 0.15 : 0), lineWidth: 0.5))
                        .offset(y: -7 * lift)
                        .opacity(0.55 + 0.45 * lift)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Timeline

    private func play() async {
        if reduceMotion {
            mapVisible = true
            iconVisible = true
            haloProgress = 1
            writeProgress = 1
            ruleProgress = 1
            taglineVisible = true
            try? await TaskSleep.seconds(1.2)
            onFinished()
            return
        }

        withAnimation(.easeOut(duration: 1.6)) { mapVisible = true }
        try? await TaskSleep.seconds(0.1)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { iconVisible = true }
        withAnimation(.easeInOut(duration: 0.9)) { haloProgress = 1 }
        try? await TaskSleep.seconds(0.35)
        withAnimation(.easeInOut(duration: 0.95)) { writeProgress = 1.05 }
        try? await TaskSleep.seconds(0.6)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { ruleProgress = 1 }
        try? await TaskSleep.seconds(0.2)
        withAnimation(.easeOut(duration: 0.5)) { taglineVisible = true }
        withAnimation(.easeIn(duration: 0.3).delay(0.2)) { loaderVisible = true }
        try? await TaskSleep.seconds(1.75)
        withAnimation(.easeIn(duration: 0.4)) { exiting = true }
        try? await TaskSleep.seconds(0.42)
        onFinished()
    }
}
