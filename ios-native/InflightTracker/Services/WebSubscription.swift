import Combine
import Foundation

/// Inflight Pro, bought on inflight.info through Stripe.
///
/// The other way to pay, alongside `ProStore`'s App Store purchase, and the
/// one that already had a place in this app: `pro_entitlement()` has always
/// folded a website subscription in, and `Entitlements` has always honoured it.
/// What was missing was a way to *start* one from here, so a pilot who wanted
/// the website's monthly plan had to go and find it themselves.
///
/// ## The shape of it
///
/// One month, at the price Stripe has. There is no yearly price on Stripe, so
/// there is no plan to choose and nothing here asks — and there is no trial,
/// because it is not something the website sells.
///
/// ## Where it happens
///
/// In a sheet over the app — Safari's own view controller, slid up from the
/// bottom like every other sheet here, rather than a jump out to the Safari
/// app and back. The payment is still Stripe's hosted page in Safari's engine
/// and no card detail ever touches this app; what changed is that the pilot
/// keeps the paywall, and the map, behind it.
///
/// That is also why `page` lives here rather than in the view. The sheet has
/// to close on something the *view* cannot see — the return page bouncing to
/// `inflight://open?payment=…` — so the one thing that knows a checkout is in
/// flight is the same thing that hears it end.
///
/// ## Why the confirmation is its own step
///
/// The checkout happens in a browser this app cannot read. Nothing
/// here ever grants Pro on the strength of somebody having come back: the
/// entitlement is written by `stripe-webhook`, which Stripe calls directly and
/// retries for days, from the account id this app puts on the checkout. That
/// is the durable half, and it lands whether or not the pilot returns at all.
///
/// What this adds is speed. A webhook can take a moment, and a pilot who has
/// just paid is looking at the paywall *now* — so on the way back the app asks
/// the server to check Stripe for this account (`restore-pro-access`, which
/// identifies the caller from their own token and takes no word from the
/// client about what it is owed) and re-reads the entitlement a few times.
///
/// Which is why running out of tries is not a failure and does not say so.
/// Coming back to the app re-asks anyway — `ContentView` refreshes the
/// entitlement on every foreground — and the webhook has days to arrive.
final class WebSubscription: ObservableObject {

    static let shared = WebSubscription()

    /// Set while the checkout session is being created, before the sheet opens.
    @Published private(set) var isStarting = false

    /// The checkout page, while one is up.
    ///
    /// Settable from outside so a view can bind a sheet straight to it: the
    /// pilot closing that sheet is the one end this cannot hear for itself.
    /// Everything else that ends a checkout clears it from in here.
    @Published var page: CheckoutPage?

    /// A checkout page, identified so it can drive a `sheet(item:)`. The URL
    /// is not the identity — Stripe would happily hand back the same session
    /// twice, and re-presenting is not the same as never having closed.
    struct CheckoutPage: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    /// Set while the app is asking the server whether the payment landed.
    @Published private(set) var isConfirming = false

    /// The last thing that went wrong, if it was worth saying.
    @Published var problem: String?

    /// Said when the checkout came back with nothing to show for it, which
    /// otherwise looks like the app having simply forgotten.
    @Published var notice: String?

