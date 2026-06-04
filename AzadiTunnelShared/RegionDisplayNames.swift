import Foundation

/// Maps Psiphon / ISO region codes to readable country names.
enum RegionDisplayNames {
    static func countryName(for codeOrLabel: String) -> String {
        let key = codeOrLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return "" }
        if key.count > 3 { return codeOrLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
        return isoCountry[key] ?? codeOrLabel
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
        "AE": "UAE", "ZA": "South Africa", "KR": "South Korea", "TW": "Taiwan",
        "NZ": "New Zealand", "AR": "Argentina", "CL": "Chile", "CO": "Colombia"
    ]
}
