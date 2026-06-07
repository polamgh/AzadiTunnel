import SwiftUI

/// Dedicated page for the "Bypass Iranian IPs" feature.
///
/// Lets the user route Iranian destination IPs (plus custom IP/CIDR entries and resolved domains)
/// directly through the device's normal network instead of the VPN. The actual routing happens in
/// the packet-tunnel extension via `NEIPv4Settings.excludedRoutes` (see
/// ``PacketTunnelProvider``); this view manages the cached list, custom entries, and domain
/// resolution, all persisted in App Group storage.
struct BypassIranView: View {
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared

    @State private var settings = SharedSettingsStore.shared.appSettings
    @State private var customText = SharedSettingsStore.shared.appSettings.bypassCustomRoutes
    @State private var domainText = SharedSettingsStore.shared.appSettings.bypassDomains

    @State private var listCount = SharedSettingsStore.shared.effectiveBypassIranListCount
    @State private var usingBundledList = SharedSettingsStore.shared.bypassIranListIsBundledFallback
    @State private var listUpdatedAt = SharedSettingsStore.shared.bypassIranListUpdatedAt
    @State private var routesApplied = SharedSettingsStore.shared.bypassRoutesAppliedCount

    @State private var isUpdating = false
    @State private var isResolving = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Form {
                toggleSection
                statusSection
                customSection
                domainSection
                applySection
                strictSection
                noteSection
            }
            .navigationTitle(L10n.t(.bypassNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .id(lang.revision)
            .onAppear {
                refresh()
                // Pull a fresh list on first open (throttled) so the count/date populate.
                Task { await updateList(force: false, silent: true) }
            }

            if showToast {
                VStack {
                    Spacer()
                    AppToastBanner(message: toastMessage)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.3), value: showToast)
    }

    // MARK: - Sections

    private var toggleSection: some View {
        Section {
            Toggle(L10n.t(.bypassEnableTitle), isOn: Binding(
                get: { settings.bypassIranIPsEnabled },
                set: { newValue in
                    settings.bypassIranIPsEnabled = newValue
                    persist("bypass_iran_enabled")
                    SharedLogger.shared.log(newValue ? .bypassIranEnabled : .bypassIranDisabled)
                    if newValue {
                        Task { await updateList(force: false, silent: true) }
                    }
                    Task { await reconnectIfConnected() }
                }
            ))
            .accessibilityIdentifier("bypassIranToggle")
            Text(L10n.t(.bypassEnableDescription))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if settings.bypassIranIPsEnabled {
                Text(L10n.t(.bypassBestEffortWarning))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusSection: some View {
        Section(L10n.t(.bypassStatusSection)) {
            HStack {
                Text(L10n.t(.bypassListCount))
                Spacer()
                Text("\(listCount)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bypassListCount")
            }
            HStack {
                Text(L10n.t(.bypassListUpdated))
                Spacer()
                Text(updatedText)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.t(.bypassRoutesApplied))
                Spacer()
                Text("\(routesApplied)")
                    .foregroundStyle(.secondary)
            }
            // Warning per requirement: bypass ON but no usable list at all → VPN stays normal.
            if settings.bypassIranIPsEnabled && listCount == 0 {
                Text(L10n.t(.bypassNoListWarning))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("bypassNoListWarning")
            } else if usingBundledList {
                Text(L10n.t(.bypassListSourceBundled))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await updateList(force: true, silent: false) }
            } label: {
                HStack {
                    Text(isUpdating ? L10n.t(.bypassUpdating) : L10n.t(.bypassUpdateListNow))
                    if isUpdating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isUpdating)
            .accessibilityIdentifier("bypassUpdateListButton")
        }
    }

    private var customSection: some View {
        Section(L10n.t(.bypassCustomSection)) {
            TextEditor(text: $customText)
                .frame(minHeight: 90)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bypassCustomEditor")
            Text(L10n.t(.bypassCustomHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var domainSection: some View {
        Section(L10n.t(.bypassDomainSection)) {
            TextEditor(text: $domainText)
                .frame(minHeight: 70)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bypassDomainEditor")
            Text(L10n.t(.bypassDomainHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await resolveDomains() }
            } label: {
                HStack {
                    Text(isResolving ? L10n.t(.bypassResolving) : L10n.t(.bypassResolveNow))
                    if isResolving {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isResolving)
            Text(L10n.t(.bypassDomainWarning))
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var applySection: some View {
        Section {
            Button(L10n.t(.bypassSaveApply)) {
                Task { await saveAndApply() }
            }
            .accessibilityIdentifier("bypassSaveButton")
        }
    }

    private var strictSection: some View {
        Section(L10n.t(.bypassStrictSection)) {
            Toggle(L10n.t(.bypassStrictToggle), isOn: Binding(
                get: { settings.bypassStrictModeEnabled },
                set: { newValue in
                    settings.bypassStrictModeEnabled = newValue
                    persist("bypass_strict_mode")
                    Task { await reconnectIfConnected() }
                }
            ))
            .accessibilityIdentifier("bypassStrictToggle")
            Text(L10n.t(.bypassStrictDescription))
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var noteSection: some View {
        Section {
            Text(L10n.t(.bypassEffectiveNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.bypassReconnectNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var updatedText: String {
        guard let date = listUpdatedAt else { return L10n.t(.bypassNever) }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = lang.locale
        return formatter.string(from: date)
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
    }

    private func refresh() {
        settings = SharedSettingsStore.shared.appSettings
        listCount = SharedSettingsStore.shared.effectiveBypassIranListCount
        usingBundledList = SharedSettingsStore.shared.bypassIranListIsBundledFallback
        listUpdatedAt = SharedSettingsStore.shared.bypassIranListUpdatedAt
        routesApplied = SharedSettingsStore.shared.bypassRoutesAppliedCount
    }

    @MainActor
    private func updateList(force: Bool, silent: Bool) async {
        if isUpdating { return }
        isUpdating = true
        defer { isUpdating = false }
        let result = await IranBypassListService.refresh(force: force)
        refresh()
        if silent { return }
        switch result {
        case .updated, .skippedFresh:
            presentToast(L10n.t(.bypassListUpdatedToast))
        case .usedCache, .failedNoCache:
            // Remote sources failed; we kept the cached or bundled list.
            presentToast(L10n.t(.bypassListFailedToast))
        }
    }

    @MainActor
    private func resolveDomains() async {
        if isResolving { return }
        // Persist the edited domains first so the resolver reads the latest text.
        settings.bypassDomains = domainText
        persist("bypass_domains")
        isResolving = true
        defer { isResolving = false }
        let domains = BypassRoutes.tokenize(domainText)
        _ = await BypassDomainResolver.resolveAndCache(domains: domains)
        presentToast(L10n.t(.bypassSavedToast))
    }

    @MainActor
    private func saveAndApply() async {
        settings.bypassCustomRoutes = customText
        settings.bypassDomains = domainText
        persist("bypass_lists")
        presentToast(L10n.t(.bypassSavedToast))
        if !BypassRoutes.tokenize(domainText).isEmpty {
            _ = await BypassDomainResolver.resolveAndCache(domains: BypassRoutes.tokenize(domainText))
        }
        await reconnectIfConnected()
        refresh()
    }

    private func reconnectIfConnected() async {
        guard vpn.status == .connected || vpn.status == .connecting else { return }
        await vpn.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await vpn.connect()
    }

    private func presentToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        showToast = true
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { showToast = false }
        }
    }
}
