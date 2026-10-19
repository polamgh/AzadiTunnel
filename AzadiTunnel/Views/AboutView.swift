import StoreKit
import SwiftUI
import UIKit

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var lang = AppLanguageController.shared
    @State private var appeared = false

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
            VStack(spacing: 22) {
                hero
                    .modifier(AboutAppear(index: 0, appeared: appeared))
                infoTiles
                    .modifier(AboutAppear(index: 1, appeared: appeared))
                noticeCard
                    .modifier(AboutAppear(index: 2, appeared: appeared))
                contactGrid
                    .modifier(AboutAppear(index: 3, appeared: appeared))
                projectLinks
                    .modifier(AboutAppear(index: 4, appeared: appeared))
                legalLinks
                    .modifier(AboutAppear(index: 5, appeared: appeared))
                footer
                    .modifier(AboutAppear(index: 6, appeared: appeared))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background(SettingsSurface())
        .navigationTitle(L10n.t(.aboutNavTitle))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aboutAzadiTunnelScreen")
        .id(lang.revision)
        .onAppear {
            SharedLogger.shared.logRaw("ABOUT_PAGE_OPENED", detail: "version=\(version) build=\(build)")
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                AboutHalo(animated: !reduceMotion)
                    .frame(width: 150, height: 150)
                AppIconImage(size: 96)
                    .shadow(color: AppTheme.iranGreenBright.opacity(0.35), radius: 20, y: 8)
            }
            .padding(.top, 6)

            Text("AzadiTunnel")
                .font(.custom(AppFonts.wordmark, size: 44, relativeTo: .largeTitle))
                .foregroundColor(AppTheme.primaryText(for: colorScheme))
                .padding(.horizontal, 6)
                .background(alignment: .topLeading) {
                    GeometryReader { geometry in
                        PeekingLion(trackWidth: geometry.size.width, startDelay: 1.0)
                            .offset(y: -PeekingLion.windowHeight + PeekingLion.hideLine + 6)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)

            Text("v\(version) (\(build))")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(AppTheme.primaryText(for: colorScheme).opacity(0.07)))

            Text(L10n.t(.aboutMission))
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            HStack(spacing: 0) {
                AppTheme.iranGreen
                AppTheme.iranWhite
                AppTheme.iranRed
            }
            .frame(width: 120, height: 3)
            .clipShape(Capsule())
            .environment(\.layoutDirection, .leftToRight)
            .padding(.top, 6)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Info

    private var infoTiles: some View {
        HStack(spacing: 10) {
            AboutInfoTile(icon: "person.fill", tint: .blue, label: L10n.t(.aboutDeveloperLabel), value: L10n.t(.aboutDeveloperValue))
            AboutInfoTile(icon: "app.badge.fill", tint: AppTheme.iranGreen, label: L10n.t(.aboutAppVersionLabel), value: version)
            AboutInfoTile(icon: "cpu", tint: .orange, label: L10n.t(.aboutCoreVersionLabel), value: L10n.t(.aboutCoreVersionValue))
        }
    }

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            noticeRow(icon: "checkmark.shield.fill", tint: AppTheme.iranGreen, text: L10n.t(.aboutResponsibleUse))
            Divider().overlay(AppTheme.cardStroke(for: colorScheme))
            noticeRow(icon: "chevron.left.forwardslash.chevron.right", tint: .indigo, text: L10n.t(.aboutOpenSourceAck))
        }
        .padding(16)
        .background(AboutCardBackground())
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconTile(systemName: icon, tint: tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Links

    private var contactGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Button {
                requestAppReview()
            } label: {
                AboutLinkTile(icon: "star.fill", tint: Color(red: 1.0, green: 0.74, blue: 0.16), title: L10n.t(.aboutRateUs))
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))

            Button {
                openURL(AboutLinks.companyWebsite)
            } label: {
                AboutLinkTile(icon: "building.2.fill", tint: .blue, title: L10n.t(.aboutCompanyWebsite))
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))

            Button {
                openURL(AboutLinks.xProfile)
            } label: {
                AboutLinkTile(icon: "at", tint: Color(red: 0.2, green: 0.2, blue: 0.24), title: L10n.t(.aboutX))
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))

            Button {
                openURL(AboutLinks.contactEmail)
            } label: {
                AboutLinkTile(icon: "envelope.fill", tint: AppTheme.iranGreen, title: L10n.t(.aboutContactUs))
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
        }
    }

    private var projectLinks: some View {
        VStack(spacing: 0) {
            Button {
                openURL(AboutLinks.psiphonWebsite)
            } label: {
                AboutRow(icon: "safari.fill", tint: .blue, title: L10n.t(.aboutWebsite), external: true)
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
            rowDivider
            Button {
                openURL(AboutLinks.psiphonGitHub)
            } label: {
                AboutRow(icon: "link", tint: .gray, title: L10n.t(.aboutPsiphonGitHub), external: true)
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
        }
        .background(AboutCardBackground())
    }

    private var legalLinks: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PrivacyNoticeView()
            } label: {
                AboutRow(icon: "hand.raised.fill", tint: .purple, title: L10n.t(.privacyNoticeTitle), external: false)
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
            rowDivider
            NavigationLink {
                LegalOpenSourceView()
            } label: {
                AboutRow(icon: "doc.text.fill", tint: .orange, title: L10n.t(.legalOpenSourceTitle), external: false)
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
            rowDivider
            NavigationLink {
                SupportAzadiTunnelView()
            } label: {
                AboutRow(icon: "heart.fill", tint: AppTheme.iranRed, title: L10n.t(.settingsSupport), external: false)
            }
            .buttonStyle(AboutPressStyle())
            .accessibilityHint(Text(L10n.t(.accessibilityOpen)))
        }
        .background(AboutCardBackground())
    }

    private var rowDivider: some View {
        Divider()
            .overlay(AppTheme.cardStroke(for: colorScheme))
            .padding(.leading, 58)
    }

    private var footer: some View {
        Text(copyrightText)
            .font(.caption)
            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
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

/// Flag-colored ring that slowly turns around the app icon.
private struct AboutHalo: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let time = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.iranGreenBright.opacity(0.22), .clear],
                            center: .center,
                            startRadius: 30,
                            endRadius: 80
                        )
                    )
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                AppTheme.iranGreenBright,
                                AppTheme.iranWhite.opacity(0.9),
                                AppTheme.iranRed,
                                AppTheme.iranGreenBright.opacity(0.1),
                                AppTheme.iranGreenBright
                            ],
                            center: .center,
                            angle: .radians(time * 0.6)
                        ),
                        lineWidth: 2.5
                    )
                    .padding(14)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AboutCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1)
            )
    }
}

private struct AboutInfoTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsIconTile(systemName: icon, tint: tint)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(AboutCardBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}

private struct AboutLinkTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(systemName: icon, tint: tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(AboutCardBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

private struct AboutRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let title: String
    let external: Bool

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: icon, tint: tint)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            Spacer(minLength: 8)
            Image(systemName: external ? "arrow.up.forward" : "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

private struct AboutPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct AboutAppear: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.06), value: appeared)
    }
}
