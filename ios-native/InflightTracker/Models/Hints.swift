import Foundation

/// Where in the app a hint belongs.
///
/// A hint is only worth reading next to the thing it is about, so there is no
/// general pool — each place asks for its own, and a place with nothing left to
/// say shows nothing at all.
enum HintPlacement: String {
    case map
    case flight
    case airport
    case airports
    case atc
    case friends
    case filters
    case weather
}

/// One line of guidance about the part of the app it is sitting in.
///
/// Deliberately not a tour and not a first-run overlay: nothing here blocks
/// anything, and every line is something the app can genuinely do rather than a
/// caption of what is already on screen. A hint that tells you what the button
/// under it is called is noise.
struct Hint: Identifiable, Equatable {

    /// Stable across releases — it is the key the "seen" count is stored
    /// against, so renaming one silently un-retires it for everybody.
    let id: String

    let placement: HintPlacement
    let text: String

    /// Everything the app has to say, in the order each place says it.
    ///
    /// Every line here is a claim about behaviour, so each one has to stay true
    /// as the code changes — a hint that lies is worse than no hint, because it
    /// is read as documentation.
    static let all: [Hint] = [

        // MARK: The map

        Hint(
            id: "map.search",
            placement: .map,
            text: "Search finds callsigns, pilot names, registrations and ICAO codes — all of it from what is already on the device, so it answers as you type."
        ),
        Hint(
            id: "map.airports",
            placement: .map,
            text: "Airports shows where the server actually is: the busiest fields right now, ranked by what pilots have filed."
        ),
        Hint(
            id: "map.atc",
            placement: .map,
            text: "ATC lists everyone on frequency. Tap a field to see what is landing there."
        ),
        Hint(
            id: "map.zoom",
            placement: .map,
            text: "There is no cap on how many aircraft the map draws. Zoom out as far as you like — if the server has two thousand aeroplanes in view, you get two thousand."
        ),
        Hint(
            id: "map.filters",
            placement: .map,
            text: "Filters change only what is drawn, never what is received, so turning them all back on is instant."
        ),

        // MARK: A flight

        Hint(
            id: "flight.drag",
            placement: .flight,
            text: "Drag this window down to its peek and the map stays live behind it — you can pan and zoom without closing the flight."
        ),
        Hint(
            id: "flight.follow",
            placement: .flight,
            text: "The viewfinder button beside the window keeps the map with this aircraft as it flies, instead of you re-centring it."
        ),
        Hint(
            id: "flight.replay",
            placement: .flight,
            text: "Replay flies the track this aircraft has already covered, at whatever speed you set."
        ),
        Hint(
            id: "flight.watch",
            placement: .flight,
            text: "Watch a pilot and you will get a notification when they take off and when they land, even with the app closed."
        ),
        Hint(
            id: "flight.pin",
            placement: .flight,
            text: "Pin puts this flight on the home-screen widget, drawn on the aircraft's own photo."
        ),
        Hint(
            id: "flight.route",
            placement: .flight,
            text: "Tap either end of the route to open that airport — its weather, who is on frequency, and everything else heading there. The way back is the first row."
        ),
        Hint(
            id: "flight.controlled",
            placement: .flight,
            text: "An aerial beside an airport code means somebody is working that field right now."
        ),

        // MARK: One field

        Hint(
            id: "airport.rows",
            placement: .airport,
            text: "Every aircraft listed here opens its own window."
        ),
        Hint(
            id: "airport.eta",
            placement: .airport,
            text: "Inbound is ordered by how long each aircraft has to run at its current ground speed — not by how far out it is."
        ),
        Hint(
            id: "airport.parked",
            placement: .airport,
            text: "Aircraft that filed here but have not left their gate sort to the bottom of Inbound, marked Parked."
        ),

        // MARK: The board

        Hint(
            id: "airports.filed",
            placement: .airports,
            text: "The board counts flight plans, not aeroplanes on the ground. A field can be busy here before anyone has pushed back."
        ),
        Hint(
            id: "airports.controlled",
            placement: .airports,
            text: "The aerial badge means someone is on frequency there."
        ),

        // MARK: Controllers

        Hint(
            id: "atc.tap",
            placement: .atc,
            text: "Tap any field to open it: the same controllers, plus its weather and everything inbound."
        ),
        Hint(
            id: "atc.centre",
            placement: .atc,
            text: "Centre positions work an airspace rather than an airport, so they are listed apart — there is no field to open behind one."
        ),

        // MARK: Friends

        Hint(
            id: "friends.name",
            placement: .friends,
            text: "Add a pilot by their Infinite Flight display name, spelled the way it appears on the map."
        ),
        Hint(
            id: "friends.device",
            placement: .friends,
            text: "A live banner raised by someone's takeoff needs a real device — the token it starts from is one the simulator never issues."
        ),

        // MARK: Filters

        Hint(
            id: "filters.altitude",
            placement: .filters,
            text: "The altitude colours here are the same ones the map paints a flown path in, so the filter and the track agree on what \"low\" means."
        ),
        Hint(
            id: "filters.aircraft",
            placement: .filters,
            text: "Aircraft kinds come from the same table that picks each plane's icon, so anything the map can draw, this can narrow down to."
        ),

        // MARK: Weather

        Hint(
            id: "weather.cache",
            placement: .weather,
            text: "Reports are held for as long as they stay current, so panning around a busy area never re-fetches the same field."
        ),
        Hint(
            id: "weather.units",
            placement: .weather,
            text: "Units are a display choice. Reports arrive the same either way, so switching costs nothing and is instant."
        )
    ]
}

