import SwiftUI

struct SecureDNSSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared

    @State private var settings = SharedSettingsStore.shared.appSettings
    @State private var warningText = SharedSettingsStore.shared.secureDNSWarning
    @State private var testRunning = false
    @State private var testSummary = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastTask: Task<Void, Never>?
    @State private var statusTicker: Task<Void, Never>?

    var body: some View {
        ZStack {
            Form {
                noteSection
                modeSection
                if SecureDNSConfiguration.isActive(settings) {
                    providerSection
                    if settings.secureDNSProvider == .custom {
                        customSection
                    }
                    testSection
                }
                if let warningText, !warningText.isEmpty {
                    warningSection(warningText)
                }
            }
            .navigationTitle(L10n.t(.secureDnsNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .id(lang.revision)
            .accessibilityIdentifier("secureDnsScreen")
            .onAppear {
                refresh()
                startStatusTicker()
            }
            .onDisappear { statusTicker?.cancel() }

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

    private var noteSection: some View {
        Section {
            Text(L10n.t(.secureDnsDefaultOffNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.secureDnsProxyOnlyNote))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if vpn.status == .connected || vpn.status == .connecting {
                Text(L10n.t(.secureDnsReconnectNote))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeSection: some View {
        Section {
            HStack {
                Text(L10n.t(.secureDnsActiveSelection))
                Spacer()
                Text(activeSelectionSummary)
                    .foregroundStyle(AppTheme.accent)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.t(.secureDnsActiveSelection)))
            .accessibilityValue(Text(activeSelectionSummary))

            ForEach(SecureDNSMode.allCases) { mode in
                modeOptionRow(mode)
            }
        } header: {
            Text(L10n.t(.secureDnsModeSection))
        }
        .accessibilityIdentifier("secureDnsModePicker")
    }

    private var providerSection: some View {
        Section {
            ForEach(SecureDNSProvider.allCases) { provider in
                providerOptionRow(provider)
            }
        } header: {
            Text(L10n.t(.secureDnsProviderSection))
        }
        .accessibilityIdentifier("secureDnsProviderPicker")
    }

    private var customSection: some View {
        Section {
            TextField(L10n.t(.secureDnsCustomDoHURL), text: $settings.customDoHURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel(Text(L10n.t(.secureDnsCustomDoHURL)))
                .onChange(of: settings.customDoHURL) { _ in persist("secure_dns_custom_doh") }
        }
    }

    private var testSection: some View {
        Section {
            Text(L10n.t(.secureDnsTestHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .accessibilityHidden(true)
                    Text(testRunning ? L10n.t(.secureDnsTestRunning) : L10n.t(.secureDnsTestButton))
                }
            }
            .disabled(testRunning)
            .accessibilityLabel(Text(testRunning ? L10n.t(.secureDnsTestRunning) : L10n.t(.secureDnsTestButton)))
            .accessibilityHint(Text(L10n.t(.accessibilitySelect)))
            .accessibilityIdentifier("secureDnsTestButton")
            if !testSummary.isEmpty {
                Text(testSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func warningSection(_ text: String) -> some View {
        Section(L10n.t(.secureDnsWarningSection)) {
            Text(text == "blocked" ? L10n.t(.secureDnsBlockedWarning) : text)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var activeSelectionSummary: String {
        if SecureDNSConfiguration.isActive(settings) {
            return "\(modeTitle(settings.secureDNSMode)) · \(providerLabel(settings.secureDNSProvider))"
        }
        return modeTitle(.off)
    }

    private func modeOptionRow(_ mode: SecureDNSMode) -> some View {
        let selected = settings.secureDNSMode == mode
        return Button {
            selectMode(mode)
        } label: {
            HStack(spacing: 14) {
                modeIconBadge(mode, selected: selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(modeTitle(mode))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                    Text(modeDetail(mode))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AppTheme.accent : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(modeTitle(mode)))
        .accessibilityValue(Text(modeDetail(mode) + (selected ? ". " + L10n.t(.accessibilitySelected) : "")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func providerOptionRow(_ provider: SecureDNSProvider) -> some View {
        let selected = settings.secureDNSProvider == provider
        return Button {
            selectProvider(provider)
        } label: {
            HStack(spacing: 14) {
                providerIconBadge(provider, selected: selected)
                Text(providerLabel(provider))
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AppTheme.accent : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(providerLabel(provider)))
        .accessibilityValue(Text(selected ? L10n.t(.accessibilitySelected) : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeIconBadge(_ mode: SecureDNSMode, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    selected
                        ? AppTheme.accent.opacity(colorScheme == .dark ? 0.24 : 0.14)
                        : Color.secondary.opacity(0.12)
                )
                .frame(width: 40, height: 40)
            Image(systemName: modeIconName(mode))
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
        }
    }

    private func providerIconBadge(_ provider: SecureDNSProvider, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    selected
                        ? AppTheme.accent.opacity(colorScheme == .dark ? 0.24 : 0.14)
                        : Color.secondary.opacity(0.12)
                )
                .frame(width: 34, height: 34)
            Image(systemName: providerIconName(provider))
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText(for: colorScheme))
                .accessibilityHidden(true)
        }
    }

    private func modeIconName(_ mode: SecureDNSMode) -> String {
        switch mode {
        case .off: return "power"
        case .doh: return "lock.shield"
        case .dot: return "lock.shield"
        }
    }

    private func providerIconName(_ provider: SecureDNSProvider) -> String {
        switch provider {
        case .cloudflare: return "cloud.fill"
        case .google: return "globe"
        case .quad9: return "9.circle.fill"
        case .adguard: return "shield.lefthalf.filled"
        case .custom: return "slider.horizontal.3"
        }
    }

    private func modeTitle(_ mode: SecureDNSMode) -> String {
        switch mode {
        case .off: return L10n.t(.secureDnsModeOff)
        case .doh: return L10n.t(.secureDnsModeDoh)
        case .dot: return L10n.t(.secureDnsModeDoh)
        }
    }

    private func modeDetail(_ mode: SecureDNSMode) -> String {
        switch mode {
        case .off: return L10n.t(.secureDnsModeOffDetail)
        case .doh: return L10n.t(.secureDnsModeDohDetail)
        case .dot: return L10n.t(.secureDnsModeDohDetail)
        }
    }

    private func providerLabel(_ provider: SecureDNSProvider) -> String {
        switch provider {
        case .cloudflare: return L10n.t(.secureDnsProviderCloudflare)
        case .google: return L10n.t(.secureDnsProviderGoogle)
        case .quad9: return L10n.t(.secureDnsProviderQuad9)
        case .adguard: return L10n.t(.secureDnsProviderAdguard)
        case .custom: return L10n.t(.secureDnsProviderCustom)
        }
    }

    private func selectMode(_ mode: SecureDNSMode) {
        guard settings.secureDNSMode != mode else { return }
        settings.secureDNSMode = mode
        persist("secure_dns_mode")
        Task { await reconnectIfConnected() }
    }

    private func selectProvider(_ provider: SecureDNSProvider) {
        guard settings.secureDNSProvider != provider else { return }
        settings.secureDNSProvider = provider
        persist("secure_dns_provider")
        Task { await reconnectIfConnected() }
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
        SharedSettingsStore.shared.secureDNSWarning = nil
        warningText = nil
    }

    private func refresh() {
        settings = SharedSettingsStore.shared.appSettings
        warningText = SharedSettingsStore.shared.secureDNSWarning
    }

    private func startStatusTicker() {
        statusTicker?.cancel()
        statusTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                warningText = SharedSettingsStore.shared.secureDNSWarning
            }
        }
    }

    private func reconnectIfConnected() async {
        guard vpn.status == .connected || vpn.status == .connecting else { return }
        await vpn.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await vpn.connect()
        refresh()
    }

    private func runTest() async {
        guard vpn.status == .connected else {
            testSummary = L10n.t(.secureDnsTestConnectFirst)
            presentToast(L10n.t(.secureDnsTestConnectFirst))
            return
        }

        testRunning = true
        defer { testRunning = false }

        let response = await vpn.sendProviderMessage("secure-dns:test")
        if let response, response.hasPrefix("ok:") {
            testSummary = response
            presentToast(L10n.t(.secureDnsTestOk))
        } else {
            testSummary = response ?? L10n.t(.secureDnsTestFailed)
            presentToast(L10n.t(.secureDnsTestFailed))
        }
        warningText = SharedSettingsStore.shared.secureDNSWarning
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
