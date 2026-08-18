import Combine
import Foundation

/// What Inflight Pro actually unlocks.
///
/// One list, used by the paywall to say what is being sold and by the gates
/// themselves to say what is locked, so the two cannot describe different
/// products. Adding a Pro feature means a case here and a `guard` where it is
/// used — nothing else.
enum ProFeature: String, CaseIterable, Identifiable {

    /// Playing back the path an aircraft has already flown.
    case replay

    /// More than a handful of watched pilots.
    case watchlist

    /// Your own aircraft and the pilots you watch, painted so you can find
    /// them in a screen full of traffic.
    case pilotColours

    /// Satellite, and the globe.
    case mapStyles

    /// A photograph across the top of your public profile, and the colour it
    /// is drawn in. Everybody gets a profile, a picture and a banner; Pro is
    /// what makes the banner yours.
    case profileBanner

    /// The whole logbook. Every flight is recorded for every account — the
    /// tracker does not stop writing things down because somebody stopped
    /// paying — and Pro is what serves the whole of it back rather than the
    /// most recent stretch.
    case logbook

    /// How many pilots a free account can watch. Low enough to be a real
    /// difference, high enough that the feature is genuinely usable free —
    /// nobody should have to pay to find out whether the list works.
    ///
    /// Lives on the feature rather than on `Entitlements` so the copy below,
    /// the gate and the paywall all read the same number.
    static let freeWatchlistLimit = 3

    /// How much of a free account's logbook is served back to it, and to
    /// anybody reading their profile.
    ///
    /// Must match `public.pilot_logbook_free_entries()` — the server is the one
    /// that actually enforces it, and this number is only what the app says out
    /// loud. If the two ever disagree the server wins and the copy is wrong,
    /// which is the failure worth avoiding.
    static let freeLogbookEntries = 20

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replay: return "Flight replay"
        case .watchlist: return "The whole watchlist"
        case .pilotColours: return "Your traffic, in your colours"
        case .mapStyles: return "Satellite and the globe"
        case .profileBanner: return "Your profile, your way"
        case .logbook: return "Every flight you've made"
        }
    }

    var detail: String {
        switch self {
        case .replay:
            return "Fly any aircraft's track back from departure, at your own speed."
        case .watchlist:
            return "Watch as many pilots as you like. Free keeps \(Self.freeWatchlistLimit)."
        case .pilotColours:
            return "Your own aircraft and every pilot you watch, picked out of the traffic in colours you choose."
        case .mapStyles:
            return "Imagery, and the whole planet — free to spin and tilt with the traffic on it."
        case .profileBanner:
            return "A photograph across the top of your profile, in a colour you pick. Free profiles get a painted one."
        case .logbook:
            return "Your whole logbook, not just the last \(Self.freeLogbookEntries) flights — with the fields, fleet and hours behind it."
        }
    }

    var symbol: String {
        switch self {
        case .replay: return "clock.arrow.circlepath"
        case .watchlist: return "person.2.badge.plus"
        case .pilotColours: return "paintpalette"
        case .mapStyles: return "globe"
        case .profileBanner: return "photo.on.rectangle.angled"
        case .logbook: return "book.closed"
        }
    }
}

