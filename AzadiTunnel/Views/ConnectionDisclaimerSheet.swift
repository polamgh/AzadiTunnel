import SwiftUI

struct ConnectionDisclaimerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.t(.disclaimerIntro))
                        .font(.body)

                    disclaimerSection(title: L10n.t(.disclaimerResponsibleUseTitle), body: L10n.t(.disclaimerResponsibleUse))
                    disclaimerSection(title: L10n.t(.disclaimerNoGuaranteeTitle), body: L10n.t(.disclaimerNoGuarantee))
                    disclaimerSection(title: L10n.t(.disclaimerPrivacyDiagnosticsTitle), body: L10n.t(.disclaimerPrivacyDiagnostics))
                    disclaimerSection(title: L10n.t(.disclaimerNoIllegalContentTitle), body: L10n.t(.disclaimerNoIllegalContent))
                    disclaimerSection(title: L10n.t(.disclaimerThirdPartyNetworksTitle), body: L10n.t(.disclaimerThirdPartyNetworks))
                }
                .padding()
            }
            .navigationTitle(L10n.t(.beforeYouConnectTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t(.cancel)) {
                        SharedLogger.shared.logRaw("DISCLAIMER_CANCELLED", detail: "source=sheet")
                        onCancel()
                    }
                    .accessibilityIdentifier("disclaimerCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t(.iUnderstandAndAgree)) {
                        SharedLogger.shared.logRaw("DISCLAIMER_ACCEPTED", detail: "source=sheet")
                        onAccept()
                    }
                    .accessibilityIdentifier("disclaimerAcceptButton")
                }
            }
        }
        .onAppear {
            SharedLogger.shared.logRaw("DISCLAIMER_PRESENTED", detail: "source=first_connect")
        }
    }

    private func disclaimerSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
        }
    }
}
