import Foundation

/// Maps Psiphon / ISO region codes to readable country names and flag labels for UI.
enum RegionDisplayNames {
    static func countryName(for codeOrLabel: String, locale: Locale = .current) -> String {
        let key = codeOrLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return "" }
        if key.count > 3 { return codeOrLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let localized = locale.localizedString(forRegionCode: key), !localized.isEmpty {
            return localized
        }
        return isoCountry[key] ?? codeOrLabel
    }

    /// Regional-indicator flag emoji for ISO 3166-1 alpha-2 (e.g. US → 🇺🇸).
    static func flagEmoji(for code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count == 2, upper.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "" }
        let base: UInt32 = 127_397
        var flag = ""
        for scalar in upper.unicodeScalars {
            guard let regional = UnicodeScalar(base + scalar.value) else { return "" }
            flag.unicodeScalars.append(regional)
        }
        return flag
    }

    /// Flag + full country name for pickers and dashboard.
    static func pickerLabel(for code: String, locale: Locale = .current) -> String {
        let name = countryName(for: code, locale: locale)
        let flag = flagEmoji(for: code)
        return flag.isEmpty ? name : "\(flag) \(name)"
    }

    private static let isoCountry: [String: String] = [
        "US": "United States", "GB": "United Kingdom", "UK": "United Kingdom",
        "DE": "Germany", "FR": "France", "NL": "Netherlands", "SE": "Sweden",
        "CH": "Switzerland", "AT": "Austria", "BE": "Belgium", "PL": "Poland",
        "IT": "Italy", "ES": "Spain", "PT": "Portugal", "IE": "Ireland",
        "CA": "Canada", "AU": "Australia", "JP": "Japan", "SG": "Singapore",
        "HK": "Hong Kong", "IN": "India", "BR": "Brazil", "MX": "Mexico",
        "TR": "Turkey", "RU": "Russia", "UA": "Ukraine", "FI": "Finland",
        "NO": "Norway", "DK": "Denmark", "CZ": "Czechia", "RO": "Romania",
        "BG": "Bulgaria", "HU": "Hungary", "GR": "Greece", "IL": "Israel",
        "AE": "United Arab Emirates", "ZA": "South Africa", "KR": "South Korea",
        "TW": "Taiwan", "NZ": "New Zealand", "AR": "Argentina", "CL": "Chile",
        "CO": "Colombia", "IR": "Iran"
    ]
}
