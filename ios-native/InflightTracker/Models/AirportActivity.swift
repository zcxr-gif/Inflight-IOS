import CoreLocation
import Foundation

/// What is happening at one field right now, worked out from the packet the
/// feed last published.
///
/// Nothing here is fetched. The traffic is already in memory and the field's
/// position comes from the offline dataset, so a field can be opened and read
/// with no network beyond the feed itself — and with the feed down it keeps
/// showing whatever it last saw rather than emptying out.
struct AirportActivity {

    /// One aircraft the field has something to do with.
    ///
    /// The geometry is worked out once, here, rather than in the row that draws
    /// it: the panel is rebuilt on every packet, and a great-circle distance per
    /// aircraft is the only part of this that costs anything.
    struct Movement: Identifiable, Equatable {

        let flight: Flight

        /// Great-circle distance from the field.
        let distanceNM: Double

        /// Seconds to run at the current ground speed, for aircraft on their way
        /// here. Nil wherever the number would be a fiction — anything on the
        /// ground, anything on its way out, and anything too slow for the
        /// division to mean anything.
        let etaSeconds: TimeInterval?

        var id: String { flight.id }

        /// `14 min`, `2h 06m`. Floored at a minute rather than rounding to
        /// zero, because `0 min` reads as a broken readout rather than as short
        /// final.
        var etaLabel: String? {
            guard let seconds = etaSeconds, seconds.isFinite, seconds > 0 else { return nil }
            let minutes = max(1, Int((seconds / 60).rounded()))
            guard minutes >= 60 else { return "\(minutes) min" }
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }

        /// Moving under its own power on the ground, as against parked at a
        /// stand. Same threshold the info window uses to call an aircraft
        /// taxiing.
        var isTaxiing: Bool { flight.groundSpeedKnots >= 5 }
    }

    let airport: Airport

    /// Filed in here and not on the field yet, soonest to arrive first.
    ///
    /// Which includes traffic that has not actually left its gate: it filed
    /// this destination, so it is expected, and having no estimate to run on
    /// sorts it to the bottom of the list where the row says "Parked".
    let inbound: [Movement]

    /// Filed out of here and no longer on the field, closest first — so the
    /// aircraft that has just got airborne heads the list.
    let outbound: [Movement]

    /// Sitting on the field, whatever they filed — including the traffic that
    /// filed nothing at all, which is most of a busy apron.
    let onGround: [Movement]

    var movementCount: Int { inbound.count + outbound.count + onGround.count }

    var isEmpty: Bool { movementCount == 0 }

    /// How close an aircraft has to be to count as being *at* the field rather
    /// than merely near it. Generous enough to take in a large field's whole
    /// apron and both ends of its longest runway.
    static let groundRadiusNM: Double = 6

    /// Below this an aircraft is not flying.
    ///
    /// Ground speed decides this on its own, rather than the shared
    /// `FlightPhase`, which also tests altitude: the feed reports altitude above
    /// sea level, so at a field like Lhasa or Denver everything parked at a
    /// stand reads as airborne. Height above the ground is what that test wants
    /// and the dataset has no field elevations to work it out from.
    static let flyingSpeedKnots: Double = 40

    /// Splits a packet into the three lists the field's panel shows.
    static func at(_ airport: Airport, in flights: [Flight]) -> AirportActivity {
        let icao = airport.icao.uppercased()
        let field = airport.coordinate

        // Everything outside this box is further out than the ground radius, so
        // it can be dropped without a haversine. A busy server is a thousand
        // aircraft and this runs on every packet.
        let latitudeSpan = groundRadiusNM / 60.0
        let cosine = max(cos(field.latitude * .pi / 180), 0.01)
        let longitudeSpan = latitudeSpan / cosine

        var inbound: [Movement] = []
        var outbound: [Movement] = []
        var onGround: [Movement] = []

        for flight in flights {
            let arriving = flight.arrivalIcao?.uppercased() == icao
            let departing = flight.departureIcao?.uppercased() == icao

            let isNearby = abs(flight.latitude - field.latitude) <= latitudeSpan
                && abs(flight.longitude - field.longitude) <= longitudeSpan

            // Nothing filed here and nowhere near it: not this field's traffic.
            guard arriving || departing || isNearby else { continue }

            let distance = FlightProgress.distanceNM(from: flight.coordinate, to: field)

            if flight.groundSpeedKnots < flyingSpeedKnots, distance <= groundRadiusNM {
                onGround.append(Movement(flight: flight, distanceNM: distance, etaSeconds: nil))
                continue
            }

            if arriving {
                // A circuit files the same field at both ends. It is counted
                // once, as an arrival, because that is the list its ETA belongs
                // in.
                let speed = flight.groundSpeedKnots
                let eta: TimeInterval? = speed > flyingSpeedKnots
                    ? distance / speed * 3600
                    : nil
                inbound.append(Movement(flight: flight, distanceNM: distance, etaSeconds: eta))
            } else if departing {
                outbound.append(Movement(flight: flight, distanceNM: distance, etaSeconds: nil))
            }
            // Anything left is passing overhead with no business here, which is
            // not something the field's panel has anything to say about.
        }

        return AirportActivity(
            airport: airport,
            inbound: inbound.sorted(by: soonestFirst),
            outbound: outbound.sorted { $0.distanceNM < $1.distanceNM },
            onGround: onGround.sorted(by: movingFirst)
        )
    }