/// Which hints have been read, and whether to show them at all.
///
/// The rule is that a hint retires: it appears in a few separate sessions and
/// then never again, because a tip you have read four times has stopped being a
/// tip and become furniture. Dismissing one retires it immediately.
final class HintsStore: ObservableObject {

    static let shared = HintsStore()

    private static let enabledKey = "hintsEnabled"
    private static let shownKey = "hintsShownCounts"

    /// How many separate launches a hint appears in before retiring.
    ///
    /// Counted per launch rather than per appearance on screen: a place like
    /// the map is left and returned to constantly within one session, and
    /// counting those would burn the whole catalogue in an afternoon without
    /// anyone having read a word of it.
    static let appearances = 3

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Bumped whenever what a place should be showing changes — one dismissed,
    /// or all of them restored. Published, so a strip already on screen
    /// re-asks instead of sitting on a line that has been retired underneath it.
    @Published private(set) var revision = 0

    private var shown: [String: Int]

    /// Hints already counted in this launch — see `appearances`.
    private var countedThisLaunch: Set<String> = []

    /// What each place settled on this launch.
    ///
    /// The choice is memoised because it has to be stable: a strip reads it
    /// straight out of its `body`, which SwiftUI runs whenever it likes, and a
    /// line that changed between redraws would be unreadable. The outer
    /// optional is "has this place been asked yet", the inner one is "and it
    /// had nothing to say" — which is why this is a dictionary of optionals
    /// rather than a plain one.
    private var chosen: [HintPlacement: Hint?] = [:]

    private init() {
        let defaults = UserDefaults.standard

        // No stored value means the user has never chosen, and hints are the
        // app as it ships.
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        shown = defaults.object(forKey: Self.shownKey) as? [String: Int] ?? [:]
    }

    /// How many hints have been read out or dismissed, for the settings row
    /// that offers them back.
    var retiredCount: Int {
        var count = 0
        for hint in Hint.all where (shown[hint.id] ?? 0) >= Self.appearances {
            count += 1
        }
        return count
    }

    /// What this place is saying this launch, or nil once it has said all of it.
    ///
    /// Safe to call from a view's `body`: the first call for a place picks a
    /// hint and counts it as shown, and every call after that returns the same
    /// answer without touching anything. Nothing it writes is published, so
    /// reading it while SwiftUI is building a view cannot start an update of
    /// its own.
    func current(for placement: HintPlacement) -> Hint? {
        if let memoised = chosen[placement] { return memoised }

        let pick = next(for: placement)
        chosen[placement] = pick
        if let pick = pick { markShown(pick) }
        return pick
    }

    /// The least-shown hint this place still has, or nil when it has none left.
    ///
    /// Showing one increments its count, so the catalogue rotates between
    /// launches by itself rather than needing a cursor stored anywhere. Ties go
    /// to whichever comes first in `Hint.all`.
    private func next(for placement: HintPlacement) -> Hint? {
        // A loop rather than filter-then-min. Chaining two closures whose
        // bodies are optional-coalesced dictionary lookups is the shape that
        // defeated the type checker in `AirportTraffic.busiest`, and this is
        // not worth finding that out from a ten-minute build.
        var best: Hint?
        var bestCount = Self.appearances

        for hint in Hint.all where hint.placement == placement {
            let count = shown[hint.id] ?? 0
            // Strictly less, so ties go to the earlier entry in `Hint.all` and
            // the order a place says things in stays the written one.
            if count < bestCount {
                best = hint
                bestCount = count
            }
        }

        return best
    }

    private func markShown(_ hint: Hint) {
        guard !countedThisLaunch.contains(hint.id) else { return }
        countedThisLaunch.insert(hint.id)
        shown[hint.id, default: 0] += 1
        persist()
    }

    /// Dismissed by hand: retired there and then rather than after its
    /// remaining appearances, because dismissing one is the reader saying they
    /// are done with it. The place is left with nothing rather than moving
    /// straight on to the next line, which would read as the × having failed.
    func dismiss(_ hint: Hint) {
        shown[hint.id] = Self.appearances
        chosen[hint.placement] = .some(nil)
        persist()
        revision += 1
    }

    func restoreAll() {
        shown.removeAll()
        countedThisLaunch.removeAll()
        chosen.removeAll()
        persist()
        revision += 1
    }

    private func persist() {
        UserDefaults.standard.set(shown, forKey: Self.shownKey)
    }
}
