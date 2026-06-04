import Foundation

struct OpenSourceComponent: Identifiable {
    let id: String
    let name: String
    let license: String
    let sourceURL: String
    let description: String
    let licenseNeedsVerification: Bool
}

enum LegalNoticesCatalog {
    static let components: [OpenSourceComponent] = [
        OpenSourceComponent(
            id: "psiphon-inc",
            name: "Psiphon (Psiphon Inc.)",
            license: "GNU General Public License v3 (tunnel-core components)",
            sourceURL: "https://github.com/psiphon-inc",
            description: "Psiphon tunnel technology. Psiphon® is a registered trademark of Psiphon Inc. AzadiTunnel is not affiliated with Psiphon Inc.",
            licenseNeedsVerification: false
        ),
        OpenSourceComponent(
            id: "psiphon-tunnel-core",
            name: "psiphon-tunnel-core",
            license: "GNU General Public License v3",
            sourceURL: "https://github.com/shirokhorshid/psiphon-tunnel-core",
            description: "Tunnel client core used by the Packet Tunnel extension (pinned fork/build).",
            licenseNeedsVerification: false
        ),
        OpenSourceComponent(
            id: "shiro-reference",
            name: "Shiro Khorshid reference implementation",
            license: "See upstream repositories",
            sourceURL: "https://github.com/shirokhorshid/shirokhorshid-android",
            description: "Transport, CDN fronting, and Conduit behavior referenced for parity.",
            licenseNeedsVerification: true
        ),
        OpenSourceComponent(
            id: "tun2socks",
            name: "tun2socks (Swift Package)",
            license: "License: needs verification",
            sourceURL: "https://github.com/zhuhaow/tun2socks",
            description: "Forwards packet tunnel traffic to the local Psiphon SOCKS proxy.",
            licenseNeedsVerification: true // TODO: Confirm upstream license and bundle notice if required.
        ),
        OpenSourceComponent(
            id: "geolite2-country",
            name: "GeoLite2 Country database (MMDB)",
            license: "MaxMind GeoLite2 License (needs verification)",
            sourceURL: "https://dev.maxmind.com/geoip/geolite2-free-geolocation-data",
            description: "Optional GeoIP database for Conduit country filtering when bundled.",
            licenseNeedsVerification: true // TODO: Confirm MaxMind attribution and redistribution terms.
        )
    ]

    static func bundledText(named resource: String) -> String? {
        let base = (resource as NSString).deletingPathExtension
        let ext = (resource as NSString).pathExtension
        let subdirs = ["Resources/Legal", "Legal", nil as String?]
        for sub in subdirs {
            let url: URL?
            if ext.isEmpty {
                url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: sub)
            } else {
                url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub)
            }
            if let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        SharedLogger.shared.logRaw("LICENSE_COMPONENT_MISSING", detail: "name=\(resource)")
        return nil
    }

    static var appLicenseText: String {
        bundledText(named: "LICENSE") ?? ""
    }

    static var thirdPartyNoticesText: String {
        bundledText(named: "THIRD_PARTY_NOTICES.md") ?? ""
    }

    static var fullLicenseNoticesText: String {
        let license = appLicenseText
        let notices = thirdPartyNoticesText
        if license.isEmpty && notices.isEmpty {
            return "Full license notices are not available in this build. See the project repository for LICENSE and THIRD_PARTY_NOTICES.md."
        }
        var parts: [String] = []
        if !notices.isEmpty {
            parts.append("=== PSIPHON / THIRD-PARTY NOTICES ===\n\n\(notices)")
        }
        if !license.isEmpty {
            parts.append("=== AzadiTunnel LICENSE ===\n\n\(license)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func logMissingComponentsOnOpen() {
        for component in components where component.licenseNeedsVerification {
            SharedLogger.shared.logRaw(
                "LICENSE_COMPONENT_MISSING",
                detail: "name=\(component.id) reason=license_needs_verification"
            )
        }
        if appLicenseText.isEmpty {
            SharedLogger.shared.logRaw("LICENSE_COMPONENT_MISSING", detail: "name=LICENSE")
        }
        if thirdPartyNoticesText.isEmpty {
            SharedLogger.shared.logRaw("LICENSE_COMPONENT_MISSING", detail: "name=THIRD_PARTY_NOTICES")
        }
    }
}
