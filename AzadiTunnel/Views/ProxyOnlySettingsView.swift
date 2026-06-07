import SwiftUI
import UIKit

/// Settings detail for Proxy Only mode — local HTTP/SOCKS listeners without full-device routing.
struct ProxyOnlySettingsView: View {
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared

    @State private var settings = SharedSettingsStore.shared.appSettings
    @State private var wifiIP: String? = LocalNetworkAddress.wifiIPv4()
    @State private var boundHost: String? = SharedSettingsStore.shared.lanProxyBoundHost
    @State private var runtimeStatus: LANProxyRuntimeStatus = SharedSettingsStore.shared.lanProxyRuntimeStatus
    @State private var activeHttpPort: Int = SharedSettingsStore.shared.lanProxyActiveHttpPort
    @State private var activeSocksPort: Int = SharedSettingsStore.shared.lanProxyActiveSocksPort
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastTask: Task<Void, Never>?
    @State private var statusTicker: Task<Void, Never>?
    @State private var selfTestRunning = false
    @State private var selfTestSummary = ""

    var body: some View {
        ZStack {
            Form {
                toggleSection
                modeSection
                sameDeviceSection
                if settings.shareProxyOnLocalNetworkEnabled {
                    lanAddressSection
                }
                selfTestSection
                warningSection
                instructionsSection
            }
            .navigationTitle(L10n.t(.proxyOnlyNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .id(lang.revision)
            .onAppear {
                refreshAll()
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

    private var toggleSection: some View {
        Section {
            Toggle(L10n.t(.proxyOnlyEnableTitle), isOn: Binding(
                get: { settings.proxyOnlyModeEnabled },
                set: { newValue in
                    settings.proxyOnlyModeEnabled = newValue
                    persist("proxy_only_mode")
                    SharedLogger.shared.log(newValue ? .proxyOnlyModeEnabled : .proxyOnlyModeDisabled)
                    if newValue {
                        SharedLogger.shared.log(.proxyOnlyWarningNotFullVPN)
                    }
                    Task { await applyToggleChange() }
                }
            ))
            .accessibilityIdentifier("proxyOnlyToggle")
            Text(L10n.t(.proxyOnlyEnableDescription))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.proxyOnlyWarningShort))
                .font(.footnote)
                .foregroundStyle(.orange)
            if vpn.status == .connected || vpn.status == .connecting {
                Text(L10n.t(.proxyOnlyReconnectHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeSection: some View {
        Section(L10n.t(.proxyOnlyModeSection)) {
            HStack {
                Text(L10n.t(.status))
                Spacer()
                Text(currentModeLabel)
                    .foregroundStyle(settings.proxyOnlyModeEnabled ? .orange : .primary)
            }
            .accessibilityIdentifier("proxyOnlyModeLabel")
        }
    }

    private var sameDeviceSection: some View {
        Section(L10n.t(.proxyOnlySameDeviceAddresses)) {
            if settings.proxyOnlyModeEnabled, !wifiAvailable {
                Text(L10n.t(.proxyOnlyNotAvailableOnCellular))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Text(L10n.t(.proxyOnlyLoopbackNotReachable))
                .font(.footnote)
                .foregroundStyle(.orange)
            if let host = sameDeviceHost, wifiAvailable {
                addressRow(
                    title: L10n.t(.shareProxyHttpAddressTitle),
                    value: "\(host):\(httpPort)",
                    enabled: addressCardsEnabled
                )
                addressRow(
                    title: L10n.t(.shareProxySocksAddressTitle),
                    value: "\(host):\(socksPort)",
                    enabled: addressCardsEnabled
                )
            } else if settings.proxyOnlyModeEnabled {
                addressRow(
                    title: L10n.t(.shareProxyHttpAddressTitle),
                    value: "—",
                    enabled: false
                )
                addressRow(
                    title: L10n.t(.shareProxySocksAddressTitle),
                    value: "—",
                    enabled: false
                )
                Text(L10n.t(.proxyOnlyNoWifiSameDevice))
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text(L10n.t(.proxyOnlyNoWifiSameDevice))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var lanAddressSection: some View {
        Section(L10n.t(.proxyOnlyLanAddresses)) {
            if let host = sameDeviceHost {
                Text(L10n.t(.shareProxyEnableDescription))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                addressRow(
                    title: L10n.t(.shareProxyHttpAddressTitle),
                    value: "\(host):\(httpPort)",
                    enabled: isProxyLive
                )
                addressRow(
                    title: L10n.t(.shareProxySocksAddressTitle),
                    value: "\(host):\(socksPort)",
                    enabled: isProxyLive
                )
            } else {
                Text(L10n.t(.shareProxyNoWifiHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selfTestSection: some View {
        Section(L10n.t(.proxyOnlySocksSelfTestTitle)) {
            Button {
                Task { await runSocksSelfTest() }
            } label: {
                if selfTestRunning {
                    Text(L10n.t(.proxyOnlySocksSelfTestRunning))
                } else {
                    Text(L10n.t(.proxyOnlySocksSelfTestButton))
                }
            }
            .disabled(selfTestRunning || vpn.status != .connected || !wifiAvailable)
            .accessibilityIdentifier("proxyOnlySocksSelfTestButton")
            if !selfTestSummary.isEmpty {
                Text(selfTestSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var warningSection: some View {
        Section {
            Text(L10n.t(.proxyOnlyWarningFull))
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var instructionsSection: some View {
        Section {
            Text(L10n.t(.proxyOnlyConfiguredAppsHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.proxyOnlyTelegramHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                ShareProxyView()
            } label: {
                Text(L10n.t(.shareProxyNavTitle))
            }
            .accessibilityIdentifier("proxyOnlyShareProxyLink")
        }
    }

    private func addressRow(title: String, value: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = value
                presentToast(L10n.t(.copiedToClipboard))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel(L10n.t(.copy))
        }
    }

    private var sameDeviceHost: String? {
        SameDeviceProxyAddress.reachableHost(boundHost: boundHost) ?? wifiIP
    }

    private var currentModeLabel: String {
        if vpn.status == .connected, vpn.statistics.proxyOnlyModeActive || settings.proxyOnlyModeEnabled {
            return L10n.t(.proxyOnlyModeProxyOnly)
        }
        if settings.proxyOnlyModeEnabled {
            return L10n.t(.proxyOnlyModeProxyOnly)
        }
        return L10n.t(.proxyOnlyModeFullVPN)
    }

    private var httpPort: Int {
        activeHttpPort > 0 ? activeHttpPort : settings.lanHttpProxyPort
    }

    private var socksPort: Int {
        activeSocksPort > 0 ? activeSocksPort : settings.lanSocksProxyPort
    }

    private var wifiAvailable: Bool {
        wifiIP != nil
    }

    private var addressCardsEnabled: Bool {
        isProxyLive && wifiAvailable
    }

    private var isProxyLive: Bool {
        settings.proxyOnlyModeEnabled
            && vpn.status == .connected
            && runtimeStatus == .running
            && sameDeviceHost != nil
            && wifiAvailable
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
    }

    private func refreshAll() {
        settings = SharedSettingsStore.shared.appSettings
        wifiIP = LocalNetworkAddress.wifiIPv4()
        boundHost = SharedSettingsStore.shared.lanProxyBoundHost
        runtimeStatus = SharedSettingsStore.shared.lanProxyRuntimeStatus
        activeHttpPort = SharedSettingsStore.shared.lanProxyActiveHttpPort
        activeSocksPort = SharedSettingsStore.shared.lanProxyActiveSocksPort
    }

    private func startStatusTicker() {
        statusTicker?.cancel()
        statusTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                wifiIP = LocalNetworkAddress.wifiIPv4()
                boundHost = SharedSettingsStore.shared.lanProxyBoundHost
                runtimeStatus = SharedSettingsStore.shared.lanProxyRuntimeStatus
                activeHttpPort = SharedSettingsStore.shared.lanProxyActiveHttpPort
                activeSocksPort = SharedSettingsStore.shared.lanProxyActiveSocksPort
            }
        }
    }

    private func runSocksSelfTest() async {
        guard vpn.status == .connected else { return }
        selfTestRunning = true
        defer { selfTestRunning = false }

        let port = socksPort

        guard let wifi = sameDeviceHost else {
            selfTestSummary = L10n.t(.proxyOnlySocksSelfTestNoWifi)
            presentToast(L10n.t(.proxyOnlySocksSelfTestNoWifi))
            return
        }

        let wifiResult = await ProxyOnlySocksSelfTest.probe(host: wifi, port: port)
        SharedLogger.shared.log(.proxyOnlySocksSelfTestWifi, detail: wifiResult.logDetail)
        if wifiResult.handshakeOK {
            SharedLogger.shared.log(.proxyOnlySocksHandshakeOk, detail: "source=app_self_test_wifi")
        } else {
            SharedLogger.shared.log(.proxyOnlySocksHandshakeFailed, detail: "source=app_self_test_wifi \(wifiResult.logDetail)")
        }

        selfTestSummary = "\(wifi):\(port) — \(wifiResult.userMessage)"
        presentToast(
            wifiResult.handshakeOK
                ? L10n.t(.proxyOnlySocksSelfTestWifiOK)
                : L10n.t(.proxyOnlySocksSelfTestWifiFailed)
        )

        // Internal diagnostics only — not shown in the main UI result.
        let loopback = await ProxyOnlySocksSelfTest.probe(host: "127.0.0.1", port: port)
        SharedLogger.shared.log(.proxyOnlySocksSelfTestLoopback, detail: loopback.logDetail)
        _ = await vpn.sendProviderMessage("proxy-only:socks-self-test")
    }

    private func applyToggleChange() async {
        guard vpn.status == .connected || vpn.status == .connecting else { return }
        await vpn.disconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await vpn.connect()
        refreshAll()
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
