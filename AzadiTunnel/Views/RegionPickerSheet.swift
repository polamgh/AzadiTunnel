import SwiftUI

/// Exit-country picker: searchable, grouped by continent, with "Automatic (best)" featured.
struct RegionPickerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let selectedCode: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var pendingCode: String?
    @State private var appeared = false

    private struct RegionGroup: Identifiable {
        let id: String
        let title: String
        let codes: [String]
    }

    private var locale: Locale { AppLanguageController.shared.locale }

    /// Continent buckets for every exposed region; anything unknown falls into "Other".
    private var groups: [RegionGroup] {
        let continent: [String: String] = [
            "US": "americas", "CA": "americas", "BR": "americas",
            "GB": "europe", "DE": "europe", "FR": "europe", "NL": "europe", "CH": "europe", "SE": "europe",
            "JP": "asia", "SG": "asia", "IN": "asia", "AE": "asia", "IR": "asia"
        ]
        let order: [(String, String)] = [
            ("europe", L10n.t(.regionGroupEurope)),
            ("americas", L10n.t(.regionGroupAmericas)),
            ("asia", L10n.t(.regionGroupAsia)),
            ("other", L10n.t(.regionGroupOther))
        ]
        let visible = PsiphonRegionList.all.filter(matchesQuery)
        return order.compactMap { key, title in
            let codes = visible
                .filter { (continent[$0] ?? "other") == key }
                .sorted { name(for: $0) < name(for: $1) }
            return codes.isEmpty ? nil : RegionGroup(id: key, title: title, codes: codes)
        }
    }

    private var currentCode: String { pendingCode ?? selectedCode }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if query.isEmpty {
                        bestCard
                            .modifier(StaggeredAppear(index: 0, appeared: appeared))
                    }
                    if groups.isEmpty {
                        Text(L10n.t(.regionNoResults))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(Array(group.codes.enumerated()), id: \.element) { index, code in
                                    countryCard(code)
                                        .modifier(StaggeredAppear(index: groupIndex * 4 + index + 1, appeared: appeared))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .background(surface.ignoresSafeArea())
        .modifier(RegionSheetPresentation())
        .accessibilityIdentifier("dashboardRegionPickerSheet")
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
    }

    // MARK: - Pieces

    private var surface: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.05, green: 0.07, blue: 0.12), Color(red: 0.03, green: 0.05, blue: 0.09)]
                : [Color(red: 0.96, green: 0.97, blue: 0.98), Color(red: 0.92, green: 0.94, blue: 0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var header: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(AppTheme.secondaryText(for: colorScheme).opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(.settingsEgressRegion))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(L10n.t(.regionPickerSubtitle))
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AppTheme.primaryText(for: colorScheme).opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t(.cancel)))
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
            TextField(L10n.t(.regionSearch), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            if !query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t(.cancel)))
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.primaryText(for: colorScheme).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.cardStroke(for: colorScheme).opacity(0.6), lineWidth: 1)
        )
    }

    private var bestCard: some View {
        let selected = currentCode.isEmpty
        return Button {
            choose("")
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [AppTheme.iranGreenBright, AppTheme.iranGreen],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .shadow(color: AppTheme.iranGreenBright.opacity(0.45), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t(.regionAny))
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(L10n.t(.regionBestSubtitle))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                selectionMark(selected)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(selected: selected, radius: 20))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func countryCard(_ code: String) -> some View {
        let selected = currentCode == code
        return Button {
            choose(code)
        } label: {
            HStack(spacing: 10) {
                Text(RegionDisplayNames.flagEmoji(for: code))
                    .font(.system(size: 26))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AppTheme.primaryText(for: colorScheme).opacity(0.06)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(for: code))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(code)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(selected ? AppTheme.iranGreenBright : AppTheme.secondaryText(for: colorScheme))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(selected: selected, radius: 18))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white, AppTheme.iranGreenBright)
                        .padding(7)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name(for: code)))
        .accessibilityValue(Text(selected ? L10n.t(.accessibilitySelected) : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func cardBackground(selected: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected
                  ? AppTheme.iranGreenBright.opacity(colorScheme == .dark ? 0.16 : 0.10)
                  : AppTheme.primaryText(for: colorScheme).opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        selected ? AppTheme.iranGreenBright : AppTheme.cardStroke(for: colorScheme).opacity(0.5),
                        lineWidth: selected ? 1.6 : 1
                    )
            )
            .shadow(color: selected ? AppTheme.iranGreenBright.opacity(0.25) : .clear, radius: 10, y: 4)
    }

    private func selectionMark(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? AppTheme.iranGreenBright : AppTheme.cardStroke(for: colorScheme), lineWidth: 1.5)
                .frame(width: 24, height: 24)
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AppTheme.iranGreenBright))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Behavior

    private func name(for code: String) -> String {
        RegionDisplayNames.countryName(for: code, locale: locale)
    }

    private func matchesQuery(_ code: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let english = RegionDisplayNames.countryName(for: code, locale: Locale(identifier: "en"))
        return [code, name(for: code), english].contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// Show the selection land, then hand it back and close.
    private func choose(_ code: String) {
        HapticFeedback.light()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { pendingCode = code }
        onSelect(code)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { dismiss() }
    }
}

/// Cards sink slightly while pressed.
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Cards rise into place one after another when the sheet opens.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(index) * 0.035), value: appeared)
    }
}

/// Large detent with a rounded, hidden-indicator presentation where available.
private struct RegionSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(32)
        } else if #available(iOS 16.0, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        } else {
            content
        }
    }
}
