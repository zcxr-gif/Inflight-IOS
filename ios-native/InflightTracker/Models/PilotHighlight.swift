import SwiftUI
import UIKit

/// Colouring the aircraft that matter to you.
///
/// The Capacitor build did this with a Mapbox colour expression — see
/// `getPremiumColorExpression()` in `old/www/profileUI.js`, which painted your
/// own aircraft amber and your watchlist purple. Those two defaults are carried
/// over exactly, because people recognise them.
///
/// What is different is where the colour comes from. These are real
/// preferences rather than constants — and on a Pro account there is a third,
/// `friendColors`, which is a colour for one named pilot rather than for the
/// whole watchlist. Which of them the map actually uses is
/// `PilotHighlighting.current()`, not this: everything here is stored whether
/// or not the account may currently spend it, so a lapse loses nothing and a
/// renewal restores it.
final class PilotHighlightPreferences: ObservableObject {

    static let shared = PilotHighlightPreferences()

    /// `#fbbf24` — the old build's amber for your own aircraft.
    static let defaultOwn = Color(red: 0.984, green: 0.749, blue: 0.141)

    /// `#c084fc` — its amethyst for everyone on the watchlist.
    static let defaultFriend = Color(red: 0.753, green: 0.518, blue: 0.988)

    private static let enabledKey = "pilotHighlightEnabled"
    private static let ownKey = "pilotHighlightOwnColor"
    private static let friendKey = "pilotHighlightFriendColor"
    private static let perFriendKey = "pilotHighlightFriendColors"

