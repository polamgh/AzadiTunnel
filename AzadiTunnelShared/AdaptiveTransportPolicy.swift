import Foundation

/// The transport choices used by the automatic Iran recovery policy.
///
/// This type deliberately has no access to settings or network state. Keeping the ordering and
/// scope rules pure makes them deterministic to test and prevents a persisted connection result
/// from silently changing the user's explicit transport selection.
enum AdaptiveTransportPolicy {
    enum Selection: String, Equatable {
        case auto
        case direct
        case cdnFronting
        case conduit
    }

    struct Candidate: Equatable {
        let transport: FallbackStep
        let selection: Selection
        let beast: Bool
        let tacticsEnabled: Bool
        let usesStaticCDNOverrides: Bool
    }

    /// Returns the ordered candidates for a user selection.
    ///
    /// Automatic selection starts with Auto + Beast (AggressiveEstablishment), then falls back to
    /// explicit CDN fronting and Direct. Public Conduit is intentionally opt-in to this list and,
    /// when available, is always the final candidate. Direct remains a single explicit choice.
    static func candidates(
        for selection: Selection,
        includePublicConduit: Bool = false
    ) -> [Candidate] {
        let auto = Candidate(
            transport: .autoBeast,
            selection: .auto,
            beast: true,
            tacticsEnabled: true,
            usesStaticCDNOverrides: false
        )
        let cdn = Candidate(
            transport: .cdn,
            selection: .cdnFronting,
            beast: true,
            tacticsEnabled: true,
            usesStaticCDNOverrides: true
        )
        let direct = Candidate(
            transport: .direct,
            selection: .direct,
            beast: false,
            tacticsEnabled: true,
            usesStaticCDNOverrides: false
        )
        let publicConduit = Candidate(
            transport: .conduitPublic,
            selection: .conduit,
            beast: false,
            tacticsEnabled: true,
            usesStaticCDNOverrides: false
        )

        switch selection {
        case .auto:
            return [auto, cdn, direct] + (includePublicConduit ? [publicConduit] : [])
        case .cdnFronting:
            return [cdn, auto, direct] + (includePublicConduit ? [publicConduit] : [])
        case .direct:
            return [direct]
        case .conduit:
            return []
        }
    }

    /// Shiro Android applies CDN fronting hints for auto, direct, and explicit CDN modes.
    static func includesCdnFrontingHints(for selection: Selection) -> Bool {
        switch selection {
        case .auto, .direct, .cdnFronting:
            return true
        case .conduit:
            return false
        }
    }

    /// Static CDN dial overrides and scan hints are only valid for an explicit CDN attempt.
    static func usesStaticCDNOverrides(for selection: Selection) -> Bool {
        selection == .cdnFronting
    }

    static func usesStaticCDNOverrides(for rawValue: String) -> Bool {
        guard let selection = selection(for: rawValue) else { return false }
        return usesStaticCDNOverrides(for: selection)
    }

    static func includesCdnFrontingHints(for rawValue: String) -> Bool {
        guard let selection = selection(for: rawValue) else { return false }
        return includesCdnFrontingHints(for: selection)
    }

    /// The app never disables Psiphon tactics for an adaptive transport attempt.
    static func keepsTacticsEnabled(for selection: Selection) -> Bool {
        _ = selection
        return true
    }

    static func selection(for rawValue: String) -> Selection? {
        if let selection = Selection(rawValue: rawValue) {
            return selection
        }
        // Accept the diagnostics/storage spelling used by older connectivity code.
        if rawValue == "cdn_fronting" {
            return .cdnFronting
        }
        return nil
    }
}
