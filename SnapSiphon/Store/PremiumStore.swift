import Foundation
import StoreKit

/// StoreKit 2 wrapper for the single premium unlock: background backups.
/// Non-consumable, one-time purchase; everything else in the app stays free.
///
/// Entitlement is re-derived from `Transaction.currentEntitlements` on launch
/// and after every purchase/restore/update, so family sharing, refunds, and
/// re-installs all resolve correctly without us persisting anything.
@MainActor
final class PremiumStore: ObservableObject {
    static let shared = PremiumStore()
    static let productID = "ca.straybits.snapsiphon.premium"

    @Published private(set) var isUnlocked = false
    @Published private(set) var product: Product?
    @Published private(set) var purchasing = false
    @Published private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        // React to transactions that happen outside the app (family sharing,
        // refunds, Ask to Buy approvals).
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task {
            await refreshEntitlement()
            await loadProduct()
        }
    }

    var displayPrice: String { product?.displayPrice ?? "$0.99" }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    func refreshEntitlement() async {
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    func purchase() async {
        lastError = nil
        if product == nil { await loadProduct() }
        guard let product else {
            lastError = "Store not reachable — try again later."
            return
        }
        purchasing = true
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await refreshEntitlement()
            case .userCancelled, .pending:
                break   // pending = Ask to Buy; Transaction.updates resolves it
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        lastError = nil
        try? await AppStore.sync()
        await refreshEntitlement()
        if !isUnlocked { lastError = "No previous purchase found for this Apple ID." }
    }
}
