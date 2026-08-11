import CoreTelephony
import Foundation

/// Best-effort information about the SIM/eSIM providers configured on the device.
///
/// Core Telephony does not require a user permission or an entitlement for this
/// information. It describes the subscriber's home provider, not the ISP of a
/// Wi-Fi connection and not necessarily the network used while roaming.
struct CellularCarrierSnapshot: Equatable, Sendable {
    let names: [String]
    let identifiers: [String]
    let countries: [String]
    let codes: [String]

    var primaryName: String { names.first ?? "unknown" }
    var primaryIdentifier: String { identifiers.first ?? "unknown" }
    var namesValue: String {
        names.isEmpty ? "unknown" : String(names.joined(separator: ",").prefix(100))
    }
    var codesValue: String {
        codes.isEmpty ? "unknown" : String(codes.joined(separator: ",").prefix(100))
    }
    var primaryCountry: String { countries.first ?? "unknown" }
}

/// Reads carrier metadata without requesting phone, contacts, location, or
/// tracking access. The API is deprecated by Apple but remains the only public
/// Core Telephony API for subscriber carrier information, so callers must treat
/// an unavailable value as `unknown`.
@MainActor
enum CellularCarrierProvider {
    private struct CarrierRecord {
        let name: String
        let identifier: String
        let country: String
        let code: String
    }

    static func current() -> CellularCarrierSnapshot {
        let networkInfo = CTTelephonyNetworkInfo()
        let carriers = (networkInfo.serviceSubscriberCellularProviders ?? [:]).values.compactMap(record)

        var unique: [String: CarrierRecord] = [:]
        for carrier in carriers {
            let key = "\(carrier.identifier)|\(carrier.code)|\(carrier.name)"
            unique[key] = carrier
        }

        let ordered = unique.values.sorted {
            if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
            if $0.code != $1.code { return $0.code < $1.code }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return CellularCarrierSnapshot(
            names: ordered.map(\.name),
            identifiers: ordered.map(\.identifier),
            countries: ordered.map(\.country),
            codes: ordered.map(\.code)
        )
    }

    @available(iOS, deprecated: 16.0)
    private static func record(_ carrier: CTCarrier) -> CarrierRecord? {
        let name = clean(carrier.carrierName)
        let country = clean(carrier.isoCountryCode)?.uppercased() ?? ""
        let mcc = clean(carrier.mobileCountryCode) ?? ""
        let mnc = clean(carrier.mobileNetworkCode) ?? ""
        let code = [mcc, mnc].filter { !$0.isEmpty }.joined(separator: "-")
        let identifier = canonicalIdentifier(name: name, mcc: mcc, mnc: mnc)
        let displayName = name ?? displayName(for: identifier)

        guard name != nil || identifier != "unknown" || !code.isEmpty || !country.isEmpty else {
            return nil
        }

        return CarrierRecord(
            name: displayName.isEmpty ? "unknown" : displayName,
            identifier: identifier,
            country: country.isEmpty ? "unknown" : country,
            code: code.isEmpty ? "unknown" : code
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "--" else { return nil }
        return trimmed
    }

    private static func canonicalIdentifier(name: String?, mcc: String, mnc: String) -> String {
        // Stable identifiers for the common Iranian mobile networks. MCC/MNC
        // is preferred over the carrier's presentation string when available.
        if mcc == "432" {
            switch mnc {
            case "11": return "mci"
            case "35": return "irancell"
            case "20": return "rightel"
            default: break
            }
        }

        let token = name?.lowercased() ?? ""
        if token.contains("irancell") || token.contains("ایرانسل") { return "irancell" }
        if token.contains("mci") || token.contains("hamrah") || token.contains("همراه") { return "mci" }
        if token.contains("rightel") || token.contains("رایتل") { return "rightel" }

        guard let name else { return "unknown" }
        let slug = name
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return slug.isEmpty ? "unknown" : String(slug.prefix(40))
    }

    private static func displayName(for identifier: String) -> String {
        switch identifier {
        case "mci": return "MCI"
        case "irancell": return "Irancell"
        case "rightel": return "Rightel"
        default: return identifier == "unknown" ? "unknown" : identifier
        }
    }
}
