import Foundation
import SwiftUI

/// What of the server's traffic the map is drawing.
///
/// The feed is whole — every filter here is a view onto the aircraft already
/// received, so nothing has to be re-fetched when one is flipped and turning
/// them all back on is instant. Choices persist, because a filter you set once
/// (say, hiding everything parked on the ground) is one you meant to keep.
final class MapFilters: ObservableObject {

    static let shared = MapFilters()

    private static let phasesKey = "mapFilterPhases"
    private static let bandsKey = "mapFilterAltitudeBands"
    private static let categoriesKey = "mapFilterCategories"
    private static let filedOnlyKey = "mapFilterFiledRouteOnly"

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

    private init() {
        let defaults = UserDefaults.standard

        // No stored value means everything is on, which is the map as it was
        // before any of this existed.
        if let raw = defaults.array(forKey: Self.phasesKey) as? [String], !raw.isEmpty {
            phases = Set(raw.compactMap(FlightPhase.init(rawValue:)))
        } else {
            phases = Set(FlightPhase.allCases)
        }

        if let raw = defaults.array(forKey: Self.bandsKey) as? [Int], !raw.isEmpty {
            bands = Set(raw)
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

    // MARK: - Quick filters

    /// The narrowings worth one tap, for the row of chips under the search
    /// field.
    ///
    /// Not a second filter model — every one of these is a shorthand for a
    /// state the panel can already express, and each reads its own selected
    /// state back off the live filter. So a chip is lit exactly when the map is
    /// in that state however it got there, and the two controls can never
    /// disagree about what is being shown.
    enum QuickFilter: String, CaseIterable, Identifiable {

        case all
        case airborne
        case airliners
        case regional
        case light
        case military
        case helicopters
        case filed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All traffic"
            case .airborne: return "Airborne"
            case .airliners: return "Airliners"
            case .regional: return "Regional"
            case .light: return "Light"
            case .military: return "Military"
            case .helicopters: return "Helicopters"
            case .filed: return "Filed route"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "circle.grid.2x2"
            case .airborne: return "arrow.up.forward"
            case .airliners: return "airplane"
            case .regional: return "airplane.departure"
            case .light: return "paperplane"
            case .military: return "shield"
            case .helicopters: return "fan.desk"
            case .filed: return "point.topleft.down.to.point.bottomright.curvepath"
            }
        }

        /// The aircraft group this chip narrows to, for the four that are about
        /// what is flying rather than about what it is doing.
        var category: AircraftCategory? {
            switch self {
            case .airliners: return .airliner
            case .regional: return .regional
            case .light: return .light
            case .military: return .military
            case .helicopters: return .helicopter
            case .all, .airborne, .filed: return nil
            }
        }
    }

    /// Whether the map is currently in the state this chip describes.
    func isActive(_ quick: QuickFilter) -> Bool {
        switch quick {
        case .all:
            return !isFiltering

        case .airborne:
            return !phases.contains(.ground)

        case .filed:
            return filedRouteOnly

        default:
            guard let category = quick.category else { return false }
            // Lit only when it is the *only* kind being drawn. A chip that lit
            // whenever its group happened to be included would be lit on a map
            // showing everything, which says nothing.
            return categories == [category]
        }
    }

    /// One tap on a chip. Every one of these is its own opposite, so tapping a
    /// lit chip puts back what it took away rather than being a dead end.
    func toggle(_ quick: QuickFilter) {
        switch quick {
        case .all:
            reset()

        case .airborne:
            // Through the phase toggle rather than straight at the set, so the
            // rule that the last phase cannot be turned off holds here too —
            // a map filtered down to the ground only must not be emptied by a
            // chip.
            toggle(FlightPhase.ground)

        case .filed:
            filedRouteOnly.toggle()

        default:
            guard let category = quick.category else { return }
            categories = isActive(quick) ? Set(AircraftCategory.allCases) : [category]
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
