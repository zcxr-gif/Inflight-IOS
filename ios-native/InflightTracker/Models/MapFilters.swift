import Foundation
import SwiftUI

/// Which line an open flight gets drawn ahead of it — and it is one line or
/// the other, never both.
///
/// The two answer the same question, "where is this aeroplane going", and they
/// answer it differently: the plan is the route as filed, bending through every
/// fix on it, and the direct line is the great circle to the destination
/// ignoring all of that. Drawn together they cross each other repeatedly on any
/// route with a dogleg in it, and the picture is two claims about the same
/// flight with nothing to say which is which.
///
/// So this is a choice rather than a pair of switches, which is also the honest
/// shape of it: nobody wants both.
enum RouteLineMode: String, CaseIterable, Identifiable {

    /// Neither. The flown track behind the aeroplane is a separate switch and
    /// is untouched by this — what it has done is not a claim about where it is
    /// going.
    case off

    /// The great circle from the aeroplane to its filed destination, moving
    /// with it. Nothing to fetch, and it is drawn for every flight with a
    /// destination filed, which is most of them.
    case direct

    /// The plan as filed: the line through every fix, and the fixes named.
    /// Fetched per aircraft, and there is nothing to draw for the many pilots
    /// who file no plan at all.
    case filedPlan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .direct: return "Direct"
        case .filedPlan: return "Filed"
        }
    }

    /// What the panel says under the picker once this one is chosen.
    var detail: String {
        switch self {
        case .off:
            return "No line ahead of the aeroplane. The flown path behind it has its own switch below."
        case .direct:
            return "A dashed great-circle line from the aeroplane straight to its destination, moving with it as it flies. Drawn for any flight with a destination filed."
        case .filedPlan:
            return "The route as filed — a dashed line through every fix, with the one being flown to picked out. Procedures are expanded to the fixes they contain. Drawn on the flat map and the planet alike. Most pilots file nothing, and nothing is drawn when they haven't."
        }
    }
}

/// What of the server's traffic the map is drawing.
///
/// The feed is whole — every filter here is a view onto the aircraft already
/// received, so nothing has to be re-fetched when one is flipped and turning
/// them all back on is instant. Choices persist, because a filter you set once
/// (say, hiding everything parked on the ground) is one you meant to keep.
final class MapFilters: ObservableObject {

    static let shared = MapFilters()

    private static let phasesKey = "mapFilterPhases"
    /// Versioned, and it has to be.
    ///
    /// Bands are stored by index, and the altitude ramp went from four bands to
    /// seven when it gained real colours. A stored `[0, 1, 2, 3]` from before
    /// that — which is what "all of them" looked like — would survive the
    /// update and now mean "nothing above 25,000 ft", quietly emptying the
    /// cruise off everybody's map with a filter they never set. Changing the
    /// key discards those selections instead, so every install starts the new
    /// ramp with all seven on.
    private static let bandsKey = "mapFilterAltitudeBandsV2"
    private static let categoriesKey = "mapFilterCategories"
    private static let filedOnlyKey = "mapFilterFiledRouteOnly"
    private static let airportsKey = "mapShowsAirports"
    private static let groundKey = "mapShowsGroundLayout"

    /// Phases still being drawn. Empty would mean an empty map, so the panel
    /// never lets the last one be turned off.
    @Published var phases: Set<FlightPhase> {
        didSet { persist() }
    }

    /// Altitude bands still being drawn, by `AltitudeBand`'s own indices — the
    /// same bands that colour a flown path, so the filter and the map agree on
    /// what "low" means.
    @Published var bands: Set<Int> {
        didSet { persist() }
    }

    /// Kinds of aircraft still being drawn, by the sprite key each one
    /// resolved to at parse time. Same rule as the phases: the last one on
    /// cannot be turned off.
    @Published var categories: Set<AircraftCategory> {
        didSet { persist() }
    }

    /// Only aircraft with a destination filed. The tracker is at its most
    /// useful when it is showing flights that are going somewhere.
    @Published var filedRouteOnly: Bool {
        didSet { persist() }
    }

