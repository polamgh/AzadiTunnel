import SwiftUI

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            usesAppLogo: true,
            titleKey: .onboardingWelcomeTitle,
            bodyKey: .onboardingWelcomeBody
        ),
        OnboardingPage(
            icon: "lock.shield",
            titleKey: .onboardingPrivacyTitle,
            bodyKey: .onboardingPrivacyBody
        ),
        OnboardingPage(
            icon: "network",
            titleKey: .onboardingTransportTitle,
            bodyKey: .onboardingTransportBody
        ),
        OnboardingPage(
            icon: "arrow.triangle.branch",
            titleKey: .onboardingFallbackTitle,
            bodyKey: .onboardingFallbackBody
        ),
        OnboardingPage(
            icon: "heart.fill",
            titleKey: .onboardingSupportTitle,
            bodyKey: .onboardingSupportBody
        )
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 24) {
                            if item.usesAppLogo {
                                AppIconImage(size: 72)
                                    .padding(.top, 40)
                            } else if let icon = item.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 56))
                                    .foregroundStyle(AppTheme.iranGreen)
                                    .padding(.top, 40)
                            }
                            Text(L10n.t(item.titleKey))
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                            Text(L10n.t(item.bodyKey))
                                .font(.body)
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(action: advance) {
                    Text(page == pages.count - 1 ? L10n.t(.onboardingGetStarted) : L10n.t(.onboardingContinue))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.iranGreen)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .accessibilityIdentifier("onboarding_continue_button")
            }
            .background(AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea())
            .navigationTitle(L10n.t(.onboardingNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if page > 0 {
                        Button(L10n.t(.onboardingSkip)) { finish() }
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    }
                }
            }
        }
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation { page += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        var settings = SharedSettingsStore.shared.appSettings
        settings.hasCompletedOnboarding = true
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: "onboarding_complete")
        SharedLogger.shared.logRaw("ONBOARDING_COMPLETED", detail: "pages=\(pages.count)")
        onFinish()
    }
}

private struct OnboardingPage {
    var icon: String? = nil
    var usesAppLogo = false
    let titleKey: AppLanguageController.L10nKey
    let bodyKey: AppLanguageController.L10nKey
}
