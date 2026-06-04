import Foundation

enum IAPProductIDs {
    static let tipSmall = "azaditunnel.tip.small"
    static let tipMedium = "azaditunnel.tip.medium"
    static let tipLarge = "azaditunnel.tip.large"
    static let supportMonthly = "azaditunnel.support.monthly"
    static let supportYearly = "azaditunnel.support.yearly"

    static var all: [String] {
        [tipSmall, tipMedium, tipLarge, supportMonthly, supportYearly]
    }
}

enum SupportPurchaseState: String, Codable {
    case notPurchased
    case purchased
    case subscribed
    case expired
    case unknown

    var localizedLabel: String {
        switch self {
        case .notPurchased: return L10n.t(.supportStateNotPurchased)
        case .purchased: return L10n.t(.supportStatePurchased)
        case .subscribed: return L10n.t(.supportStateSubscribed)
        case .expired: return L10n.t(.supportStateExpired)
        case .unknown: return L10n.t(.supportStateUnknown)
        }
    }
}
