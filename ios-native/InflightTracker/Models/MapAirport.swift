import Foundation

/// A field worth drawing on the map.
///
/// "Active" is two different things, and both belong: a field somebody is
/// *controlling*, and a field the traffic is *going to*. They rank differently
/// and they are drawn differently — a staffed tower is the more interesting of
/// the two even when it is quiet, because it is the one you might divert to or
/// call — so the map keeps them distinguishable rather than merging them into
/// one "busy" score.
///
/// Bounded on purpose. The offline dataset has seventeen thousand fields in it
/// and the overwhelming majority have nothing happening; drawing them all would
/// bury the traffic the map is actually for.
struct MapAirport: Identifiable, Equatable {

    let airport: Airport

    /// Aircraft with this field filed as their destination.
    let inbound: Int

    /// Aircraft that filed out of it.
    let outbound: Int

    /// Positions being worked — "TWR", "GND". Empty at an uncontrolled field.
    let atcPositions: [String]

    var id: String { airport.icao }

    var isControlled: Bool { !atcPositions.isEmpty }

    var movements: Int { inbound + outbound }

    /// Compared by what is drawn rather than by the whole airport record, so a
    /// redraw only happens when something on screen would actually differ.
    static func == (lhs: MapAirport, rhs: MapAirport) -> Bool {
        lhs.airport.icao == rhs.airport.icao
            && lhs.inbound == rhs.inbound
            && lhs.outbound == rhs.outbound
            && lhs.atcPositions == rhs.atcPositions
    }

    /// Every controlled field, plus the busiest handful that nobody is working.
    ///
    /// Controlled fields are never dropped for being quiet — that is the whole
    /// point of marking them — so the limit applies only to the traffic-ranked
    /// tail. An ICAO the dataset has never heard of is skipped rather than
    /// drawn at a guessed position.
    static func active(
        in flights: [Flight],
        stations: [AtcStation],
        busiestLimit: Int
    ) -> [MapAirport] {
        var inbound: [String: Int] = [:]
        var outbound: [String: Int] = [:]

        for flight in flights {
            if let arrival = flight.arrivalIcao?.uppercased(), !arrival.isEmpty {
                inbound[arrival, default: 0] += 1
            }
            if let departure = flight.departureIcao?.uppercased(), !departure.isEmpty {
                outbound[departure, default: 0] += 1
            }
        }

        // Centres are excluded: their identifier is an FIR rather than an
        // ICAO, so there is no field to put a marker on.
        var positions: [String: [String]] = [:]
        for station in stations where !station.isCenter {
            let icao = station.identifier.uppercased()
            guard !icao.isEmpty else { continue }
            positions[icao, default: []].append(contentsOf: station.facilities.map { $0.kind.code })
        }

        var wanted = Set(positions.keys)

        // The traffic-ranked tail, taken from fields nobody is working — a
        // controlled field is already in, and would otherwise use up a slot.
        var ranked: [(icao: String, total: Int)] = []
        var totals: [String: Int] = [:]
        for (icao, count) in inbound where positions[icao] == nil {
            totals[icao, default: 0] += count
        }
        for (icao, count) in outbound where positions[icao] == nil {
            totals[icao, default: 0] += count
        }
        for (icao, total) in totals {
            ranked.append((icao: icao, total: total))
        }
        ranked.sort { lhs, rhs in
            lhs.total == rhs.total ? lhs.icao < rhs.icao : lhs.total > rhs.total
        }

        for entry in ranked.prefix(max(0, busiestLimit)) {
            wanted.insert(entry.icao)
        }

        var result: [MapAirport] = []
        result.reserveCapacity(wanted.count)

        for icao in wanted {
            guard let airport = AirportStore.shared.airport(icao) else { continue }
            result.append(
                MapAirport(
                    airport: airport,
                    inbound: inbound[icao] ?? 0,
                    outbound: outbound[icao] ?? 0,
                    atcPositions: positions[icao] ?? []
                )
            )
        }

        return result
    }
}
