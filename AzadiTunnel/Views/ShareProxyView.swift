import SwiftUI
import Network
import UIKit

/// Dedicated page for the "Share Proxy on Local Network" feature.
///
/// Lets the user expose AzadiTunnel's HTTP/SOCKS5 local proxies to other devices on the
/// same Wi-Fi. The listeners themselves live in the packet-tunnel extension
/// (see ``LANProxyBridge``); this view persists user choices, observes the runtime status
/// the extension publishes through ``SharedSettingsStore``, and asks the extension to
/// start / stop / re-bind via `NETunnelProviderSession.sendProviderMessage`.
struct ShareProxyView: View {
    @ObservedObject private var lang = AppLanguageController.shared
    @ObservedObject private var vpn = VPNController.shared

    @State private var settings = SharedSettingsStore.shared.appSettings
    @State private var wifiIP: String? = LocalNetworkAddress.wifiIPv4()
    @State private var runtimeStatus: LANProxyRuntimeStatus = SharedSettingsStore.shared.lanProxyRuntimeStatus
    @State private var boundHost: String? = SharedSettingsStore.shared.lanProxyBoundHost
    @State private var activeHttpPort: Int = SharedSettingsStore.shared.lanProxyActiveHttpPort
    @State private var activeSocksPort: Int = SharedSettingsStore.shared.lanProxyActiveSocksPort

    @State private var httpPortText: String = "\(SharedSettingsStore.shared.appSettings.lanHttpProxyPort)"
    @State private var socksPortText: String = "\(SharedSettingsStore.shared.appSettings.lanSocksProxyPort)"
    @State private var portValidationError: String?
    @State private var statusTicker: Task<Void, Never>?
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastTask: Task<Void, Never>?

    private var minPort: Int { 1024 }
    private var maxPort: Int { 65535 }

