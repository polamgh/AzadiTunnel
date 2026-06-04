import Foundation
import Combine
import StoreKit

@MainActor
final class SupportStoreManager: ObservableObject {
    static let shared = SupportStoreManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadError: String?
    @Published private(set) var purchaseState: SupportPurchaseState = .unknown
    @Published private(set) var isLoading = false

    private var transactionUpdatesTask: Task<Void, Never>?

    var productsUnavailable: Bool {
        !isLoading && products.isEmpty
    }

    private init() {
        listenForTransactionUpdates()
    }

    func loadProductsIfNeeded() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        loadError = nil
        SharedLogger.shared.logRaw("IAP_PRODUCTS_LOADING", detail: "count_request=\(IAPProductIDs.all.count)")
        do {
            let loaded = try await Product.products(for: IAPProductIDs.all)
            products = loaded.sorted { $0.id < $1.id }
            let loadedIDs = Set(products.map(\.id))
            let missing = IAPProductIDs.all.filter { !loadedIDs.contains($0) }
            let missingDetail = missing.isEmpty ? "none" : missing.joined(separator: ",")
            SharedLogger.shared.logRaw(
                "IAP_PRODUCTS_LOADED",
                detail: "count=\(products.count) missing=\(missingDetail)"
            )
            if products.isEmpty {
                loadError = SupportStoreManager.unavailableMessage
            }
            await refreshEntitlements()
        } catch {
            loadError = SupportStoreManager.unavailableMessage
            SharedLogger.shared.logRaw("IAP_PRODUCTS_LOADED", detail: "count=0 error=\(error.localizedDescription)")
        }
        isLoading = false
    }

    func purchase(_ product: Product) async {
        SharedLogger.shared.logRaw("IAP_PURCHASE_STARTED", detail: "product=\(product.id)")
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                SharedLogger.shared.logRaw("IAP_PURCHASE_SUCCESS", detail: "product=\(product.id)")
                await refreshEntitlements()
            case .userCancelled:
                SharedLogger.shared.logRaw("IAP_PURCHASE_CANCELLED", detail: "product=\(product.id)")
            case .pending:
                SharedLogger.shared.logRaw("IAP_PURCHASE_FAILED", detail: "product=\(product.id) error=pending")
            @unknown default:
                SharedLogger.shared.logRaw("IAP_PURCHASE_FAILED", detail: "product=\(product.id) error=unknown_result")
            }
        } catch {
            SharedLogger.shared.logRaw("IAP_PURCHASE_FAILED", detail: "product=\(product.id) error=\(error.localizedDescription)")
        }
    }

    func restorePurchases() async {
        SharedLogger.shared.logRaw("IAP_RESTORE_STARTED", detail: "source=app")
        try? await AppStore.sync()
        await refreshEntitlements()
        SharedLogger.shared.logRaw("IAP_RESTORE_COMPLETED", detail: "state=\(purchaseState.rawValue)")
    }

    private func listenForTransactionUpdates() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard let transaction = try? self.checkVerified(result) else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func refreshEntitlements() async {
        var hasTip = false
        var hasActiveSub = false
        var hasExpiredSub = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == IAPProductIDs.supportMonthly || transaction.productID == IAPProductIDs.supportYearly {
                if transaction.revocationDate == nil, transaction.expirationDate == nil || (transaction.expirationDate ?? .distantPast) > Date() {
                    hasActiveSub = true
                } else {
                    hasExpiredSub = true
                }
            }
            if IAPProductIDs.all.contains(transaction.productID) {
                hasTip = true
            }
        }
        if hasActiveSub {
            purchaseState = .subscribed
        } else if hasExpiredSub {
            purchaseState = .expired
        } else if hasTip {
            purchaseState = .purchased
        } else if products.isEmpty {
            purchaseState = .unknown
        } else {
            purchaseState = .notPurchased
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe): return safe
        }
    }

    static let unavailableMessage = "Support purchases are not available in this build."
}
