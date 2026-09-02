import Combine
import Foundation
import StoreKit

/// Inflight Pro, bought through the App Store.
///
/// Two plans against one entitlement — a year and a month — sitting in one
/// subscription group, so switching between them is something Apple handles
/// rather than something anybody buys twice. The lifetime unlock earlier
/// builds sold is no longer offered, but `AppConfig.ProProduct` still knows
/// about it and `refreshEntitlement` still honours it: a purchase does not
/// stop counting because the pricing changed.
///
/// StoreKit 2 throughout, so there is no receipt to parse:
/// `Transaction.currentEntitlements` is the Apple-signed answer to "does this
/// Apple Account have Pro right now", and it is the only thing this class
/// treats as proof on the device. What it *also* does is post those signed
/// transactions to Supabase (`AppConfig.appleSubscriptionSyncURL`), so the
/// entitlement reaches the account rather than staying on the phone — that is
/// what makes a purchase made here show up on inflight.info, and what lets a
/// renewal that happens with the app closed still land.
final class ProStore: ObservableObject {

    static let shared = ProStore()

    /// The catalogue, as the App Store describes it: localised names, and
    /// prices in the user's own currency. Never hard-coded — $19.99 is the US
    /// tier and every other storefront has its own number.
    @Published private(set) var products: [AppConfig.ProProduct: Product] = [:]

    /// Which plan the paywall has selected. A year by default: it is the one
    /// most people should buy, and preselecting it is the honest version of
    /// "recommended" — the other two are one tap away.
    @Published var selected: AppConfig.ProProduct = .annual

    /// The product identifiers this Apple Account currently owns.
    @Published private(set) var owned: Set<String> = []

    /// Set while the App Store sheet is up, and for which plan.
    @Published private(set) var purchasing: AppConfig.ProProduct?

    /// Set while the catalogue is being fetched, so the paywall can show its
    /// prices arriving rather than a row of blanks.
    @Published private(set) var isLoadingProducts = false

    /// Set while a restore is running.
    @Published private(set) var isRestoring = false

    /// The last thing that went wrong, if it was worth saying. A cancelled
    /// purchase is not — the user knows, they cancelled it.
    @Published var problem: String?

    /// Said after a restore that found nothing, which otherwise looks like the
    /// button doing nothing at all.
    @Published var notice: String?

