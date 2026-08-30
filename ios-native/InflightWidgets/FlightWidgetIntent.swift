import AppIntents
import Foundation

/// What a flight tile is pointed at, chosen by long-pressing the widget and
/// tapping Edit.
///
/// ## Why this is not a flight
///
/// The obvious design is to let somebody pick an aeroplane, store its id, and
/// draw that. It works beautifully until the flight ends — and every flight
/// ends. A flight id belongs to one leg: the pilot lands, starts another, and
/// the id they chose refers to nothing for the rest of time. The widget would
/// have been correct once and blank for ever after, with no way for its owner
/// to tell that anything had happened.
///
/// What somebody means by "put this in my widget" is almost always a standing
/// rule rather than a fact: *whatever I am flying*, *whatever this pilot is
/// flying*, *whatever I pinned in the app*. All three survive a landing. So
/// that is what is stored, and the flight is looked up fresh every time the
/// tile is drawn.
struct FlightSubject: AppEntity, Identifiable, Hashable {

    /// One of `auto`, `pinned`, `mine`, or `pilot:<username>`.
    ///
    /// A string rather than an enum with associated values because this is what
    /// the system persists on the user's behalf, and it has to be readable back
    /// into a choice by a build that has never seen that pilot before — see
    /// `FlightSubjectQuery.entities(for:)`.
    var id: String

    var name: String
    var detail: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Flight")
    }

    var displayRepresentation: DisplayRepresentation {
        if let detail = detail {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = FlightSubjectQuery()

    // MARK: - The standing rules

    /// What the id means, once it is read back.
    enum Rule: Equatable {
        case automatic
        case pinned
        case mine
        case pilot(String)
    }

    var rule: Rule {
        if id == Self.automaticID { return .automatic }
        if id == Self.pinnedID { return .pinned }
        if id == Self.mineID { return .mine }
        guard id.hasPrefix(Self.pilotPrefix) else { return .automatic }
        return .pilot(String(id.dropFirst(Self.pilotPrefix.count)))
    }

    private static let automaticID = "auto"
    private static let pinnedID = "pinned"
    private static let mineID = "mine"
    private static let pilotPrefix = "pilot:"

    static let automatic = FlightSubject(
        id: automaticID,
        name: "Automatic",
        detail: "Whatever you pinned in the app, or the flight closest to landing"
    )

    static let pinnedInApp = FlightSubject(
        id: pinnedID,
        name: "Pinned in the app",
        detail: "The flight you pinned from its window"
    )

    static let myAircraft = FlightSubject(
        id: mineID,
        name: "My flight",
        detail: "Whatever you are flying right now"
    )

    static func pilot(_ username: String, flying route: String?) -> FlightSubject {
        FlightSubject(id: pilotPrefix + username, name: username, detail: route)
    }

    /// Everything worth offering, read out of the snapshot the app leaves in
    /// the shared container.
    ///
    /// The standing rules first, because they are the ones that keep working;
    /// then the pilots this device actually knows about. A pilot appears once
    /// however many of the lists they are in.
    static func offered() -> [FlightSubject] {
        let snapshot = SharedStore.loadSnapshot()

        var out: [FlightSubject] = [.automatic]
        if snapshot.pinned != nil { out.append(.pinnedInApp) }
        if !snapshot.myFlights.isEmpty { out.append(.myAircraft) }

        var seen = Set<String>()
        for flight in snapshot.friends + snapshot.myFlights {
            let username = flight.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, seen.insert(username.lowercased()).inserted else { continue }
            out.append(.pilot(username, flying: flight.routeLabel))
        }

        return out
    }
}

/// Answers the two questions the system asks: what may be chosen, and what a
/// choice made earlier meant.
struct FlightSubjectQuery: EntityQuery {

    func suggestedEntities() async throws -> [FlightSubject] {
        FlightSubject.offered()
    }

    func defaultResult() async -> FlightSubject? { .automatic }

    /// Resolving a choice the user already made — and the reason this cannot
    /// simply filter `offered()`.
    ///
    /// A pilot who is not flying at this moment is not in the snapshot, so a
    /// widget pointed at them would find nothing here and the system would
    /// quietly reset the configuration to the default. Somebody would come back
    /// to a tile they had set up and find it showing somebody else. So a
    /// `pilot:` id is rebuilt from the id itself: the name is in there, and the
    /// list is only ever a convenience for choosing.
    func entities(for identifiers: [String]) async throws -> [FlightSubject] {
        let offered = FlightSubject.offered()

        return identifiers.compactMap { id in
            if let known = offered.first(where: { $0.id == id }) { return known }

            switch FlightSubject(id: id, name: "", detail: nil).rule {
            case .pilot(let username) where !username.isEmpty:
                return .pilot(username, flying: nil)
            case .pinned:
                return .pinnedInApp
            case .mine:
                return .myAircraft
            case .automatic, .pilot:
                return .automatic
            }
        }
    }
}

/// The widget's own settings, as the system presents them under Edit Widget.
struct SelectFlightIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource = "Choose a flight"

    static var description: IntentDescription {
        IntentDescription("Which aircraft this widget follows.")
    }

    @Parameter(title: "Show")
    var subject: FlightSubject?

    init() {}

    init(subject: FlightSubject?) {
        self.subject = subject
    }
}

// MARK: - Resolving a rule to an aeroplane

extension WidgetSnapshot {

    /// The aircraft a standing rule points at right now, or nil when there is
    /// nothing for it to point at — the pilot has landed, nothing is pinned,
    /// the app has not run yet.
    ///
    /// Every lookup is against the snapshot as it stands at draw time, which is
    /// the whole point: the rule is stored, the aeroplane is found.
    func flight(for rule: FlightSubject.Rule) -> WidgetFlight? {
        switch rule {
        case .automatic:
            // The original behaviour, in the original order — a tile nobody has
            // configured behaves exactly as it did before this existed.
            return pinned
                ?? myFlights.first
                ?? friends.first { $0.isAirborne }
                ?? friends.first

        case .pinned:
            return pinned

        case .mine:
            return myFlights.first { $0.isAirborne } ?? myFlights.first

        case .pilot(let username):
            let wanted = username.lowercased()
            let matches = allFlights.filter { $0.username.lowercased() == wanted }
            // Somebody flying two aeroplanes gets the one that is airborne.
            return matches.first { $0.isAirborne } ?? matches.first
        }
    }
}
