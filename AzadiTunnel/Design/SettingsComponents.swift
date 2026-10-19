import SwiftUI

/// Rounded, tinted SF Symbol tile in the style of iOS Settings.
struct SettingsIconTile: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: tint.opacity(0.35), radius: 3, y: 1.5)
            .accessibilityHidden(true)
    }
}

/// Icon tile + title (+ optional subtitle) used as the label of rows, toggles and links.
struct SettingsRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Section header with a small glyph, matching the dashboard's tone.
struct SettingsSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.iranGreenBright)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
        .textCase(nil)
    }
}

/// Supporting copy under a row, kept quieter than the row itself.
struct SettingsFootnote: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tint ?? AppTheme.secondaryText(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared backdrop for the settings stack (same palette as the dashboard map).
struct SettingsSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.03, green: 0.05, blue: 0.09), Color(red: 0.05, green: 0.08, blue: 0.14)]
                    : [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.97, green: 0.98, blue: 0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [AppTheme.iranGreenBright.opacity(colorScheme == .dark ? 0.12 : 0.07), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

/// Grouped-row card background: translucent on the gradient, hairline edge.
struct SettingsRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.78))
            .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.4 : 0.6))
    }
}

/// Identity card at the top of Settings: icon, script wordmark, version and current setup.
struct SettingsHeroCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let protocolName: String
    let regionName: String

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "v\(short)" : "v\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                AppIconImage(size: 58, shadow: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AzadiTunnel")
                        .font(.custom(AppFonts.wordmark, size: 32, relativeTo: .title))
                        .foregroundColor(AppTheme.primaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .background(alignment: .topLeading) {
                            GeometryReader { geometry in
                                PeekingLion(trackWidth: geometry.size.width, startDelay: 0.8)
                                    .offset(y: -PeekingLion.windowHeight + PeekingLion.hideLine)
                            }
                        }
                    Text(version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                }
                .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                pill(icon: "arrow.triangle.branch", text: protocolName)
                pill(icon: "globe", text: regionName)
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                AppTheme.iranGreen
                AppTheme.iranWhite
                AppTheme.iranRed
            }
            .frame(height: 3)
            .clipShape(Capsule())
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.iranGreenBright)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(AppTheme.primaryText(for: colorScheme).opacity(0.07)))
    }
}

extension View {
    /// Hides the default grouped background (iOS 16+) so `SettingsSurface` shows through.
    @ViewBuilder
    func settingsScrollBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