    /// Watches for entitlements that arrive without this app asking: a purchase
    /// made on another device, a renewal, a family-sharing grant, an
    /// Ask-to-Buy approval that lands days later, or a refund being taken back.
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
            await self.loadProducts()
        }
    }

    // MARK: - Catalogue

    @MainActor
    func loadProducts() async {
        guard products.count < AppConfig.ProProduct.forSale.count,
              !isLoadingProducts else { return }

        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetched = try await Product.products(for: AppConfig.proProductIDs)

            var mapped: [AppConfig.ProProduct: Product] = [:]
            for product in fetched {
                if let plan = AppConfig.ProProduct(rawValue: product.id) {
                    mapped[plan] = product
                }
            }
            products = mapped
        } catch {
            // Left as it was. The paywall says what Pro is either way and
            // offers the buttons disabled, which is a better answer than an
            // error about StoreKit to someone who is only browsing.
        }
    }

    func product(for plan: AppConfig.ProProduct) -> Product? { products[plan] }

    /// The App Store's own formatted price, or nil while the catalogue is on
    /// its way. Nothing pretending to be a price is ever shown in its place.
    func displayPrice(for plan: AppConfig.ProProduct) -> String? {
        products[plan]?.displayPrice
    }

    /// The cheapest way in, for the rows elsewhere in the app that mention what
    /// Pro costs without opening the paywall.
    var displayPrice: String? {
        displayPrice(for: .annual) ?? displayPrice(for: .monthly)
    }

    /// What a year works out at per month, in the storefront's own currency.
    ///
    /// Formatted from the product's own price and currency rather than by
    /// dividing a string, so it is right in every storefront and absent in none.
    func perMonthPrice(for plan: AppConfig.ProProduct) -> String? {
        guard plan == .annual,
              let product = products[.annual],
              let period = product.subscription?.subscriptionPeriod else { return nil }

        let months: Decimal
        switch period.unit {
        case .year: months = Decimal(period.value * 12)
        case .month: months = Decimal(period.value)
        case .week: months = Decimal(period.value) / 4
        case .day: months = Decimal(period.value) / 30
        @unknown default: return nil
        }

        guard months > 1 else { return nil }
        return (product.price / months).formatted(product.priceFormatStyle)
    }

    /// How much cheaper a year is than twelve months, as a whole percentage.
    ///
    /// Nil unless both prices are actually known and the year is actually
    /// cheaper — a saving badge on a plan that saves nothing is a lie, and one
    /// computed from a price that hasn't arrived is a guess.
    var annualSavingPercent: Int? {
        guard let annual = products[.annual], let monthly = products[.monthly],
              let annualPeriod = annual.subscription?.subscriptionPeriod,
              annualPeriod.unit == .year, annualPeriod.value == 1 else { return nil }

        let twelveMonths = monthly.price * 12
        guard twelveMonths > 0, annual.price < twelveMonths else { return nil }

        let saved = (twelveMonths - annual.price) / twelveMonths * 100
        let percent = (saved as NSDecimalNumber).intValue
        return percent > 0 ? percent : nil
    }

    // MARK: - Buying

    @MainActor
    func purchase(_ plan: AppConfig.ProProduct) async {
        guard purchasing == nil else { return }

        // The paywall can be opened before the catalogue lands — on a cold
        // launch with a slow connection, say — so this retries rather than
        // refusing.
        if products[plan] == nil { await loadProducts() }

        guard let product = products[plan] else {
            problem = "The App Store isn't answering right now. Try again in a moment."
            return
        }

        purchasing = plan
        problem = nil
        notice = nil
        defer { purchasing = nil }

        var options: Set<Product.PurchaseOption> = []

        // Stamps the purchase with the account that made it, so a renewal or a
        // refund notification arriving at the server days later can find its
        // way back to the right profile without the app being involved. The
        // Supabase user id is already a UUID, which is exactly what this field
        // wants.
        if let accountID = AccountStore.shared.account.flatMap({ UUID(uuidString: $0.id) }) {
            options.insert(.appAccountToken(accountID))
        }

        do {
            switch try await product.purchase(options: options) {
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

    /// Whether this Apple Account owns Pro in any of its forms.
    var isPurchased: Bool { !owned.isEmpty }

    /// Which plan the entitlement came from, for the account panel to say so.
    /// Lifetime wins when somebody holds both — it is the one that does not
    /// run out, and the one whose copy needs saying.
    var ownedPlan: AppConfig.ProProduct? {
        if owned.contains(AppConfig.ProProduct.lifetime.rawValue) { return .lifetime }
        if owned.contains(AppConfig.ProProduct.annual.rawValue) { return .annual }
        if owned.contains(AppConfig.ProProduct.monthly.rawValue) { return .monthly }
        return nil
    }

    @MainActor
    func refreshEntitlement() async {
        var found: Set<String> = []
        var signed: [String] = []

        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  AppConfig.ProProduct(rawValue: transaction.productID) != nil else { continue }

            // A refunded or revoked purchase stays in the list with a date on
            // it, and it is not an entitlement any more.
            guard transaction.revocationDate == nil else { continue }

            // A subscription that has run out is likewise still listed for a
            // while. `currentEntitlements` filters most of these out already;
            // this is the belt to that braces.
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }

            found.insert(transaction.productID)
            // The signature comes off the verification result rather than the
            // decoded transaction: the JWS *is* the signed form, and it is
            // what the server re-verifies against Apple's roots.
            signed.append(entitlement.jwsRepresentation)
        }

        if found != owned {
            owned = found
            Entitlements.shared.storeChanged()
        }

        await linkIfNeeded(signed)
    }

    /// What has already been handed to the server, and for whom.
    ///
    /// Both halves matter. Without the products, every launch re-posts a
    /// purchase the server already has; without the account, signing in on a
    /// phone that already owns Pro would never post it at all — the set of
    /// owned products hasn't changed, but the account it needs to reach has.
    private var linked: (account: String, products: Set<String>)?

    /// Pushes the signed transactions up, when there is a new thing to say.
    ///
    /// Deliberately after the local entitlement has already been applied: the
    /// device does not wait on the network to unlock something StoreKit has
    /// signed for. This is only about the *account* — and therefore the
    /// website — catching up.
    @MainActor
    private func linkIfNeeded(_ signedTransactions: [String]) async {
        guard !owned.isEmpty,
              let accountID = AccountStore.shared.account?.id else { return }

        if let linked = linked, linked.account == accountID, linked.products == owned {
            return
        }

        linked = (accountID, owned)
        await AccountStore.shared.linkAppStorePurchases(signedTransactions)
    }
}
