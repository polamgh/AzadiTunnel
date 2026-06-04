import SwiftUI

/// In-app rendering of the bundled app icon (AppLogo asset).
struct AppIconImage: View {
    var size: CGFloat = 44
    var cornerRadius: CGFloat? = nil
    var shadow: Bool = true

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.2237
    }

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
            .shadow(
                color: shadow ? .black.opacity(0.14) : .clear,
                radius: shadow ? size * 0.08 : 0,
                y: shadow ? size * 0.04 : 0
            )
            .accessibilityHidden(true)
    }
}