    /// Whether controlled and busy fields are marked on the map.
    ///
    /// Not counted as an active filter below: the others *narrow* what the map
    /// shows and the badge exists to say the map is not showing everything.
    /// This adds to it, so badging it would mean the toolbar reported the map
    /// as filtered for turning something on.
    @Published var showsAirports: Bool {
        didSet { UserDefaults.standard.set(showsAirports, forKey: Self.airportsKey) }
    }

    /// Whether a field's pavement is drawn once the map is close enough to it
    /// — runways, taxiways, aprons and terminals, with the runway designators.
    ///
    /// Uncounted for the same reason as the fields above: it adds to the map
    /// rather than narrowing it.
    @Published var showsGroundLayout: Bool {
        didSet { UserDefaults.standard.set(showsGroundLayout, forKey: Self.groundKey) }
    }

    /// Which line is drawn ahead of an open flight — the filed plan, the
    /// direct line to its destination, or neither.
    ///
    /// Uncounted as a filter for the same reason as the two above: it adds to
    /// the map rather than narrowing it. Defaults to the filed plan, which is
    /// the more informative of the two where there is one to draw.
    ///
    /// Only the map's layer, and only the map's. The plan store behind it is
    /// shared — the flight window's route card and the navigation display both
    /// read it — so choosing anything here never throws that cache away.
    @Published var routeLine: RouteLineMode {
        didSet { UserDefaults.standard.set(routeLine.rawValue, forKey: Self.routeLineKey) }
    }

    /// Whether the fixes on an open flight's filed plan are drawn.
    ///
    /// It costs one request per aircraft whose window is opened, cached for ten
    /// minutes, and nothing at all for the many pilots who file no plan.
    var showsFlightPlan: Bool { routeLine == .filedPlan }

    /// Whether the great circle from the open aircraft to its destination is
    /// drawn. Costs nothing — it is two coordinates the feed already carries.
    var showsDirectLine: Bool { routeLine == .direct }

    /// Whether each fix on a drawn plan is named.
    ///
    /// Its own switch rather than part of the picker above, because the two
    /// answer different questions and one of them has a real cost on screen. A
    /// transatlantic plan is thirty or forty fixes; at a zoom that fits the
    /// whole route, thirty five-character names laid along one line is a smear
    /// rather than a route, and the *shape* — which is what you were looking at
    /// — disappears underneath its own labelling. Turning the names off leaves
    /// the diamonds, so the plan still reads as a plan with somewhere to be at
    /// every corner.
    ///
    /// On by default: the names are most of why a plan is worth plotting rather
    /// than drawing its two ends, and a switch nobody finds is a switch nobody
    /// has.
    ///
    /// Honoured by both maps. Anything about a layer that is true on the flat
    /// map and not on the planet is a setting that appears to do nothing
    /// depending on which shape you happen to be on.
    @Published var showsPlanFixNames: Bool {
        didSet { UserDefaults.standard.set(showsPlanFixNames, forKey: Self.planNamesKey) }
    }

    /// Whether a fix on a drawn plan gets its name — the switch above, and only
    /// where there is a plan being drawn to put names on.
    var showsPlanNames: Bool { showsFlightPlan && showsPlanFixNames }

    /// Whether the open aircraft's flown track is drawn on the map — the
    /// coloured line behind it showing where it has actually been.
    ///
    /// Uncounted as a filter, like the layers around it: it adds to the map
    /// rather than narrowing it. On by default, because the track is most of
    /// what makes an open flight worth opening — the numbers say where it is,
    /// and only the path says what it has done to get there.
    ///
    /// Separate from `showsFlightPlan` and deliberately so. The plan is what
    /// the pilot *intends*; this is what they have *flown*, which on most
    /// flights is a visibly different line. Having one switch for both meant
    /// there was no way to look at either on its own.
    @Published var showsFlownPath: Bool {
        didSet { UserDefaults.standard.set(showsFlownPath, forKey: Self.flownKey) }
    }

    /// Whether the North Atlantic organised tracks are drawn.
    ///
    /// Uncounted as a filter, like the layers above it, and off by default —
    /// it is a dozen coloured lines across one ocean, which is exactly what
    /// somebody watching the North Atlantic wants and clutter to everybody
    /// else. One request an hour while it is on, and none at all while it is
    /// not.
    @Published var showsNatTracks: Bool {
        didSet { UserDefaults.standard.set(showsNatTracks, forKey: Self.natKey) }
    }