    /// Off is a real choice, not just what free accounts get. The map is
    /// monochrome by design and some people will want it left that way.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var ownColor: Color {
        didSet { Self.store(ownColor, forKey: Self.ownKey) }
    }

    /// The colour every watched pilot is painted, unless one of them has been
    /// given a colour of their own below.
    @Published var friendColor: Color {
        didSet { Self.store(friendColor, forKey: Self.friendKey) }
    }

    /// A colour for one particular pilot, keyed by lowercased username.
    ///
    /// The Pro half of this preference, and the reason it is a map rather than
    /// a field on the watchlist: `FriendsStore` is a list of names synced to
    /// the backend against a device token, and a colour is a local decoration
    /// that has no business travelling with it. Keeping them apart also means
    /// removing somebody and adding them back does not lose what they were
    /// painted — the entry simply stops being asked about while they are off
    /// the list. `resetColors()` is the only thing that empties it.
    @Published var friendColors: [String: Color] {
        didSet { Self.storeAll(friendColors, forKey: Self.perFriendKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        ownColor = Self.read(forKey: Self.ownKey) ?? Self.defaultOwn
        friendColor = Self.read(forKey: Self.friendKey) ?? Self.defaultFriend
        friendColors = Self.readAll(forKey: Self.perFriendKey)
    }

    /// What one watched pilot is painted: their own colour if they have been
    /// given one, and the shared one if not.
    ///
    /// Answers for any name, watched or not — deciding *whether* a pilot is
    /// highlighted is `PilotHighlighting`'s job, and this is only what colour
    /// they would be.
    func color(forFriend username: String) -> Color {
        friendColors[username.lowercased()] ?? friendColor
    }

    /// Gives one pilot a colour, or takes it away again — nil puts them back on
    /// the shared one.
    func setColor(_ color: Color?, forFriend username: String) {
        let key = username.lowercased()
        guard !key.isEmpty else { return }
        if let color = color {
            friendColors[key] = color
        } else {
            friendColors.removeValue(forKey: key)
        }
    }

    /// Whether this pilot has been painted something of their own.
    func hasOwnColor(forFriend username: String) -> Bool {
        friendColors[username.lowercased()] != nil
    }

    func resetColors() {
        ownColor = Self.defaultOwn
        friendColor = Self.defaultFriend
        friendColors = [:]
    }

    // MARK: - Persistence

    /// Stored as three components rather than a hex string: `Color` has no
    /// stable archive format across OS versions, and the components are what
    /// both `Color` and `UIColor` are built from anyway.
    private static func store(_ color: Color, forKey key: String) {
        guard let parts = components(of: color) else { return }
        UserDefaults.standard.set(parts, forKey: key)
    }

    private static func read(forKey key: String) -> Color? {
        guard let parts = UserDefaults.standard.array(forKey: key) as? [Double],
              parts.count == 3 else { return nil }
        return Color(red: parts[0], green: parts[1], blue: parts[2])
    }

    /// The same three components, one array per name. A dictionary of arrays is
    /// a property-list value, so this is one write rather than a key per pilot.
    private static func storeAll(_ colors: [String: Color], forKey key: String) {
        var encoded: [String: [Double]] = [:]
        for (name, color) in colors {
            guard let parts = components(of: color) else { continue }
            encoded[name] = parts
        }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    private static func readAll(forKey key: String) -> [String: Color] {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] else {
            return [:]
        }
        var colors: [String: Color] = [:]
        for (name, parts) in stored where parts.count == 3 {
            colors[name] = Color(red: parts[0], green: parts[1], blue: parts[2])
        }
        return colors
    }

    private static func components(of color: Color) -> [Double]? {
        let ui = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return [Double(red), Double(green), Double(blue)]
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

    /// Off entirely — the preference is off, or there is nothing to highlight.
    /// Every lookup short-circuits.
    let isActive: Bool

    /// Lowercased. Empty matches nothing.
    let me: String

    /// Lowercased watched usernames.
    let watched: Set<String>

    let ownColor: Color

    /// What a watched pilot is painted when nothing more specific has been said
    /// about them. Everybody's, free or Pro — see `current()`.
    let friendColor: Color

    /// A colour for one particular pilot, keyed by lowercased username.
    ///
    /// Empty on a free account, which is the whole of the difference: a free
    /// watchlist is one colour all round, and Pro is what lets a name be given
    /// its own. Empty on a Pro account that has not painted anybody either, so
    /// the common case costs one dictionary lookup that misses.
    let friendColors: [String: Color]

    /// The colours, bridged once when the value is made.
    ///
    /// `tint` is asked about an aircraft at a time and hands its answer to the
    /// sprite cache, which wants a `UIColor`; building one there meant a bridge
    /// per painted aeroplane. Not compared — they are derived from the stored
    /// colours above, which are.
    private let ownTint: UIColor
    private let friendTint: UIColor
    private let friendTints: [String: UIColor]

    init(
        isActive: Bool = false,
        me: String = "",
        watched: Set<String> = [],
        ownColor: Color = PilotHighlightPreferences.defaultOwn,
        friendColor: Color = PilotHighlightPreferences.defaultFriend,
        friendColors: [String: Color] = [:]
    ) {
        self.isActive = isActive
        self.me = me
        self.watched = watched
        self.ownColor = ownColor
        self.friendColor = friendColor
        self.friendColors = friendColors
        self.ownTint = UIColor(ownColor)
        self.friendTint = UIColor(friendColor)
        self.friendTints = friendColors.mapValues { UIColor($0) }
    }

    static func == (lhs: PilotHighlighting, rhs: PilotHighlighting) -> Bool {
        lhs.isActive == rhs.isActive
            && lhs.me == rhs.me
            && lhs.watched == rhs.watched
            && lhs.ownColor == rhs.ownColor
            && lhs.friendColor == rhs.friendColor
            && lhs.friendColors == rhs.friendColors
    }

    /// What this flight should be painted, or nil to leave it as the sprite
    /// sheet drew it.
    ///
    /// Your own aircraft wins over the watchlist, for the case where you have
    /// somehow ended up watching yourself. Within the watchlist, a pilot's own
    /// colour wins over the shared one — that is what having picked one means.
    func tint(for username: String?) -> UIColor? {
        guard isActive, let username = username, !username.isEmpty else { return nil }

        let key = username.lowercased()
        if !me.isEmpty, key == me { return ownTint }
        guard watched.contains(key) else { return nil }
        return friendTints[key] ?? friendTint
    }

    /// The live answer, assembled from the stores. One place, so the map, the
    /// legend and anything else that wants to explain the colours cannot
    /// disagree about them.
    ///
    /// ## Where Pro is
    ///
    /// Not on *having* colours. Everybody's own aeroplane is amber and
    /// everybody's watchlist is amethyst, because a watchlist you cannot pick
    /// out of the traffic is most of the way to not having one. What Pro buys
    /// is choosing them: the two colours above, and — the part it is really
    /// for — a colour per pilot, so five friends in the circuit at the same
    /// field are five different aeroplanes rather than five of the same one.
    ///
    /// A free account is therefore handed the defaults rather than what is
    /// stored. That matters for a lapse: somebody who picked colours while
    /// they were Pro keeps them on disk and gets them back on renewal, and in
    /// between their map is the free map rather than a paid one they are no
    /// longer paying for.
    @MainActor
    static func current() -> PilotHighlighting {
        let preferences = PilotHighlightPreferences.shared

        guard preferences.isEnabled else { return PilotHighlighting() }

        let isPro = Entitlements.shared.has(.pilotColours)

        return PilotHighlighting(
            isActive: true,
            me: PilotIdentity.shared.matchKey,
            // Already lowercased, and already a set: the store keeps one.
            watched: FriendsStore.shared.watched,
            ownColor: isPro ? preferences.ownColor : defaultOwn,
            friendColor: isPro ? preferences.friendColor : defaultFriend,
            friendColors: isPro ? preferences.friendColors : [:]
        )
    }

    private static var defaultOwn: Color { PilotHighlightPreferences.defaultOwn }
    private static var defaultFriend: Color { PilotHighlightPreferences.defaultFriend }
}