    /// When a checkout was started from here, if one is still unaccounted for.
    ///
    /// On disk rather than in memory, and that is still the point even now the
    /// sheet keeps the app forward: a checkout can be left open, the phone
    /// locked, and this app killed for memory while it sits there. A claim held
    /// only in memory is exactly the claim that goes missing in the case it
    /// exists for — somebody pays, comes back to a freshly launched app, and
    /// nothing ever asks whether they did.
    ///
    /// It records only that a checkout was started. Not which session, not
    /// whether anybody paid: the server is asked for that, and is the only
    /// thing that answers it.
    private var pendingSince: Date? {
        get {
            let seconds = UserDefaults.standard.double(forKey: Self.claimKey)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.claimKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.claimKey)
            }
        }
    }

    private static let claimKey = "inflight.webSubscription.pendingSince"

    /// How long a claim is worth asking about. A day covers a checkout somebody
    /// left open overnight and finished in the morning; past that, a payment
    /// that never arrived is not going to, and asking Stripe on every launch
    /// forever is not a thing to leave running.
    private static let claimLifetime: TimeInterval = 24 * 60 * 60

    /// Whether there is a checkout still to account for. Expired claims clear
    /// themselves on the way past rather than needing a sweep.
    private var awaitingReturn: Bool {
        get {
            guard let since = pendingSince else { return false }
            guard Date().timeIntervalSince(since) <= Self.claimLifetime else {
                pendingSince = nil
                return false
            }
            return true
        }
        set { pendingSince = newValue ? Date() : nil }
    }

    /// Set when the return page says the pilot backed out at Stripe. Read
    /// between tries as well as before them, because the deep link and the app
    /// coming forward race each other and either can arrive first.
    private var wasCancelled = false

    private init() {}

    // MARK: - What the return page says

    /// The result carried on `inflight://open?payment=…`, or nil for any other
    /// link. Lives here rather than in `InflightLink` — that enum is the
    /// contract between the widgets and the app, and a payment is neither.
    static func paymentOutcome(from url: URL) -> Bool? {
        guard url.scheme?.lowercased() == InflightLink.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let outcome = items.first(where: { $0.name == "payment" })?.value
        else { return nil }

        switch outcome {
        case "success": return true
        case "cancel": return false
        default: return nil
        }
    }

    /// Called with what the return page said.
    ///
    /// A cancellation is worth hearing precisely because the alternative is
    /// unknowable from here: an account with no subscription on it looks the
    /// same whether nobody paid or Stripe has not finished. Told outright, the
    /// paywall can stop rather than spend twelve seconds checking for
    /// something nobody bought.
    @MainActor
    func settled(paid: Bool) async {
        // Whichever way it went, the checkout is over — so the sheet goes,
        // first and unconditionally. The return page bounces to
        // `inflight://open?payment=…` from inside that very sheet, and this is
        // the only thing that hears it.
        page = nil

        if paid {
            // Already asking, because coming forward beat the link here. The
            // link adds nothing to that, and staking a fresh claim over the
            // top of it would leave one outstanding after the run finishes.
            guard !isConfirming else { return }

            // Otherwise the link is itself the claim, and does not depend on
            // the one made when the checkout started: the app may have been
            // killed in the background while Stripe had the screen.
            awaitingReturn = true
            wasCancelled = false
            await confirmIfAwaitingReturn()
        } else {
            wasCancelled = true
            awaitingReturn = false
            problem = nil
            notice = nil
        }
    }

    // MARK: - Buying

    /// Creates the checkout session and puts its page up.
    ///
    /// Sets `page`, which a view has a sheet bound to; on any failure it sets
    /// `problem` instead and leaves the sheet shut. The view still owns what
    /// is on screen — it decides how a page is shown, and closing it is its
    /// call — but *whether there is a checkout in flight* is this object's
    /// business, because it is what the return link reports back to.
    @MainActor
    func begin() async {
        guard !isStarting else { return }

        // The subscription is attached to an account, so there has to be one.
        // Signing in first is a real requirement rather than a formality: a
        // payment made under no account is a payment nothing can be given for.
        guard let account = AccountStore.shared.account else {
            problem = "Sign into your Inflight account first — a subscription belongs to an account."
            return
        }

        isStarting = true
        problem = nil
        notice = nil
        defer { isStarting = false }

        guard let token = await AccountStore.shared.currentAccessToken() else {
            problem = "Your session has expired. Sign in again and try once more."
            return
        }

        do {
            let checkout = try await SupabaseAuth.webCheckoutSession(
                email: account.email,
                userID: account.id,
                accessToken: token
            )
            awaitingReturn = true
            wasCancelled = false
            page = CheckoutPage(url: checkout)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The checkout sheet has gone — Cancel, a swipe down, or the return link
    /// having closed it.
    ///
    /// Closing it is not cancelling at Stripe and must not be read as one: the
    /// return page is the only thing that says a checkout was abandoned, and
    /// somebody who swipes away Stripe's own receipt has paid. So this asks,
    /// exactly as coming back from Safari used to.
    ///
    /// It has to be asked *here* rather than left to the foreground check,
    /// because with the sheet inside the app there is no longer a foreground to
    /// come back to: the app never left. Without this a payment made in the
    /// sheet and then dismissed by hand would go unclaimed until the next
    /// launch.
    ///
    /// Safe on the return-link path too, where `settled(paid:)` has already
    /// started asking: `confirm()` runs one at a time and a settled claim is
    /// no longer awaiting one.
    @MainActor
    func checkoutSheetClosed() async {
        await confirmIfAwaitingReturn()
    }

    // MARK: - Coming back

    /// Called when the app comes forward. Does nothing unless a checkout was
    /// started from here and has not been settled yet.
    @MainActor
    func confirmIfAwaitingReturn() async {
        guard awaitingReturn else { return }
        await confirm()
    }

    /// Asks the server, a few times, whether Stripe has a live subscription for
    /// this account — and stops the moment Pro is on, however it got there.
    ///
    /// The waits are there because Stripe is not instant and the pilot is: the
    /// app is usually forward again before the subscription has finished being
    /// created. Five tries over about twelve seconds, because that is how long
    /// somebody will sit looking at a paywall — the webhook covers the rest,
    /// and so does the next time they open the app.
    @MainActor
    private func confirm() async {
        guard !isConfirming else { return }

        isConfirming = true
        problem = nil
        notice = nil
        // Whatever comes of this, it is asked once per return trip. Somebody
        // who cancelled at Stripe should not have the app quietly checking on
        // them every time they open it for the rest of the session.
        awaitingReturn = false
        defer { isConfirming = false }

        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            // The return page may have got here after this started. Nothing to
            // say when it did: the pilot knows they cancelled.
            if wasCancelled { return }

            if let token = await AccountStore.shared.currentAccessToken() {
                // Whether it says yes or no, the entitlement is re-read below:
                // the webhook may already have applied the subscription, in
                // which case there is nothing here to restore and Pro is on
                // anyway.
                _ = try? await SupabaseAuth.restoreWebSubscription(accessToken: token)
            }

            await Entitlements.shared.refreshFromServer()

            if Entitlements.shared.isPro { return }
        }

        // Either the payment is still settling or there was never one — a
        // cancelled checkout comes back here too, and from the outside the two
        // are the same thing. So the copy claims nothing about which it was.

        notice = "No subscription on this account yet. If you have just paid, give it a minute — the app checks again each time you open it."
    }
}