    /// Arrival order: by how long they have to run, then by how far out they
    /// are. An aircraft slow enough to have no estimate goes last rather than
    /// jumping the queue with a missing number.
    private static func soonestFirst(_ first: Movement, _ second: Movement) -> Bool {
        switch (first.etaSeconds, second.etaSeconds) {
        case let (lhs?, rhs?):
            return lhs == rhs ? first.distanceNM < second.distanceNM : lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return first.distanceNM < second.distanceNM
        }
    }

    /// Anything moving comes before anything parked — a taxiing aircraft is the
    /// part of the apron that is actually doing something — and within each,
    /// alphabetically, so the list doesn't reshuffle as the packet's own order
    /// changes underneath it.
    private static func movingFirst(_ first: Movement, _ second: Movement) -> Bool {
        if first.isTaxiing != second.isTaxiing { return first.isTaxiing }
        return first.flight.displayName < second.flight.displayName
    }
}

/// One field's share of what the server is flying, for ranking the whole board
/// rather than reading one airport.
///
/// Counted from what aircraft have *filed*, which is a dictionary of string
/// keys and nothing else. The obvious alternative — asking `AirportActivity`
/// about every airport — would be the airport dataset times the packet, and
/// working out what is physically parked at a field costs a nearest-airport
/// search per aircraft. That is affordable for the one field you have opened
/// and not for all of them at once, so the board ranks on flight plans and the
/// apron is counted when you go in.
struct AirportTraffic: Identifiable {

    let airport: Airport

    /// Aircraft with this field filed as their destination.
    let inbound: Int

    /// Aircraft that filed out of it.
    let outbound: Int

    var total: Int { inbound + outbound }

    var id: String { airport.icao }

    /// The busiest fields on the server, most traffic first.
    ///
    /// Codes the dataset has never heard of are dropped rather than listed: a
    /// row here exists to be opened, and there is nothing behind an ICAO that
    /// resolves to no airport. They are dropped while taking the top `limit`,
    /// so a few unknown codes cost a shorter list rather than a wrong ranking.
    static func busiest(in flights: [Flight], limit: Int) -> [AirportTraffic] {
        guard limit > 0 else { return [] }

        var arrivals: [String: Int] = [:]
        var departures: [String: Int] = [:]

        for flight in flights {
            if let arrival = flight.arrivalIcao?.uppercased(), !arrival.isEmpty {
                arrivals[arrival, default: 0] += 1
            }
            if let departure = flight.departureIcao?.uppercased(), !departure.isEmpty {
                departures[departure, default: 0] += 1
            }
        }

        // Spelled out rather than chained. `Set(...).union(...).map { (a, b) }
        // .sorted { ternary }` is four inference problems in one expression —
        // a generic set operation feeding an unlabelled tuple into a
        // comparator — and Swift's type checker gives up on it outright:
        // "unable to type-check this expression in reasonable time". Loops
        // carry an explicit type at every step and cost the compiler nothing.
        var totals: [String: Int] = [:]
        for (icao, count) in arrivals {
            totals[icao, default: 0] += count
        }
        for (icao, count) in departures {
            totals[icao, default: 0] += count
        }

        var ranked: [(icao: String, total: Int)] = []
        ranked.reserveCapacity(totals.count)
        for (icao, total) in totals {
            ranked.append((icao: icao, total: total))
        }

        // Busiest first, then alphabetically, so equally busy fields come out
        // in a stable order instead of the dictionary's.
        ranked.sort { first, second in
            if first.total != second.total { return first.total > second.total }
            return first.icao < second.icao
        }

        var board: [AirportTraffic] = []
        board.reserveCapacity(limit)

        for entry in ranked {
            guard board.count < limit else { break }
            guard let airport = AirportStore.shared.airport(entry.icao) else { continue }

            board.append(
                AirportTraffic(
                    airport: airport,
                    inbound: arrivals[entry.icao] ?? 0,
                    outbound: departures[entry.icao] ?? 0
                )
            )
        }

        return board
    }
}
