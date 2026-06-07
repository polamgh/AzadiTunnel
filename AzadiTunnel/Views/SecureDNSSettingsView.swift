import SwiftUI

struct SecureDNSSettingsView: View {
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
                if settings.secureDNSMode != .off {
                    providerSection
                    if settings.secureDNSProvider == .custom {
                        customSection
                    }
                    blockSection
                    testSection
                }
                if let warningText, !warningText.isEmpty {
                    warningSection(warningText)
                }
            }
            .navigationTitle(L10n.t(.secureDnsNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .id(lang.revision)
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
        Section(L10n.t(.secureDnsModeSection)) {
            Picker(L10n.t(.secureDnsModeSection), selection: $settings.secureDNSMode) {
                Text(L10n.t(.secureDnsModeOff)).tag(SecureDNSMode.off)
                Text(L10n.t(.secureDnsModeDoh)).tag(SecureDNSMode.doh)
                Text(L10n.t(.secureDnsModeDot)).tag(SecureDNSMode.dot)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.secureDNSMode) { _ in
                persist("secure_dns_mode")
                Task { await reconnectIfConnected() }
            }
            .accessibilityIdentifier("secureDnsModePicker")
        }
    }

    private var providerSection: some View {
        Section(L10n.t(.secureDnsProviderSection)) {
            Picker(L10n.t(.secureDnsProviderSection), selection: $settings.secureDNSProvider) {
                ForEach(SecureDNSProvider.allCases) { provider in
                    Text(providerLabel(provider)).tag(provider)
                }
            }
            .onChange(of: settings.secureDNSProvider) { _ in
                persist("secure_dns_provider")
                Task { await reconnectIfConnected() }
            }
            .accessibilityIdentifier("secureDnsProviderPicker")
        }
    }

    private var customSection: some View {
        Section {
            if settings.secureDNSMode == .doh {
                TextField(L10n.t(.secureDnsCustomDoHURL), text: $settings.customDoHURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: settings.customDoHURL) { _ in persist("secure_dns_custom_doh") }
            }
            if settings.secureDNSMode == .dot {
                TextField(L10n.t(.secureDnsCustomDoTHost), text: $settings.customDoTHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.customDoTHost) { _ in persist("secure_dns_custom_dot") }
            }
        }
    }

    private var blockSection: some View {
        Section {
            Toggle(L10n.t(.secureDnsBlockCleartext), isOn: $settings.blockCleartextDNS)
                .onChange(of: settings.blockCleartextDNS) { _ in
                    persist("secure_dns_block_cleartext")
                    Task { await reconnectIfConnected() }
                }
                .accessibilityIdentifier("secureDnsBlockCleartextToggle")
            Text(L10n.t(.secureDnsBlockCleartextHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                Text(testRunning ? L10n.t(.secureDnsTestRunning) : L10n.t(.secureDnsTestButton))
            }
            .disabled(testRunning || settings.secureDNSMode == .off)
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

    private func providerLabel(_ provider: SecureDNSProvider) -> String {
        switch provider {
        case .cloudflare: return L10n.t(.secureDnsProviderCloudflare)
        case .google: return L10n.t(.secureDnsProviderGoogle)
        case .quad9: return L10n.t(.secureDnsProviderQuad9)
        case .adguard: return L10n.t(.secureDnsProviderAdguard)
        case .custom: return L10n.t(.secureDnsProviderCustom)
        }
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
        if settings.secureDNSMode == .off {
            SharedSettingsStore.shared.secureDNSWarning = nil
            warningText = nil
        }
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
        guard settings.secureDNSMode != .off else { return }
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
