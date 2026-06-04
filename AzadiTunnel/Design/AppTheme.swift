import SwiftUI

/// Iran flag palette — green, white, red — with light and dark variants.
enum AppTheme {
    static let iranGreen = Color(red: 0.12, green: 0.60, blue: 0.22)
    static let iranGreenBright = Color(red: 0.18, green: 0.72, blue: 0.32)
    static let iranRed = Color(red: 0.82, green: 0.12, blue: 0.18)
    static let iranRedDeep = Color(red: 0.62, green: 0.08, blue: 0.14)
    static let iranWhite = Color(red: 0.98, green: 0.98, blue: 0.99)

    static let accent = iranGreenBright
    static let accentWarm = iranRed
    static let success = iranGreenBright
    static let danger = iranRed

    /// Orbiting accents in the shared starfield background.
    static let starAccentPrimary = Color(red: 0.62, green: 0.42, blue: 0.95)
    static let starAccentSecondary = Color(red: 0.88, green: 0.45, blue: 0.78)

    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        switch scheme {
        case .dark:
            return LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.04, blue: 0.16),
                    Color(red: 0.12, green: 0.06, blue: 0.24),
                    Color(red: 0.10, green: 0.05, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.94, blue: 1.0),
                    Color(red: 0.92, green: 0.86, blue: 0.99),
                    Color(red: 0.96, green: 0.91, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static func meshGlow(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? starAccentPrimary.opacity(0.28)
            : Color(red: 0.55, green: 0.35, blue: 0.85).opacity(0.16)
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.72)
    }

    static func cardFillElevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.92)
    }

    static func cardStroke(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : iranGreen.opacity(0.22)
    }

    static func primaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(red: 0.12, green: 0.16, blue: 0.14)
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.62) : Color(red: 0.28, green: 0.34, blue: 0.32)
    }

    static func statusColor(for status: VPNStatusDisplay, scheme: ColorScheme) -> Color {
        switch status {
        case .connected: return success
        case .connecting, .disconnecting: return scheme == .dark ? iranWhite.opacity(0.9) : iranRedDeep
        case .error: return danger
        case .disconnected:
            return scheme == .dark ? Color.white.opacity(0.5) : Color(red: 0.45, green: 0.50, blue: 0.48)
        }
    }

    static func connectGradient(for status: VPNStatusDisplay, scheme: ColorScheme) -> LinearGradient {
        switch status {
        case .connected:
            return LinearGradient(
                colors: [iranGreenBright, iranGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .connecting, .disconnecting:
            return LinearGradient(
                colors: [iranWhite.opacity(0.95), Color(red: 0.75, green: 0.78, blue: 0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .error:
            return LinearGradient(
                colors: [iranRed, iranRedDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .disconnected:
            if scheme == .dark {
                return LinearGradient(
                    colors: [iranRed.opacity(0.85), iranRedDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [iranRed, iranRedDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Thin Iran-flag stripe accent.
struct IranFlagStripe: View {
    var body: some View {
        HStack(spacing: 0) {
            AppTheme.iranGreen
            AppTheme.iranWhite
            AppTheme.iranRed
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var elevated = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(elevated
                        ? AppTheme.cardFillElevated(for: colorScheme)
                        : AppTheme.cardFill(for: colorScheme))
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.35 : 0.55))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.cardStroke(for: colorScheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 12, y: 6)
    }
}