    /// Whether the airspace of every staffed sector is drawn.
    ///
    /// **Off by default**, and the only new layer that is off for a reason
    /// other than cost: it is a lot of ink. A busy evening on the expert server
    /// is thirty outlined sectors across two continents, which is exactly what
    /// somebody watching controlled airspace wants and a second map drawn over
    /// the first for everybody else.
    ///
    /// Stored plainly here and gated where it is *read* — see
    /// `showsAtcBoundaries`. The stored choice is left alone by a lapsed
    /// subscription, the same way the planet's colours are, so it comes back
    /// switched on rather than forgotten.
    @Published var wantsAtcBoundaries: Bool {
        didSet { UserDefaults.standard.set(wantsAtcBoundaries, forKey: Self.atcBoundariesKey) }
    }

    /// Whether the layer is actually drawn: asked for, and paid for.
    ///
    /// Resolved here rather than guarded at the switch, which is the same
    /// arrangement `FlightInfoAppearance.resolvedGlobeSkin` has and for the
    /// same reason — both maps and the settings row read this one answer, so
    /// none of them can disagree about whether the layer is on.
    var showsAtcBoundaries: Bool {
        wantsAtcBoundaries && Entitlements.shared.has(.atcBoundaries)
    }

    /// Whether the half of the world that is in darkness is washed over.
    ///
    /// Uncounted as a filter, like the layers around it. On by default and it
    /// is the only new layer that is: it costs nothing — the sun's position is
    /// arithmetic on the device, with nothing to fetch and nothing that can be
    /// stale but the clock — and knowing whether the aeroplane you are watching
    /// is flying into the night is most of what makes a tracker feel live.
    @Published var showsTerminator: Bool {
        didSet { UserDefaults.standard.set(showsTerminator, forKey: Self.terminatorKey) }
    }

    private static let routeLineKey = "map.routeLine"