    var body: some View {
        ZStack {
            Form {
                toggleSection
                statusSection
                proxyAddressSection
                portsSection
                authSection
                instructionsSection
                securitySection
            }
            .navigationTitle(L10n.t(.shareProxyNavTitle))
            .navigationBarTitleDisplayMode(.inline)
            .id(lang.revision)
            .onAppear {
                SharedLogger.shared.log(.lanProxySettingOpened)
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

    // MARK: - Sections

    private var toggleSection: some View {
        Section {
            Toggle(L10n.t(.shareProxyEnableTitle), isOn: Binding(
                get: { settings.shareProxyOnLocalNetworkEnabled },
                set: { newValue in
                    settings.shareProxyOnLocalNetworkEnabled = newValue
                    persist("share_proxy_enabled")
                    Task { await applyToggleChange(newValue) }
                }
            ))
            .accessibilityIdentifier("shareProxyToggle")
            Text(L10n.t(.shareProxyEnableDescription))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.t(.shareProxyTrustedNetworkWarning))
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var statusSection: some View {
        Section(L10n.t(.shareProxyStatusSection)) {
            HStack {
                Text(L10n.t(.status))
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            HStack {
                Text(L10n.t(.shareProxyWifiIP))
                Spacer()
                Text(displayHostOrPlaceholder)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wifiIPValue")
            }
            if wifiIP == nil {
                Text(L10n.t(.shareProxyNoWifiHint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var proxyAddressSection: some View {
        Section(L10n.t(.shareProxyAddressSection)) {
            addressRow(
                title: L10n.t(.shareProxyHttpAddressTitle),
                host: displayHost,
                port: activeHttpPort > 0 ? activeHttpPort : settings.lanHttpProxyPort,
                isAvailable: isProxyReachable
            )
            addressRow(
                title: L10n.t(.shareProxySocksAddressTitle),
                host: displayHost,
                port: activeSocksPort > 0 ? activeSocksPort : settings.lanSocksProxyPort,
                isAvailable: isProxyReachable
            )
        }
    }

    private var portsSection: some View {
        Section(L10n.t(.shareProxyPortsSection)) {
            HStack {
                Text(L10n.t(.shareProxyHttpPort))
                Spacer()
                TextField("8087", text: $httpPortText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .accessibilityIdentifier("lanHttpPortField")
            }
            HStack {
                Text(L10n.t(.shareProxySocksPort))
                Spacer()
                TextField("1088", text: $socksPortText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .accessibilityIdentifier("lanSocksPortField")
            }
            if let portValidationError {
                Text(portValidationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(L10n.t(.shareProxySavePorts)) {
                Task { await savePorts() }
            }
            .accessibilityIdentifier("savePortsButton")
            Text(L10n.t(.shareProxyPortHint))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var authSection: some View {
        Section(L10n.t(.shareProxyAuthSection)) {
            Toggle(L10n.t(.shareProxyAuthToggle), isOn: Binding(
                get: { settings.lanProxyAuthEnabled },
                set: { newValue in
                    settings.lanProxyAuthEnabled = newValue
                    persist("lan_proxy_auth_enabled")
                    SharedLogger.shared.log(newValue ? .lanProxyAuthEnabled : .lanProxyAuthDisabled)
                }
            ))
            .disabled(true)
            if settings.lanProxyAuthEnabled {
                TextField(L10n.t(.shareProxyUsername), text: $settings.lanProxyUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: settings.lanProxyUsername) { _ in persist("lan_proxy_username") }
                SecureField(L10n.t(.shareProxyPassword), text: $settings.lanProxyPassword)
                    .onChange(of: settings.lanProxyPassword) { _ in persist("lan_proxy_password") }
            }
            Text(L10n.t(.shareProxyNoAuthWarning))
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var instructionsSection: some View {
        Section(L10n.t(.shareProxyInstructionsSection)) {
            DisclosureGroup(L10n.t(.shareProxyHowToiPhone)) {
                Text(L10n.t(.shareProxyInstructionsiPhone))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.t(.shareProxyHowToAndroid)) {
                Text(L10n.t(.shareProxyInstructionsAndroid))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.t(.shareProxyHowToWindows)) {
                Text(L10n.t(.shareProxyInstructionsWindows))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.t(.shareProxyHowToAndroidTV)) {
                Text(L10n.t(.shareProxyInstructionsAndroidTV))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.t(.shareProxySocksNoteTitle)) {
                Text(L10n.t(.shareProxySocksNoteBody))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var securitySection: some View {
        Section(L10n.t(.shareProxySecuritySection)) {
            Text(L10n.t(.shareProxySecurityWarning))
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private func addressRow(title: String, host: String?, port: Int, isAvailable: Bool) -> some View {
        let value = host.map { "\($0):\(port)" } ?? L10n.t(.shareProxyAddressUnavailable)
        return HStack {
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
            .disabled(!isAvailable)
            .accessibilityLabel(L10n.t(.copy))
        }
    }

    private var displayHost: String? {
        if let boundHost, !boundHost.isEmpty { return boundHost }
        return wifiIP
    }

    private var displayHostOrPlaceholder: String {
        displayHost ?? L10n.t(.shareProxyNoWifiIP)
    }

    private var isProxyReachable: Bool {
        runtimeStatus == .running && displayHost != nil
    }

    private var statusText: String {
        switch runtimeStatus {
        case .running: return L10n.t(.shareProxyStatusRunning)
        case .stopped: return L10n.t(.shareProxyStatusStopped)
        case .vpnDisconnected: return L10n.t(.shareProxyStatusVpnDisconnected)
        case .noWifiIP: return L10n.t(.shareProxyStatusNoWifi)
        case .portInUse: return L10n.t(.shareProxyStatusPortInUse)
        case .failedToStart: return L10n.t(.shareProxyStatusFailed)
        }
    }

    private var statusColor: Color {
        switch runtimeStatus {
        case .running: return .green
        case .stopped, .vpnDisconnected: return .secondary
        case .noWifiIP, .portInUse, .failedToStart: return .red
        }
    }

    // MARK: - Actions

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
    }

    private func refreshAll() {
        settings = SharedSettingsStore.shared.appSettings
        httpPortText = "\(settings.lanHttpProxyPort)"
        socksPortText = "\(settings.lanSocksProxyPort)"
        wifiIP = LocalNetworkAddress.wifiIPv4()
        readRuntime()
    }

    private func readRuntime() {
        let store = SharedSettingsStore.shared
        runtimeStatus = store.lanProxyRuntimeStatus
        boundHost = store.lanProxyBoundHost
        activeHttpPort = store.lanProxyActiveHttpPort
        activeSocksPort = store.lanProxyActiveSocksPort
        // If the toggle is off, runtime stays stopped regardless of stale store values.
        if !settings.shareProxyOnLocalNetworkEnabled, runtimeStatus == .running {
            runtimeStatus = .stopped
        }
        // If VPN is down, surface that to the user even if no extension message arrived.
        if vpn.status != .connected, settings.shareProxyOnLocalNetworkEnabled {
            runtimeStatus = .vpnDisconnected
        }
    }

    private func startStatusTicker() {
        statusTicker?.cancel()
        statusTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                wifiIP = LocalNetworkAddress.wifiIPv4()
                readRuntime()
            }
        }
    }

    private func applyToggleChange(_ enabled: Bool) async {
        if enabled {
            if vpn.status == .connected {
                _ = await vpn.sendProviderMessage("lan-proxy:start")
            } else {
                runtimeStatus = .vpnDisconnected
            }
        } else {
            _ = await vpn.sendProviderMessage("lan-proxy:stop")
            runtimeStatus = .stopped
        }
        readRuntime()
    }

    private func savePorts() async {
        portValidationError = nil
        guard let httpPort = Int(httpPortText), (minPort...maxPort).contains(httpPort) else {
            portValidationError = L10n.t(.shareProxyPortOutOfRange)
            return
        }
        guard let socksPort = Int(socksPortText), (minPort...maxPort).contains(socksPort) else {
            portValidationError = L10n.t(.shareProxyPortOutOfRange)
            return
        }
        guard httpPort != socksPort else {
            portValidationError = L10n.t(.shareProxyPortsMustDiffer)
            return
        }

        let changed = settings.lanHttpProxyPort != httpPort || settings.lanSocksProxyPort != socksPort
        settings.lanHttpProxyPort = httpPort
        settings.lanSocksProxyPort = socksPort
        persist("lan_ports")
        if changed {
            SharedLogger.shared.log(.lanProxyPortsChanged, detail: "http=\(httpPort) socks=\(socksPort)")
        }
        presentToast(L10n.t(.shareProxyPortsSaved))

        if settings.shareProxyOnLocalNetworkEnabled, vpn.status == .connected {
            _ = await vpn.sendProviderMessage("lan-proxy:restart")
        }
        readRuntime()
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
