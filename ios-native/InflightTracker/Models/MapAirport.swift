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

    /// Every field with traffic inbound, and every field with somebody on
    /// frequency — the white pins and the green ones.
    ///
    /// No cap: a field somebody is flying to is a field worth finding, and the
    /// map only draws them once it is close enough in for a few dozen to be on
    /// screen at once (`MapLayerStyle.fieldMinZoom`). Fields with traffic only
    /// departing are left off; the map is about where the aeroplanes are going.
    /// An ICAO the dataset has never heard of is skipped rather than drawn at
    /// a guessed position.
    static func active(
        in flights: [Flight],
        stations: [AtcStation]
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

        let wanted = Set(positions.keys).union(inbound.keys)

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

        // Sorted so the same set of fields is the same list every time. It is
        // built by walking a `Set`, whose order is not stable between runs or
        // even between two calls, and the map compares one ranking against the
        // last to decide whether its markers need re-diffing at all.
        return result.sorted { $0.airport.icao < $1.airport.icao }
    }
}
