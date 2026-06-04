import SwiftUI
import UIKit

/// Copy button for IP values in diagnostics; triggers `onCopied` for toast feedback.
struct CopyableIPRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let value: String
    let onCopied: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText(for: colorScheme))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if isCopyableIP(value) {
                Button {
                    UIPasteboard.general.string = value
                    onCopied()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.iranGreen)
                .accessibilityLabel(L10n.t(.copy))
            }
        }
    }

    private func isCopyableIP(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return false }
        return trimmed.contains(".") || trimmed.contains(":")
    }
}
