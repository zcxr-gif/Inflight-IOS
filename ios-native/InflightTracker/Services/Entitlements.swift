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

    /// How many pilots a free account can watch. Low enough to be a real
    /// difference, high enough that the feature is genuinely usable free —
    /// nobody should have to pay to find out whether the list works.
    ///
    /// Lives on the feature rather than on `Entitlements` so the copy below,
    /// the gate and the paywall all read the same number.
    static let freeWatchlistLimit = 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replay: return "Flight replay"
        case .watchlist: return "The whole watchlist"
        }
    }

    var detail: String {
        switch self {
        case .replay:
            return "Fly any aircraft's track back from departure, at your own speed."
        case .watchlist:
            return "Watch as many pilots as you like. Free keeps \(Self.freeWatchlistLimit)."
        }
    }

    var symbol: String {
        switch self {
        case .replay: return "clock.arrow.circlepath"
        case .watchlist: return "person.2.badge.plus"
        }
    }
}

/// The one place the app asks "is this account Pro?".
///
/// Two things can grant it and they are deliberately OR-ed rather than
/// reconciled:
///
/// - **StoreKit** — an App Store purchase of `AppConfig.proProductID`, held on
///   the device and tied to the Apple Account. This is what the paywall sells.
/// - **The account's `profiles` row** — the web subscription, and the
///   `legacy_pro` grandfathering flag. Someone who has been paying on
///   inflight.info for a year should not be charged again for installing the
///   iOS app.
///
/// Nothing flows the other way: an App Store purchase is *not* written back to
/// `profiles`. It could only be written by the client, and a client that can
/// set its own `is_pro` is a client that can grant itself Pro — so the device
/// keeps its own receipt and the cloud keeps its own, and either is enough.
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

    private func recompute() {
        let account = AccountStore.shared.account

        let resolved: Source
        if ProStore.shared.isPurchased {
            resolved = .appStore
        } else if account?.isPro == true {
            resolved = .subscription
        } else if account?.isLegacyPro == true {
            resolved = .legacy
        } else {
            resolved = .free
        }

        if source != resolved { source = resolved }

        let unlocked = resolved != .free
        if isPro != unlocked { isPro = unlocked }
    }
}
