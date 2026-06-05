import SwiftUI

struct ContentView: View {
    @ObservedObject private var lang = AppLanguageController.shared

    var body: some View {
        TabView {
            NavigationView {
                DashboardView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label(L10n.t(.tabVPN), systemImage: "shield.lefthalf.filled")
                    .accessibilityIdentifier("vpnTab")
            }

            SettingsView()
                .accessibilityIdentifier("settingsRootScreen")
                .tabItem {
                    Label(L10n.t(.tabSettings), systemImage: "gearshape")
                        .accessibilityIdentifier("settingsTabBar")
                }
        }
        .id(lang.revision)
        .environment(\.locale, lang.locale)
        .environment(\.layoutDirection, lang.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .onAppear { runUITestHooksIfNeeded() }
    }

    private func runUITestHooksIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestExportDebugReport") {
            _ = DebugReportExporter.buildReport()
        }
        if args.contains("-UITestLoadIAPProducts") {
            Task { await SupportStoreManager.shared.loadProductsIfNeeded() }
        }
    }
}

#Preview {
    ContentView()
}
