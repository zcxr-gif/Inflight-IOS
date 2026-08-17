import Combine
import Foundation
import StoreKit

/// Inflight Pro, bought through the App Store.
///
/// A non-consumable rather than a subscription: it is one payment for the
/// features the app already has, it never lapses, and it needs no renewal
/// server. The web build sells a recurring plan through Stripe — that flow is
/// deliberately not reachable from inside the app, because App Store rules do
/// not allow it, and because `Entitlements` already honours a web subscription
/// for anyone who has one.
///
/// StoreKit 2 throughout, so there is no receipt to parse and no server to
/// validate against: `Transaction.currentEntitlements` is the Apple-signed
/// answer to "has this Apple Account bought it", and it is the only thing this
/// class treats as proof.
final class ProStore: ObservableObject {

    static let shared = ProStore()

    /// The product as the App Store describes it — localised name and, more to
    /// the point, a price formatted in the user's own currency. Never
    /// hard-coded: $1.99 is the US tier, and every other storefront has its own
    /// number.
    @Published private(set) var product: Product?

    /// Whether this Apple Account owns Pro. The device half of the entitlement.
    @Published private(set) var isPurchased = false

    /// Set while the App Store sheet is up.
    @Published private(set) var isPurchasing = false

    /// Set while the product is being fetched, so the paywall can show its
    /// price arriving rather than a blank button.
    @Published private(set) var isLoadingProduct = false

    /// Set while a restore is running.
    @Published private(set) var isRestoring = false

    /// The last thing that went wrong, if it was worth saying. A cancelled
    /// purchase is not — the user knows, they cancelled it.
    @Published var problem: String?

    /// Said after a restore that found nothing, which otherwise looks like the
    /// button doing nothing at all.
    @Published var notice: String?

    /// Watches for entitlements that arrive without this app asking: a purchase
    /// made on another device, a family-sharing grant, an Ask-to-Buy approval
    /// that lands days later, or a refund being taken back.
    private var updates: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Called once at launch. Safe to call again.
    ///
    /// Deliberately not isolated itself, so it can be called from wherever the
    /// app happens to start up. Both tasks it spawns pin themselves to the main
    /// actor instead, which is where everything they touch lives.
    func start() {
        guard updates == nil else { return }

        updates = Task { @MainActor [weak self] in
            for await update in Transaction.updates {
                guard let self = self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.refreshEntitlement()
            await self.loadProduct()
        }
    }

    // MARK: - Catalogue

    @MainActor
    func loadProduct() async {
        guard product == nil, !isLoadingProduct else { return }

        isLoadingProduct = true
        defer { isLoadingProduct = false }

        do {
            product = try await Product.products(for: [AppConfig.proProductID]).first
        } catch {
            // Left nil. The paywall says what Pro is either way and offers the
            // button disabled, which is a better answer than an error about
            // StoreKit to someone who is only browsing.
            product = nil
        }
    }

    /// What to put on the button. The App Store's own formatted price when it
    /// has arrived, and nothing pretending to be one when it hasn't.
    var displayPrice: String? { product?.displayPrice }

    // MARK: - Buying

    @MainActor
    func purchase() async {
        guard !isPurchasing else { return }

        // The paywall can be opened before the catalogue lands — on a cold
        // launch with a slow connection, say — so this retries rather than
        // refusing.
        if product == nil { await loadProduct() }

        guard let product = product else {
            problem = "The App Store isn't answering right now. Try again in a moment."
            return
        }

        isPurchasing = true
        problem = nil
        notice = nil
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // Unverified means the signature didn't check out. Nothing
                    // is unlocked on the strength of it.
                    problem = "That purchase couldn't be verified."
                    return
                }
                await transaction.finish()
                await refreshEntitlement()

            case .pending:
                // Ask to Buy, or a payment method needing action. The purchase
                // may well complete later, and `Transaction.updates` is what
                // catches it when it does.
                notice = "Waiting on approval. Pro unlocks as soon as it clears."

            case .userCancelled:
                break

            @unknown default:
                break
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The App Store restore, for a new device or a reinstall.
    ///
    /// `AppStore.sync()` is deliberately the last resort it is meant to be — it
    /// asks for an Apple Account password — so the cheap check runs first and
    /// only a genuine miss goes on to the expensive one.
    @MainActor
    func restore() async {
        guard !isRestoring else { return }

        isRestoring = true
        problem = nil
        notice = nil
        defer { isRestoring = false }

        await refreshEntitlement()
        if isPurchased { return }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isPurchased {
                notice = "No Inflight Pro purchase on this Apple Account."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Entitlement

    @MainActor
    func refreshEntitlement() async {
        var owned = false

        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productID == AppConfig.proProductID else { continue }

            // A refunded or revoked purchase stays in the list with a date on
            // it, and it is not an entitlement any more.
            if transaction.revocationDate == nil { owned = true }
        }

        guard owned != isPurchased else { return }
        isPurchased = owned
        Entitlements.shared.storeChanged()
    }
}
