import SwiftUI
import UIKit

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
                    .accessibilityLabel(Text(L10n.t(.tabVPN)))
                    .accessibilityIdentifier("vpnTab")
            }

            SettingsView()
                .accessibilityIdentifier("settingsRootScreen")
                .tabItem {
                    Label(L10n.t(.tabSettings), systemImage: "gearshape")
                        .accessibilityLabel(Text(L10n.t(.tabSettings)))
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

/// SwiftUI does not expose a view modifier for UIKit's accessibilityLanguage
/// attribute. Keep the platform accessibility elements in sync with the
/// selected in-app language so VoiceOver uses the matching speech language.
struct AccessibilityLanguageBridge: UIViewRepresentable {
    let language: String

    func makeUIView(context: Context) -> LanguageApplyingView {
        LanguageApplyingView(language: language)
    }

    func updateUIView(_ uiView: LanguageApplyingView, context: Context) {
        uiView.language = language
        uiView.scheduleScan()
    }
}

final class LanguageApplyingView: UIView {
    var language: String {
        didSet {
            guard oldValue != language else { return }
            scheduleScan()
        }
    }

    private var scanScheduled = false
    private var observers: [NSObjectProtocol] = []

    init(language: String) {
        self.language = language
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIWindow.didBecomeKeyNotification,
            UIAccessibility.elementFocusedNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleScan()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleScan()
    }

    func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.applyLanguageToWindow()
        }
    }

    private func applyLanguageToWindow() {
        guard let window else { return }
        applyLanguage(to: window)
    }

    private func applyLanguage(to view: UIView) {
        view.accessibilityLanguage = language

        if let elements = view.accessibilityElements {
            for case let element as NSObject in elements {
                element.accessibilityLanguage = language
            }
        }

        view.subviews.forEach { applyLanguage(to: $0) }
    }
}

#Preview {
    ContentView()
}
