import SwiftUI

struct AppToastBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText(for: colorScheme))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(AppTheme.cardFillElevated(for: colorScheme))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.iranGreen.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 20)
    }
}