    /// The switch this replaced, read once so an upgrade lands on the setting
    /// the pilot already had. It said whether the filed plan was drawn, and the
    /// direct line was drawn underneath it either way — so somebody who turned
    /// it off had asked, as clearly as the old panel let them, for the direct
    /// line on its own.
    private static let legacyPlanKey = "map.showsFlightPlan"
    private static let flownKey = "map.showsFlownPath"
    private static let planNamesKey = "map.showsPlanFixNames"
    private static let atcBoundariesKey = "map.showsAtcBoundaries"
    private static let natKey = "map.showsNatTracks"
    private static let terminatorKey = "map.showsTerminator"

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.routeLineKey),
           let mode = RouteLineMode(rawValue: stored) {
            routeLine = mode
        } else {
            // Nothing stored: either a fresh install, which gets the plan, or
            // an upgrade, which gets whichever line it was already looking at.
            routeLine = (defaults.object(forKey: Self.legacyPlanKey) as? Bool ?? true)
                ? .filedPlan
                : .direct
        }
        showsFlownPath = defaults.object(forKey: Self.flownKey) as? Bool ?? true
        showsPlanFixNames = defaults.object(forKey: Self.planNamesKey) as? Bool ?? true
        // Off unless somebody has asked for it, which is what "auto off" means.
        wantsAtcBoundaries = defaults.bool(forKey: Self.atcBoundariesKey)
        showsNatTracks = defaults.bool(forKey: Self.natKey)
        showsTerminator = defaults.object(forKey: Self.terminatorKey) as? Bool ?? true
        // On by default: the fields being worked are the most useful thing on
        // the map after the traffic, and a feature nobody finds is a feature
        // nobody has.
        showsAirports = defaults.object(forKey: Self.airportsKey) as? Bool ?? true
        // On by default, and it costs nothing until the map is over a field:
        // a layer nobody discovers is a layer nobody has.
        showsGroundLayout = defaults.object(forKey: Self.groundKey) as? Bool ?? true

        // No stored value means everything is on, which is the map as it was
        // before any of this existed.
        if let raw = defaults.array(forKey: Self.phasesKey) as? [String], !raw.isEmpty {
            phases = Set(raw.compactMap(FlightPhase.init(rawValue:)))
        } else {
            phases = Set(FlightPhase.allCases)
        }

        if let raw = defaults.array(forKey: Self.bandsKey) as? [Int], !raw.isEmpty {
            // Intersected with what exists today: a band index that no longer
            // maps onto anything is a filter nothing can satisfy.
            bands = Set(raw).intersection(AltitudeBand.all)
        } else {
            bands = Set(AltitudeBand.all)
        }

        if let raw = defaults.array(forKey: Self.categoriesKey) as? [String], !raw.isEmpty {
            categories = Set(raw.compactMap(AircraftCategory.init(rawValue:)))
        } else {
            categories = Set(AircraftCategory.allCases)
        }

        filedRouteOnly = defaults.bool(forKey: Self.filedOnlyKey)

        // A stored set that no longer maps onto anything — a phase renamed,
        // say — would hide the whole map with no way back except a reset.
        if phases.isEmpty { phases = Set(FlightPhase.allCases) }
        if bands.isEmpty { bands = Set(AltitudeBand.all) }
        if categories.isEmpty { categories = Set(AircraftCategory.allCases) }
    }

    // MARK: - State

    /// Whether anything is actually being held back, which is what the toolbar
    /// marks so a filtered map is never a mystery.
    var isFiltering: Bool {
        phases.count != FlightPhase.allCases.count
            || bands.count != AltitudeBand.all.count
            || categories.count != AircraftCategory.allCases.count
            || filedRouteOnly
    }

    /// A stamp of everything `apply` looks at.
    ///
    /// The map keys its annotation diff on this and on the packet: between them
    /// they say whether the traffic it should be drawing can possibly have
    /// changed, in one integer rather than a walk over the server.
    var signature: Int {
        var hasher = Hasher()
        hasher.combine(phases)
        hasher.combine(bands)
        hasher.combine(categories)
        hasher.combine(filedRouteOnly)
        return hasher.finalize()
    }

    /// How many of the groups are narrowed. Shown on the toolbar rather than a
    /// count of hidden aircraft, which would tick about on every packet.
    var activeCount: Int {
        var count = 0
        if phases.count != FlightPhase.allCases.count { count += 1 }
        if bands.count != AltitudeBand.all.count { count += 1 }
        if categories.count != AircraftCategory.allCases.count { count += 1 }
        if filedRouteOnly { count += 1 }
        return count
    }

    func reset() {
        phases = Set(FlightPhase.allCases)
        bands = Set(AltitudeBand.all)
        categories = Set(AircraftCategory.allCases)
        filedRouteOnly = false
    }

    /// Flips one phase, unless it is the only one left on.
    func toggle(_ phase: FlightPhase) {
        if phases.contains(phase) {
            guard phases.count > 1 else { return }
            phases.remove(phase)
        } else {
            phases.insert(phase)
        }
    }

    func toggle(band: Int) {
        if bands.contains(band) {
            guard bands.count > 1 else { return }
            bands.remove(band)
        } else {
            bands.insert(band)
        }
    }

    func toggle(category: AircraftCategory) {
        if categories.contains(category) {
            guard categories.count > 1 else { return }
            categories.remove(category)
        } else {
            categories.insert(category)
        }
    }

    // MARK: - Application

    func matches(_ flight: Flight) -> Bool {
        guard phases.contains(FlightPhase.from(flight)) else { return false }
        guard bands.contains(AltitudeBand.band(forFeet: flight.altitudeFeet)) else { return false }
        guard categories.contains(AircraftCategory.from(spriteKey: flight.spriteKey)) else { return false }

        if filedRouteOnly {
            let arrival = flight.arrivalIcao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !arrival.isEmpty else { return false }
        }

        return true
    }

    /// The traffic the map should draw.
    ///
    /// `keeping` is the open aircraft: its window reads from the feed by id and
    /// stays up regardless, so dropping its annotation would leave the sheet
    /// describing a plane that isn't on the map — and the route drawn under it
    /// with nothing at the head of it.
    func apply(to flights: [Flight], keeping selectedId: String? = nil) -> [Flight] {
        guard isFiltering else { return flights }

        return flights.filter { flight in
            flight.id == selectedId || matches(flight)
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(phases.map(\.rawValue), forKey: Self.phasesKey)
        defaults.set(Array(bands), forKey: Self.bandsKey)
        defaults.set(categories.map(\.rawValue), forKey: Self.categoriesKey)
        defaults.set(filedRouteOnly, forKey: Self.filedOnlyKey)
    }
}
