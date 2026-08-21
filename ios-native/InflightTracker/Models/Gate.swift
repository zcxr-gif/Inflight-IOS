import CoreLocation
import Foundation

/// One place an aircraft can be parked: a gate, a stand, a marked parking
/// position, or a named apron.
///
/// OpenStreetMap tags all four under `aeroway`, and which one a mapper reached
/// for says more about the mapper than about the field, so they are one type
/// here and the tag is kept only to break ties between two that share a name.
struct Gate: Identifiable, Equatable {

    /// How the field refers to it: `B24`, `501`, `Cargo 3`.
    let ref: String

    let coordinate: CLLocationCoordinate2D

    let kind: Kind

    var id: String { ref }

    enum Kind: String {
        case gate
        case stand
        case parkingPosition = "parking_position"
        case apron

        /// Lower sorts first where two elements share a `ref`. A gate node is
        /// the terminal's own name for the spot; an apron polygon is the area
        /// it sits in, and is the last thing worth pinning a name to.
        var precedence: Int {
            switch self {
            case .gate: return 0
            case .stand: return 1
            case .parkingPosition: return 2
            case .apron: return 3
            }
        }
    }

    static func == (lhs: Gate, rhs: Gate) -> Bool {
        lhs.ref == rhs.ref
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Which stands have something sitting on them.
///
/// Worked out by position, because that is the only way there is: the feed
/// carries no stand assignment, so an aircraft is at B24 when it is parked on
/// the spot somebody mapped as B24 and not otherwise.
struct GateOccupancy {

    struct Occupied: Identifiable {
        let gate: Gate
        let flight: Flight
        var id: String { gate.ref }
    }

    /// Stands with an aircraft on them, in the field's own order.
    let occupied: [Occupied]

    /// How many stands the field has mapped at all.
    let total: Int

    /// Parked aircraft that matched no stand — remote hardstands nobody has
    /// mapped, GA on the grass, or a field whose mapping stops at the terminal.
    /// Counted rather than listed: they are already in the ground list below.
    let unmatched: Int

    var isEmpty: Bool { occupied.isEmpty }

    /// How close an aircraft has to sit to a mapped spot to be counted as on
    /// it, in metres.
    ///
    /// A parking position marks where the nosewheel stops, and the feed reports
    /// an aircraft's own reference point, so even a correctly parked widebody
    /// is tens of metres off the node. Wide enough to cover that, tight enough
    /// that the neighbouring stand is not a candidate — they are rarely closer
    /// together than a wingspan.
    static let radiusMetres: Double = 80

    /// Matches parked aircraft to stands, nearest first, one aircraft per
    /// stand.
    ///
    /// Aircraft that are moving are left out entirely: something taxiing past
    /// the terminal is briefly nearer to a gate than the aircraft actually on
    /// it, and a stand that flickers occupied as traffic rolls by is worse than
    /// one that says nothing.
    static func match(gates: [Gate], onGround: [AirportActivity.Movement]) -> GateOccupancy {
        let parked = onGround.filter { !$0.isTaxiing }
        guard !gates.isEmpty, !parked.isEmpty else {
            return GateOccupancy(occupied: [], total: gates.count, unmatched: 0)
        }

        // Every aircraft's best stand, then hand each stand to whichever
        // aircraft is closest to it: two airframes cannot share a spot, and
        // the near one is the one actually on it.
        var claims: [String: (flight: Flight, gate: Gate, metres: Double)] = [:]
        var unmatched = 0

        for movement in parked {
            var best: (gate: Gate, metres: Double)?
            for gate in gates {
                let metres = distanceMetres(movement.flight.coordinate, gate.coordinate)
                guard metres <= radiusMetres else { continue }
                if best == nil || metres < best!.metres {
                    best = (gate, metres)
                }
            }

            guard let winner = best else {
                unmatched += 1
                continue
            }

            if let held = claims[winner.gate.ref] {
                // Whoever is further from the spot is the one not on it.
                guard winner.metres < held.metres else {
                    unmatched += 1
                    continue
                }
                unmatched += 1
            }
            claims[winner.gate.ref] = (movement.flight, winner.gate, winner.metres)
        }

        let occupied = claims.values
            .map { Occupied(gate: $0.gate, flight: $0.flight) }
            .sorted { naturalOrder($0.gate.ref, $1.gate.ref) }

        return GateOccupancy(occupied: occupied, total: gates.count, unmatched: unmatched)
    }

    /// `A2` before `A10`, which a plain string sort gets backwards. Stand names
    /// are a letter and a number far more often than they are anything else.
    static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    /// Equirectangular rather than haversine: at the scale of an apron the
    /// difference is under a centimetre, and this runs over every stand at the
    /// field for every parked aircraft on every packet.
    private static func distanceMetres(
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D
    ) -> Double {
        let metresPerDegree = 111_320.0
        let deltaLat = (to.latitude - from.latitude) * metresPerDegree
        let deltaLon = (to.longitude - from.longitude) * metresPerDegree
            * cos(from.latitude * .pi / 180)
        return (deltaLat * deltaLat + deltaLon * deltaLon).squareRoot()
    }
}