/// The one place the app asks "is this account Pro?".
///
/// Two halves, deliberately OR-ed rather than reconciled:
///
/// - **StoreKit** — an App Store purchase held on the device and tied to the
///   Apple Account. Apple has signed for it, it needs no network, and it is
///   what the paywall sells. This is the half that must act the instant
///   somebody taps Buy.
/// - **The account** — `pro_entitlement()` on the server, which folds together
///   an App Store purchase linked to this account, the web subscription sold
///   on inflight.info, and the `legacy_pro` grandfathering flag. Somebody who
///   has been paying on the website for a year should not be charged again for
///   installing the iOS app.
///
/// The flow between them goes one way and only one: the app posts its
/// Apple-signed transactions up so the *website* honours a purchase made here,
/// and the server never writes anything back down that the device would then
/// treat as proof. A client that can set its own entitlement is a client that
/// can grant itself Pro.
///
/// ## Where a gate belongs
///
/// **In the store or the model, not in the view.** A `guard` in a button's
/// action is a gate on one way in; the moment a second screen, a widget, a
/// URL scheme or a shortcut reaches the same feature, the check is somewhere
/// the new caller has never heard of. Every gate in this app is therefore
/// enforced at the point the state actually changes — `FriendsStore.add`,
/// `FlightReplay.start`, `PilotHighlighting.current` — and the views call the
/// same predicates only to decide what to *draw*: a lock instead of a tick, a
/// paywall instead of an action.
///
/// **And again on the server, for anything a client could write.** The gates
/// here decide what this app offers. They are not what makes Pro Pro: a
/// profile banner is refused by a trigger on `pilot_profiles`, and the whole
/// logbook is served or withheld by `pilot_logbook_entries()`. Anything that
/// lives only in this file is a suggestion, because PostgREST is a public API
/// and a client is a thing that can be modified.
final class Entitlements: ObservableObject {

    static let shared = Entitlements()

    @Published private(set) var isPro = false

    /// Why it is unlocked, for the account panel to say so plainly. Someone
    /// whose Pro came from the web subscription should not be shown a "Restore
    /// purchases" button as if their entitlement were an App Store one.
    enum Source: Equatable {
        case free
        case appStore
        case subscription
        case legacy
    }

    @Published private(set) var source: Source = .free

    private init() {}

    /// Called by `ProStore` and `AccountStore` when either half changes. They
    /// push rather than this pulling, because both of them own state this
    /// object has no business reaching into.
    func accountChanged() { recompute() }

    func storeChanged() { recompute() }

    func has(_ feature: ProFeature) -> Bool { isPro }

    /// Whether one more pilot can go on the watchlist.
    ///
    /// The cap is on *adding*, never on what is already there: someone who
    /// watched a dozen pilots before this shipped keeps all twelve, and only
    /// finds out about the limit when they go past it again. Silently dropping
    /// names off an existing list to enforce a new rule would be indefensible.
    func canWatchMore(current: Int) -> Bool {
        isPro || current < ProFeature.freeWatchlistLimit
    }

    /// Re-asks both halves what this account is entitled to.
    ///
    /// Called when the app comes back to the foreground. Pro can lapse, be
    /// refunded, or be bought on another device while this one sits open on a
    /// map, and until this existed none of those reached a running app: the
    /// entitlement was computed at launch, at sign-in and after a purchase, and
    /// then believed indefinitely. A tracker is an app people leave open for
    /// hours, so "indefinitely" was measured in flights.
    ///
    /// Both halves, because they fail differently: StoreKit answers offline and
    /// covers a renewal, the server covers a web subscription ending and a
    /// refund Apple has not yet told this device about.
    @MainActor
    func refreshFromServer() async {
        await ProStore.shared.refreshEntitlement()
        await AccountStore.shared.refreshEntitlement()
        recompute()
    }

    private func recompute() {
        let account = AccountStore.shared.account

        // The device's own receipt first: StoreKit has Apple's signature for
        // it, it needs no network, and it is what somebody who has just
        // tapped Buy expects to see act immediately.
        let resolved: Source
        if ProStore.shared.isPurchased {
            resolved = .appStore
        } else if account?.isAppStorePro == true {
            // An App Store purchase this account owns but this Apple Account
            // does not — bought on a different Apple ID, or before a restore.
            resolved = .appStore
        } else if account?.proSource == "subscription" || account?.proSource == "grace" {
            resolved = .subscription
        } else if account?.isPro == true {
            resolved = .legacy
        } else {
            resolved = .free
        }

        if source != resolved { source = resolved }

        let unlocked = resolved != .free
        if isPro != unlocked { isPro = unlocked }
    }
}
