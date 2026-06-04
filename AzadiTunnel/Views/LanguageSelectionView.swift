import SwiftUI

/// Shown once on first install before splash and onboarding.
struct LanguageSelectionView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                AppIconImage(size: 80, shadow: false)
                VStack(spacing: 10) {
                    Text("AzadiTunnel")
                        .font(.title.bold())
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text("Choose your language")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text("زبان خود را انتخاب کنید")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    languageButton(
                        title: "English",
                        subtitle: "Left-to-right interface",
                        language: .english,
                        identifier: "language_picker_english"
                    )
                    languageButton(
                        title: "فارسی",
                        subtitle: "رابط راست‌به‌چپ",
                        language: .persian,
                        identifier: "language_picker_persian"
                    )
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 40)
            }
        }
        .accessibilityIdentifier("languageSelectionScreen")
    }

    private func languageButton(
        title: String,
        subtitle: String,
        language: AppSettings.AppLanguage,
        identifier: String
    ) -> some View {
        Button {
            choose(language)
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.cardFillElevated(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.cardStroke(for: colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func choose(_ language: AppSettings.AppLanguage) {
        var settings = SharedSettingsStore.shared.appSettings
        settings.preferredLanguage = language
        settings.hasChosenLanguage = true
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: "language_picker")
        AppLanguageController.shared.reload()
        SharedLogger.shared.logRaw("LANGUAGE_CHOSEN", detail: "lang=\(language.rawValue)")
        onFinish()
    }
}
