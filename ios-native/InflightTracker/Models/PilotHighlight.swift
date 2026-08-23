import SwiftUI
import UIKit

/// Colouring the aircraft that matter to you.
///
/// The Capacitor build did this with a Mapbox colour expression — see
/// `getPremiumColorExpression()` in `old/www/profileUI.js`, which painted your
/// own aircraft amber and your watchlist purple. Those two defaults are carried
/// over exactly, because people recognise them.
///
/// What is different is where the colour comes from: this is a real preference
/// rather than a constant, so the two colours are yours to pick.
final class PilotHighlightPreferences: ObservableObject {

    static let shared = PilotHighlightPreferences()

    /// `#fbbf24` — the old build's amber for your own aircraft.
    static let defaultOwn = Color(red: 0.984, green: 0.749, blue: 0.141)

    /// `#c084fc` — its amethyst for everyone on the watchlist.
    static let defaultFriend = Color(red: 0.753, green: 0.518, blue: 0.988)

    private static let enabledKey = "pilotHighlightEnabled"
    private static let ownKey = "pilotHighlightOwnColor"
    private static let friendKey = "pilotHighlightFriendColor"

    /// Off is a real choice, not just what free accounts get. The map is
    /// monochrome by design and some people will want it left that way.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var ownColor: Color {
        didSet { Self.store(ownColor, forKey: Self.ownKey) }
    }

    @Published var friendColor: Color {
        didSet { Self.store(friendColor, forKey: Self.friendKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        ownColor = Self.read(forKey: Self.ownKey) ?? Self.defaultOwn
        friendColor = Self.read(forKey: Self.friendKey) ?? Self.defaultFriend
    }

    func resetColors() {
        ownColor = Self.defaultOwn
        friendColor = Self.defaultFriend
    }

    // MARK: - Persistence

    /// Stored as three components rather than a hex string: `Color` has no
    /// stable archive format across OS versions, and the components are what
    /// both `Color` and `UIColor` are built from anyway.
    private static func store(_ color: Color, forKey key: String) {
        let ui = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        UserDefaults.standard.set([Double(red), Double(green), Double(blue)], forKey: key)
    }

    private static func read(forKey key: String) -> Color? {
        guard let parts = UserDefaults.standard.array(forKey: key) as? [Double],
              parts.count == 3 else { return nil }
        return Color(red: parts[0], green: parts[1], blue: parts[2])
    }
}

/// Everything needed to decide what colour one aircraft is drawn in, as a
/// value.
///
/// Built by the view and handed to the map, rather than the map reaching into
/// four singletons on every annotation: it is `Equatable`, so the coordinator
/// can tell in one comparison whether anything about the highlighting has
/// changed and only then repaint every sprite on screen. Adding a friend,
/// picking a new colour, signing in, or Pro lapsing all land the same way.
struct PilotHighlighting: Equatable {

    /// Off entirely — no account is Pro, the preference is off, or there is
    /// nothing to highlight. Every lookup short-circuits.
    let isActive: Bool

    /// Lowercased. Empty matches nothing.
    let me: String

    /// Lowercased watched usernames.
    let watched: Set<String>

    let ownColor: Color
    let friendColor: Color

    /// The same two colours, bridged once when the value is made.
    ///
    /// `tint` is asked about an aircraft at a time and hands its answer to the
    /// sprite cache, which wants a `UIColor`; building one there meant a bridge
    /// per painted aeroplane. Not compared — they are derived from the two
    /// above, which are.
    private let ownTint: UIColor
    private let friendTint: UIColor

    init(
        isActive: Bool = false,
        me: String = "",
        watched: Set<String> = [],
        ownColor: Color = PilotHighlightPreferences.defaultOwn,
        friendColor: Color = PilotHighlightPreferences.defaultFriend
    ) {
        self.isActive = isActive
        self.me = me
        self.watched = watched
        self.ownColor = ownColor
        self.friendColor = friendColor
        self.ownTint = UIColor(ownColor)
        self.friendTint = UIColor(friendColor)
    }

    static func == (lhs: PilotHighlighting, rhs: PilotHighlighting) -> Bool {
        lhs.isActive == rhs.isActive
            && lhs.me == rhs.me
            && lhs.watched == rhs.watched
            && lhs.ownColor == rhs.ownColor
            && lhs.friendColor == rhs.friendColor
    }

    /// What this flight should be painted, or nil to leave it as the sprite
    /// sheet drew it.
    ///
    /// Your own aircraft wins over the watchlist, for the case where you have
    /// somehow ended up watching yourself.
    func tint(for username: String?) -> UIColor? {
        guard isActive, let username = username, !username.isEmpty else { return nil }

        let key = username.lowercased()
        if !me.isEmpty, key == me { return ownTint }
        if watched.contains(key) { return friendTint }
        return nil
    }

    /// The live answer, assembled from the stores. One place, so the map, the
    /// legend and anything else that wants to explain the colours cannot
    /// disagree about them.
    @MainActor
    static func current() -> PilotHighlighting {
        let preferences = PilotHighlightPreferences.shared

        guard Entitlements.shared.has(.pilotColours), preferences.isEnabled else {
            return PilotHighlighting()
        }

        return PilotHighlighting(
            isActive: true,
            me: PilotIdentity.shared.matchKey,
            // Already lowercased, and already a set: the store keeps one.
            watched: FriendsStore.shared.watched,
            ownColor: preferences.ownColor,
            friendColor: preferences.friendColor
        )
    }
}
