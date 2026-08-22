import CoreLocation
import Foundation

/// What the server is doing, right now, in numbers.
///
/// Every figure here comes out of the packet the map is already drawn from —
/// there is nothing to fetch and nothing that can disagree with what is on
/// screen. That is the whole design: a statistics screen that made its own
/// requests could tell you the server has 1,412 aircraft while the map in front
/// of you is drawing 1,380, and then neither number is worth reading.
///
/// Built in one pass, because on a busy evening it is walking a couple of
/// thousand aircraft and the alternative is walking them once per figure.
struct ServerPulse: Equatable {

    /// One counted thing, with its share of the whole — a field, a route, a
    /// type of aeroplane.
    struct Tally: Identifiable, Equatable {
        let name: String

        /// A second line where the name alone is not enough: an airport's own
        /// name under its code, a route's two ends written out.
        let detail: String?

        let count: Int

        var id: String { name }
    }

    let total: Int
    let airborne: Int
    let onGround: Int

    /// How many are flying somewhere they have actually filed for.
    let filed: Int

    let byPhase: [FlightPhase: Int]
    let byCategory: [AircraftCategory: Int]

    /// Counts per `AltitudeBand` index, for the band the aircraft is in.
    /// Airborne only — a few hundred aeroplanes parked at zero feet would
    /// otherwise be the tallest bar on the chart and mean nothing.
    let byBand: [Int: Int]

    let busiestDepartures: [Tally]
    let busiestArrivals: [Tally]
    let busiestRoutes: [Tally]
    let commonestTypes: [Tally]

    /// Positions open, and how many fields they are spread across.
    let controllers: Int
    let staffedFields: Int

    /// Of the traffic in the air. The median rather than the mean, because one
    /// aircraft at 51,000 ft drags a mean and says nothing about where the
    /// server actually is.
    let medianAltitudeFeet: Double
    let averageGroundSpeedKnots: Double

    /// The longest route being flown right now, by great-circle distance
    /// between the two filed ends.
    let longestRoute: Tally?

    static let empty = ServerPulse(
        total: 0, airborne: 0, onGround: 0, filed: 0,
        byPhase: [:], byCategory: [:], byBand: [:],
        busiestDepartures: [], busiestArrivals: [], busiestRoutes: [],
        commonestTypes: [], controllers: 0, staffedFields: 0,
        medianAltitudeFeet: 0, averageGroundSpeedKnots: 0, longestRoute: nil
    )

    /// How many of each list is kept. Enough to see the shape of the evening,
    /// short enough to read without scrolling past it.
    private static let listLength = 6
}

extension ServerPulse {

    /// One pass over everything the feed has.
    static func from(flights: [Flight], stations: [AtcStation]) -> ServerPulse {
        guard !flights.isEmpty else {
            return ServerPulse(
                total: 0, airborne: 0, onGround: 0, filed: 0,
                byPhase: [:], byCategory: [:], byBand: [:],
                busiestDepartures: [], busiestArrivals: [], busiestRoutes: [],
                commonestTypes: [], controllers: stations.reduce(0) { $0 + $1.facilities.count },
                staffedFields: stations.filter { !$0.isCenter }.count,
                medianAltitudeFeet: 0, averageGroundSpeedKnots: 0, longestRoute: nil
            )
        }

        var airborne = 0
        var onGround = 0
        var filed = 0

        var byPhase: [FlightPhase: Int] = [:]
        var byCategory: [AircraftCategory: Int] = [:]
        var byBand: [Int: Int] = [:]

        var departures: [String: Int] = [:]
        var arrivals: [String: Int] = [:]
        var routes: [String: Int] = [:]
        var types: [String: Int] = [:]

        var altitudes: [Double] = []
        var speedTotal: Double = 0

        var longestName: String?
        var longestDetail: String?
        var longestNM: Double = 0

        for flight in flights {
            let phase = FlightPhase.from(flight)
            byPhase[phase, default: 0] += 1
            byCategory[AircraftCategory.from(spriteKey: flight.spriteKey), default: 0] += 1

            if phase == .ground {
                onGround += 1
            } else {
                airborne += 1
                byBand[AltitudeBand.band(forFeet: flight.altitudeFeet), default: 0] += 1
                if flight.altitudeFeet.isFinite { altitudes.append(flight.altitudeFeet) }
                if flight.groundSpeedKnots.isFinite { speedTotal += flight.groundSpeedKnots }
            }

            if !flight.aircraftName.isEmpty {
                types[flight.aircraftName, default: 0] += 1
            }

            let from = flight.departureIcao?.uppercased()
            let to = flight.arrivalIcao?.uppercased()

            if let from = from, !from.isEmpty { departures[from, default: 0] += 1 }
            if let to = to, !to.isEmpty { arrivals[to, default: 0] += 1 }

            guard let from = from, let to = to, !from.isEmpty, !to.isEmpty else { continue }
            filed += 1
            routes["\(from) → \(to)", default: 0] += 1

            // The longest leg on the server. Both ends have to be in the
            // dataset — a route to a field this app has never heard of has no
            // length to compare.
            guard let start = AirportStore.shared.airport(from),
                  let end = AirportStore.shared.airport(to) else { continue }
            let distance = FlightProgress.distanceNM(from: start.coordinate, to: end.coordinate)
            if distance > longestNM {
                longestNM = distance
                longestName = "\(from) → \(to)"
                longestDetail = "\(Format.number(distance)) NM · \(start.name)"
            }
        }

        altitudes.sort()

        return ServerPulse(
            total: flights.count,
            airborne: airborne,
            onGround: onGround,
            filed: filed,
            byPhase: byPhase,
            byCategory: byCategory,
            byBand: byBand,
            busiestDepartures: rank(departures, describe: airportName),
            busiestArrivals: rank(arrivals, describe: airportName),
            busiestRoutes: rank(routes, describe: { _ in nil }),
            commonestTypes: rank(types, describe: { _ in nil }),
            controllers: stations.reduce(0) { $0 + $1.facilities.count },
            staffedFields: stations.filter { !$0.isCenter }.count,
            medianAltitudeFeet: median(altitudes),
            averageGroundSpeedKnots: airborne > 0 ? speedTotal / Double(airborne) : 0,
            longestRoute: longestName.map {
                Tally(name: $0, detail: longestDetail, count: Int(longestNM.rounded()))
            }
        )
    }

    /// The top few, biggest first, with ties broken by name so the order does
    /// not shuffle between packets when two fields are level.
    private static func rank(
        _ counts: [String: Int],
        describe: (String) -> String?
    ) -> [Tally] {
        counts
            .sorted {
                // Biggest first, and ties broken by name — otherwise two
                // fields on the same count swap places between packets, and a
                // list that reshuffles while you read it is unreadable.
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(listLength)
            .map { Tally(name: $0.key, detail: describe($0.key), count: $0.value) }
    }

    private static func airportName(_ icao: String) -> String? {
        AirportStore.shared.airport(icao)?.name
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
