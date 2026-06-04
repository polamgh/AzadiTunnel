import StoreKit
import SwiftUI
import UIKit

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ObservedObject private var lang = AppLanguageController.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var copyrightText: String {
        let year = Calendar.current.component(.year, from: Date())
        return String(format: L10n.t(.aboutCopyright), year)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.t(.aboutScreenTitle))
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))

                GlassCard(elevated: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        brandingHeader
                        infoRows
                        actionButtons
                        Text(copyrightText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aboutAzadiTunnelScreen")
        .id(lang.revision)
        .onAppear {
            SharedLogger.shared.logRaw("ABOUT_PAGE_OPENED", detail: "version=\(version) build=\(build)")
        }
    }

    private var brandingHeader: some View {
        HStack(spacing: 14) {
            AppIconImage(size: 56, shadow: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("AzadiTunnel")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                Text(L10n.t(.aboutMission))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t(.aboutResponsibleUse))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t(.aboutOpenSourceAck))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var infoRows: some View {
        VStack(spacing: 12) {
            AboutInfoRow(
                label: L10n.t(.aboutDeveloperLabel),
                value: L10n.t(.aboutDeveloperValue),
                colorScheme: colorScheme
            )
            AboutInfoRow(
                label: L10n.t(.aboutAppVersionLabel),
                value: "\(version) (\(build))",
                colorScheme: colorScheme
            )
            AboutInfoRow(
                label: L10n.t(.aboutCoreVersionLabel),
                value: L10n.t(.aboutCoreVersionValue),
                colorScheme: colorScheme
            )
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                requestAppReview()
            } label: {
                AboutActionRow(
                    icon: "star.fill",
                    iconColor: Color(red: 1.0, green: 0.78, blue: 0.2),
                    title: L10n.t(.aboutRateUs),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            Button {
                openURL(AboutLinks.companyWebsite)
            } label: {
                AboutActionRow(
                    icon: "building.2.fill",
                    iconColor: Color(red: 0.22, green: 0.48, blue: 0.95),
                    title: L10n.t(.aboutCompanyWebsite),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            Button {
                openURL(AboutLinks.xProfile)
            } label: {
                AboutActionRow(
                    icon: "at",
                    iconColor: Color(red: 0.12, green: 0.12, blue: 0.14),
                    title: L10n.t(.aboutX),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            Button {
                openURL(AboutLinks.contactEmail)
            } label: {
                AboutActionRow(
                    icon: "envelope.fill",
                    iconColor: Color(red: 0.28, green: 0.78, blue: 0.45),
                    title: L10n.t(.aboutContactUs),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            Button {
                openURL(AboutLinks.psiphonWebsite)
            } label: {
                AboutActionRow(
                    icon: "safari.fill",
                    iconColor: Color(red: 0.25, green: 0.55, blue: 1.0),
                    title: L10n.t(.aboutWebsite),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            Button {
                openURL(AboutLinks.psiphonGitHub)
            } label: {
                AboutActionRow(
                    icon: "link",
                    iconColor: Color(red: 0.35, green: 0.35, blue: 0.42),
                    title: L10n.t(.aboutPsiphonGitHub),
                    trailing: .external,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                PrivacyNoticeView()
            } label: {
                AboutActionRow(
                    icon: "hand.raised.fill",
                    iconColor: Color(red: 0.62, green: 0.42, blue: 0.95),
                    title: L10n.t(.privacyNoticeTitle),
                    trailing: .chevron,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                LegalOpenSourceView()
            } label: {
                AboutActionRow(
                    icon: "doc.text.fill",
                    iconColor: Color(red: 1.0, green: 0.55, blue: 0.25),
                    title: L10n.t(.legalOpenSourceTitle),
                    trailing: .chevron,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                SupportAzadiTunnelView()
            } label: {
                AboutActionRow(
                    icon: "envelope.fill",
                    iconColor: Color(red: 0.28, green: 0.78, blue: 0.45),
                    title: L10n.t(.settingsSupport),
                    trailing: .chevron,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func requestAppReview() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        SKStoreReviewController.requestReview(in: scene)
    }
}

private enum AboutLinks {
    static let companyWebsite = URL(string: "https://debugsy.com")!
    static let xProfile = URL(string: "https://x.com/alighanavatidev")!
    static let contactEmail = URL(string: "mailto:alighanavati@debugsy.com")!
    static let psiphonWebsite = URL(string: "https://psiphon.ca")!
    static let psiphonGitHub = URL(string: "https://github.com/psiphon-inc")!
}

private struct AboutInfoRow: View {
    let label: String
    let value: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct AboutActionRow: View {
    enum TrailingStyle {
        case chevron
        case external
    }

    let icon: String
    let iconColor: Color
    let title: String
    let trailing: TrailingStyle
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconColor)
                )

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))

            Spacer(minLength: 8)

            Image(systemName: trailing == .external ? "arrow.up.forward" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AboutActionRow.buttonFill(for: colorScheme))
        )
    }

    private static func buttonFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)
    }
}
