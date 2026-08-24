import Foundation

/// Somewhere the map has already been: an aircraft whose window was opened, or
/// a field whose panel was read.
///
/// Stored as a snapshot rather than as a reference, because half of what it
/// points at stops existing. A flight is gone from the feed the moment its
/// pilot disconnects, and a recent that could only render by finding its
/// aircraft in the current packet would empty itself every time somebody
/// landed. The title and detail written here are what the row shows for good;
/// whether the tap can still go anywhere is decided when it is tapped.
struct MapRecent: Identifiable, Equatable, Codable {

    enum Kind: String, Codable {
        case flight
        case airport
    }

    let kind: Kind

    /// The flight's feed id, or the field's ICAO.
    let key: String

    /// What it was called when it was opened — a callsign, or a code.
    let title: String

    /// The line under it: the pilot and the aeroplane, or the field's name.
    let detail: String

    let seen: Date

    /// Prefixed by kind, for the same reason a search result's is: an aircraft
    /// id and an ICAO cannot collide, but they share one list.
    var id: String { "\(kind.rawValue)|\(key)" }

    var symbol: String {
        switch kind {
        case .flight: return "airplane"
        case .airport: return "mappin.and.ellipse"
        }
    }
}

/// The last few things opened from the map, kept across launches.
///
/// The list is the whole feature: a tracker is an app people come back to for
/// the same handful of fields and the same handful of pilots, and typing an
/// ICAO you looked at an hour ago is work the app already had the answer to.
///
/// Ten of them, newest first, de-duplicated by what they point at — opening
/// EGLL twice is one row that moved to the top, not two rows.
final class MapRecents: ObservableObject {

    static let shared = MapRecents()

    @Published private(set) var items: [MapRecent] = []

    private static let key = "map.recents.v1"

    /// Long enough to cover a session's worth of looking around, short enough
    /// that the sheet never becomes a history screen.
    private static let limit = 10

    private let defaults = UserDefaults.standard

    private init() {
        items = load()
    }

    func record(flight: Flight) {
        let pilot = flight.username ?? "Pilot"
        let aircraft = flight.aircraftName.isEmpty ? "Unknown aircraft" : flight.aircraftName

        record(
            MapRecent(
                kind: .flight,
                key: flight.id,
                title: flight.displayName,
                detail: "\(pilot) · \(aircraft)",
                seen: Date()
            )
        )
    }

    func record(airport: Airport) {
        record(
            MapRecent(
                kind: .airport,
                key: airport.icao,
                title: airport.icao,
                detail: airport.name,
                seen: Date()
            )
        )
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        defaults.removeObject(forKey: Self.key)
    }

    private func record(_ item: MapRecent) {
        // Nothing published when the same thing is opened twice in a row: the
        // list would be identical, and the sheet would rebuild for it.
        if items.first?.id == item.id { return }

        var next = items.filter { $0.id != item.id }
        next.insert(item, at: 0)
        if next.count > Self.limit { next.removeLast(next.count - Self.limit) }

        items = next
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// A list that fails to decode — a shape change between versions — comes
    /// back empty rather than taking the sheet down with it.
    private func load() -> [MapRecent] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([MapRecent].self, from: data) else { return [] }
        return stored
    }
}
