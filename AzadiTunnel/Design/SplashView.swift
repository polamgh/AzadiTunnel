import SwiftUI

struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onFinished: () -> Void

    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
            StarfieldView()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                AppIconImage(size: 96)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Text("AzadiTunnel")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    .opacity(logoOpacity)

                Text(L10n.t(.splashTagline))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .opacity(logoOpacity * 0.9)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                logoScale = 1
                logoOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation(.easeIn(duration: 0.35)) {
                    logoOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    onFinished()
                }
            }
        }
    }
}
