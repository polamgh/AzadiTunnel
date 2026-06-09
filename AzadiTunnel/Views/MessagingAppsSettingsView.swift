import SwiftUI

struct MessagingAppsSettingsView: View {
    @ObservedObject private var lang = AppLanguageController.shared
    @State private var settings = SharedSettingsStore.shared.appSettings

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t(.messagingCompatToggle), isOn: $settings.messagingAppsCompatibilityModeEnabled)
                    .onChange(of: settings.messagingAppsCompatibilityModeEnabled) { _ in
                        persist("messaging_compat_enabled")
                    }
                    .accessibilityIdentifier("messagingCompatToggle")
                Text(L10n.t(.messagingCompatDescription))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if settings.messagingAppsCompatibilityModeEnabled {
                Section(L10n.t(.messagingCompatMtuSection)) {
                    Picker(L10n.t(.messagingCompatMtu), selection: $settings.messagingAppsTunnelMTU) {
                        ForEach(MessagingTunnelMTU.allCases) { mtu in
                            Text(mtu.displayName).tag(mtu)
                        }
                    }
                    .onChange(of: settings.messagingAppsTunnelMTU) { _ in
                        persist("messaging_compat_mtu")
                    }
                    Text(L10n.t(.messagingCompatMtuHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t(.messagingCompatFeaturesSection)) {
                    Label(L10n.t(.messagingCompatFeatureBypass), systemImage: "arrow.triangle.branch")
                    Label(L10n.t(.messagingCompatFeatureDns), systemImage: "lock.shield")
                    Label(L10n.t(.messagingCompatFeatureFallback), systemImage: "arrow.triangle.2.circlepath")
                    Label(L10n.t(.messagingCompatFeatureUdpNote), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                Section {
                    Text(L10n.t(.messagingCompatReconnectNote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.t(.messagingCompatNavTitle))
        .id(lang.revision)
        .onAppear {
            settings = SharedSettingsStore.shared.appSettings
        }
    }

    private func persist(_ key: String) {
        SharedSettingsStore.shared.updateAppSettings(settings, logKey: key)
    }
}
