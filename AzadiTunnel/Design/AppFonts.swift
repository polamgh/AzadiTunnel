import CoreText
import Foundation

/// Fonts shipped inside the app bundle (see THIRD_PARTY_NOTICES.md for licenses).
enum AppFonts {
    /// PostScript name of the wordmark typeface.
    static let wordmark = "GrandHotel-Regular"

    private static let bundled = ["GrandHotel-Regular"]

    /// Registers bundled fonts for this process so `Font.custom` can resolve them.
    static func registerBundledFonts() {
        for name in bundled {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                SharedLogger.shared.logRaw("FONT_MISSING", detail: "name=\(name)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
