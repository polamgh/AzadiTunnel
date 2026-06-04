import SwiftUI
import StoreKit

struct SupportAzadiTunnelView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = SupportStoreManager.shared
    @ObservedObject private var lang = AppLanguageController.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader

                if store.isLoading {
                    loadingCard
                } else if store.productsUnavailable {
                    unavailableCard
                } else {
                    tipsSection
                    subscriptionsSection
                    legalFooter
                }

                restoreFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AppTheme.backgroundGradient(for: colorScheme).ignoresSafeArea())
        .navigationTitle(L10n.t(.settingsSupport))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("supportAzadiTunnelScreen")
        .id(lang.revision)
        .task { await store.loadProductsIfNeeded() }
    }

    // MARK: - Header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppIconImage(size: 52, shadow: false)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t(.settingsSupport))
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(L10n.t(.supportIntro))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.iranGreen)
                Text(L10n.t(.supportFreeBadge))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.iranGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.iranGreen.opacity(0.35), lineWidth: 1)
            )

            if store.purchaseState != .notPurchased && store.purchaseState != .unknown {
                statusPill
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.caption.weight(.bold))
            Text(store.purchaseState.localizedLabel)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.12))
        )
    }

    private var statusIcon: String {
        switch store.purchaseState {
        case .subscribed, .purchased: return "heart.fill"
        case .expired: return "clock.badge.exclamationmark"
        default: return "heart"
        }
    }

    private var statusTint: Color {
        switch store.purchaseState {
        case .subscribed, .purchased: return AppTheme.iranGreen
        case .expired: return AppTheme.iranRed
        default: return AppTheme.secondaryText(for: colorScheme)
        }
    }

    // MARK: - States

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                ProgressView()
                Text(L10n.t(.supportLoading))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    private var unavailableCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "heart.slash")
                    .font(.title2)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                Text(store.loadError ?? L10n.t(.supportUnavailable))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Products

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.t(.supportTipsSection), icon: "gift.fill")

            GlassCard(elevated: true) {
                VStack(spacing: 10) {
                    tipRow(id: IAPProductIDs.tipSmall, style: .small)
                    divider
                    tipRow(id: IAPProductIDs.tipMedium, style: .medium)
                    divider
                    tipRow(id: IAPProductIDs.tipLarge, style: .large)
                }
            }
        }
    }

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.t(.supportSubscriptionsSection), icon: "sparkles")

            VStack(spacing: 10) {
                subscriptionRow(id: IAPProductIDs.supportYearly, highlight: true)
                subscriptionRow(id: IAPProductIDs.supportMonthly, highlight: false)
            }
        }
    }

    private var legalFooter: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t(.supportSubscriptionDisclaimer))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    legalLinkRow(title: L10n.t(.supportManageSubscriptions), icon: "creditcard")
                }

                NavigationLink {
                    PrivacyNoticeView()
                } label: {
                    legalLinkRow(title: L10n.t(.privacyNoticeTitle), icon: "hand.raised.fill")
                }
            }
        }
    }

    private var restoreFooter: some View {
        VStack(spacing: 8) {
            Button {
                Task { await store.restorePurchases() }
            } label: {
                Text(L10n.t(.supportRestore))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private func tipRow(id: String, style: SupportTipStyle) -> some View {
        if let product = store.products.first(where: { $0.id == id }) {
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: style.gradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: style.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(product.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        if !product.description.isEmpty {
                            Text(product.description)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(product.displayPrice)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(style.priceCapsule(for: colorScheme))
                        )
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iap_product_\(id)")
        }
    }

    @ViewBuilder
    private func subscriptionRow(id: String, highlight: Bool) -> some View {
        if let product = store.products.first(where: { $0.id == id }) {
            Button {
                Task { await store.purchase(product) }
            } label: {
                GlassCard(elevated: highlight) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: highlight
                                            ? [AppTheme.starAccentPrimary, AppTheme.starAccentSecondary]
                                            : [AppTheme.iranGreen.opacity(0.85), AppTheme.iranGreenBright],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 46, height: 46)
                            Image(systemName: highlight ? "crown.fill" : "arrow.triangle.2.circlepath")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(product.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText(for: colorScheme))

                            if !product.description.isEmpty {
                                Text(product.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(product.displayPrice)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                            .padding(.top, 4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iap_product_\(id)")
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(AppTheme.primaryText(for: colorScheme))
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.cardStroke(for: colorScheme))
            .frame(height: 1)
    }

    private func legalLinkRow(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
        }
    }
}

// MARK: - Tip styling (visual only — prices come from StoreKit)

private enum SupportTipStyle {
    case small, medium, large

    var icon: String {
        switch self {
        case .small: return "cup.and.saucer.fill"
        case .medium: return "heart.fill"
        case .large: return "star.fill"
        }
    }

    var gradient: [Color] {
        switch self {
        case .small:
            return [Color(red: 0.35, green: 0.72, blue: 0.95), Color(red: 0.22, green: 0.52, blue: 0.88)]
        case .medium:
            return [Color(red: 0.62, green: 0.42, blue: 0.95), Color(red: 0.45, green: 0.28, blue: 0.82)]
        case .large:
            return [Color(red: 0.98, green: 0.62, blue: 0.22), Color(red: 0.92, green: 0.38, blue: 0.18)]
        }
    }

    func priceCapsule(for scheme: ColorScheme) -> Color {
        switch self {
        case .small: return Color(red: 0.22, green: 0.52, blue: 0.88).opacity(scheme == .dark ? 0.95 : 1)
        case .medium: return Color(red: 0.45, green: 0.28, blue: 0.82).opacity(scheme == .dark ? 0.95 : 1)
        case .large: return Color(red: 0.92, green: 0.38, blue: 0.18).opacity(scheme == .dark ? 0.95 : 1)
        }
    }
}
