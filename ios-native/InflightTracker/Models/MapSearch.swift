import Foundation

/// One hit from the search field: an aircraft in the air right now, or a place
/// on the map to go and look at.
enum MapSearchResult: Identifiable {

    case flight(Flight)
    case airport(Airport)

    /// Prefixed by kind — an aircraft's id and an ICAO can't collide, but the
    /// list is one list and its ids have to be unique across both.
    var id: String {
        switch self {
        case .flight(let flight): return "flight|\(flight.id)"
        case .airport(let airport): return "airport|\(airport.icao)"
        }
    }
}

/// What the map's search field knows how to find.
///
/// Both halves are already on the device: the traffic is the packet the feed
/// last published, and the airports are the offline VAT-Spy dataset. So this is
/// a scan over memory rather than a query — no debounce, no spinner, and it
/// keeps working with the feed down.
enum MapSearch {

    /// Shortest query worth running. One character matches most of the sky.
    static let minimumLength = 2

    static func results(for query: String, in flights: [Flight], limit: Int = 8) -> [MapSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard needle.count >= minimumLength else { return [] }

        var scored: [(MapSearchResult, Int)] = []

        for flight in flights {
            guard let rank = rank(flight, for: needle) else { continue }
            scored.append((.flight(flight), rank))
        }

        // The airport list is ranked on the same scale, so a typed ICAO puts
        // the field above the traffic that merely happens to be routed through
        // it — one list, ordered by how well each row answers what was typed.
        for airport in AirportStore.shared.search(needle, limit: limit) {
            let rank: Int
            if airport.icao == needle {
                rank = 0
            } else if airport.icao.hasPrefix(needle) {
                rank = 1
            } else {
                rank = 2
            }
            scored.append((.airport(airport), rank))
        }

        return scored
            .sorted { first, second in
                first.1 == second.1 ? sortKey(first.0) < sortKey(second.0) : first.1 < second.1
            }
            .prefix(limit)
            .map { $0.0 }
    }

    /// How well one aircraft answers the query, or nil when it doesn't.
    ///
    /// Identity beats itinerary: someone typing `BAW` wants British Airways
    /// callsigns, and someone typing `EGLL` wants the airport — the flights
    /// routed through it come after both, which is what the last rank is for.
    private static func rank(_ flight: Flight, for needle: String) -> Int? {
        let callsign = flight.callsign?.uppercased() ?? ""
        if callsign == needle { return 0 }
        if callsign.hasPrefix(needle) { return 1 }

        let username = flight.username?.uppercased() ?? ""
        if username.hasPrefix(needle) { return 1 }

        let registration = flight.registration?.uppercased() ?? ""
        if registration.hasPrefix(needle) { return 1 }

        if callsign.contains(needle) || username.contains(needle) || registration.contains(needle) {
            return 2
        }

        // Only a whole code: `EG` shouldn't return every flight in the UK.
        if needle.count == 4,
           flight.departureIcao?.uppercased() == needle || flight.arrivalIcao?.uppercased() == needle {
            return 3
        }

        return nil
    }

    /// Tie-break within a rank, so equally good matches come out in a stable
    /// order instead of whatever order the feed's array happened to be in.
    private static func sortKey(_ result: MapSearchResult) -> String {
        switch result {
        case .flight(let flight): return flight.displayName
        case .airport(let airport): return airport.icao
        }
    }
}
