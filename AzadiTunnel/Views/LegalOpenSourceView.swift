import SwiftUI

struct LegalOpenSourceView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var appLicensePreview: String {
        let text = LegalNoticesCatalog.appLicenseText
        if text.isEmpty { return L10n.t(.legalLicenseUnavailable) }
        return String(text.prefix(600)) + (text.count > 600 ? "\n…" : "")
    }

    var body: some View {
        List {
            Section(L10n.t(.legalOpenSourceComponentsSection)) {
                ForEach(LegalNoticesCatalog.components) { component in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(component.name)
                            .font(.subheadline.weight(.semibold))
                        Text(component.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(L10n.t(.legalLicenseLabel)): \(component.license)")
                            .font(.caption)
                        if let url = URL(string: component.sourceURL) {
                            Link(component.sourceURL, destination: url)
                                .font(.caption2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(L10n.t(.legalAppLicenseSection)) {
                Text("AzadiTunnel")
                    .font(.headline)
                Text(appLicensePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t(.legalGplWarningSection)) {
                Text(L10n.t(.legalGplWarningBody))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    FullLicenseNoticesView()
                } label: {
                    Text(L10n.t(.viewFullLicenseNotices))
                }
                .accessibilityIdentifier("viewFullLicenseNoticesLink")
            }
        }
        .navigationTitle(L10n.t(.legalOpenSourceTitle))
        .accessibilityIdentifier("legalOpenSourceScreen")
        .onAppear {
            LegalNoticesCatalog.logMissingComponentsOnOpen()
            SharedLogger.shared.logRaw("LEGAL_PAGE_OPENED", detail: "screen=legal_open_source")
        }
    }
}

struct FullLicenseNoticesView: View {
    var body: some View {
        ScrollView {
            Text(LegalNoticesCatalog.fullLicenseNoticesText)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(L10n.t(.viewFullLicenseNotices))
        .accessibilityIdentifier("fullLicenseNoticesScreen")
        .onAppear {
            SharedLogger.shared.logRaw("LICENSE_NOTICES_OPENED", detail: "source=legal_page")
        }
    }
}

struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.t(.privacyNoticeBody))
                Text(L10n.t(.privacyNoticeNoSecrets))
                Text(L10n.t(.privacyNoticeReviewExport))
                Text(L10n.t(.privacyNoticeStoreKit))
            }
            .font(.body)
            .padding()
        }
        .navigationTitle(L10n.t(.privacyNoticeTitle))
        .accessibilityIdentifier("privacyNoticeScreen")
        .onAppear {
            SharedLogger.shared.logRaw("PRIVACY_PAGE_OPENED", detail: "source=settings")
        }
    }
}
