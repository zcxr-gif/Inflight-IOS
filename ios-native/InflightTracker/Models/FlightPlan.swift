import CoreLocation
import Foundation

/// The route an aircraft actually filed, rather than the straight line between
/// its two ICAO codes.
///
/// The map has been drawing a great circle from the aircraft to its
/// destination, which is an assumption — the real thing goes out on a departure
/// procedure, down a chain of fixes, and in on an arrival. The web build read
/// this (`old/www/flight.js`, `/flights/{session}/{flight}/plan`) and the
/// native rebuild never had it.
struct FlightPlan: Equatable {

    let waypoints: [FlightPlanWaypoint]

    /// How far the whole filed route runs, end to end.
    var totalDistanceNM: Double {
        guard waypoints.count >= 2 else { return 0 }
        var total: Double = 0
        for index in 1..<waypoints.count {
            total += FlightProgress.distanceNM(
                from: waypoints[index - 1].coordinate,
                to: waypoints[index].coordinate
            )
        }
        return total
    }

    /// Which fix the aircraft is working towards.
    ///
    /// Nearest is not enough on its own: a route that doubles back passes close
    /// to fixes it left behind an hour ago. So a fix only counts as a candidate
    /// if it is roughly ahead — within a hundred degrees of the current track —
    /// or close enough that where it lies no longer matters. That is the rule
    /// the web build settled on, and it is the one that stops the active fix
    /// jumping backwards down an airway.
    func activeIndex(for flight: Flight) -> Int? {
        guard !waypoints.isEmpty else { return nil }

        var best: Int?
        var bestDistance = Double.infinity

        for (index, waypoint) in waypoints.enumerated() {
            let distance = FlightProgress.distanceNM(from: flight.coordinate, to: waypoint.coordinate)

            if distance >= 5 {
                let bearing = FlightProgress.bearing(from: flight.coordinate, to: waypoint.coordinate)
                var difference = abs(bearing - flight.heading).truncatingRemainder(dividingBy: 360)
                if difference > 180 { difference = 360 - difference }
                guard difference < 100 else { continue }
            }

            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }

        return best
    }

    /// The part of the route still to fly, starting from the aircraft itself so
    /// the drawn line joins the aeroplane rather than starting at a fix it is
    /// halfway between.
    func remaining(for flight: Flight) -> [CLLocationCoordinate2D] {
        guard let active = activeIndex(for: flight) else { return [] }
        return [flight.coordinate] + waypoints[active...].map(\.coordinate)
    }

    /// Reads the backend's answer, which nests departure and arrival procedures
    /// one level down.
    ///
    /// A procedure arrives as an item with `children` and, usually, no position
    /// of its own — it is a folder, not a fix. Its children are the fixes, and
    /// they are pulled up into one flat list here so everything downstream
    /// deals in points on a map rather than in a tree.
    static func from(items: [FlightPlanService.Item]) -> FlightPlan? {
        var waypoints: [FlightPlanWaypoint] = []

        for (index, item) in items.enumerated() {
            guard let children = item.children, !children.isEmpty else {
                if let waypoint = FlightPlanWaypoint(item: item, group: .enroute) {
                    waypoints.append(waypoint)
                }
                continue
            }

            let identifier = item.label

            // Which procedure this is, by where it sits in the plan and what it
            // is called. The backend does not label them, so this is the web
            // build's reading of the same shape: the first item or two are the
            // departure, a name that looks like a runway is the approach, and
            // anything else with children on the way in is the arrival.
            let group: FlightPlanWaypoint.Group
            if index <= 1 {
                group = .departure(identifier)
            } else if isRunwayLike(identifier) {
                group = .approach(identifier)
            } else {
                group = .arrival(identifier)
            }

            for child in children {
                if let waypoint = FlightPlanWaypoint(item: child, group: group) {
                    waypoints.append(waypoint)
                }
            }
        }

        // One point is a departure field and nothing else — not a route, and
        // nothing the map could draw.
        guard waypoints.count >= 2 else { return nil }
        return FlightPlan(waypoints: waypoints)
    }

    /// `27L`, `04`, `I16C` — an approach named for the runway it ends on,
    /// with or without the single letter the approach type puts in front of it
    /// (`I` for ILS, `R` for RNAV).
    private static func isRunwayLike(_ identifier: String) -> Bool {
        var characters = Array(identifier.uppercased())
        guard !characters.isEmpty else { return false }

        // A leading letter is the approach type, not part of the runway.
        if characters[0].isLetter { characters.removeFirst() }

        guard characters.count >= 2,
              characters[0].isNumber, characters[1].isNumber,
              let number = Int(String(characters[0...1])),
              (1...36).contains(number) else { return false }

        let suffix = String(characters.dropFirst(2))
        return suffix.isEmpty || ["L", "R", "C"].contains(suffix)
    }
}

/// One point on a filed route.
struct FlightPlanWaypoint: Identifiable, Equatable {

    /// What it is called: an ICAO for an airfield, a five-letter name for a
    /// fix, a VOR's three letters.
    let identifier: String

    let coordinate: CLLocationCoordinate2D

    /// The height filed for it, where one was. Most enroute fixes carry none.
    let altitudeFeet: Double?

    let group: Group

    /// Which part of the route a fix belongs to. The name is the procedure's,
    /// so a card can head a run of fixes with the SID or STAR they came from
    /// instead of listing twenty names with nothing tying them together.
    enum Group: Equatable {
        case departure(String)
        case enroute
        case arrival(String)
        case approach(String)

        var label: String? {
            switch self {
            case .departure(let name): return "SID \(name)"
            case .enroute: return nil
            case .arrival(let name): return "STAR \(name)"
            case .approach(let name): return "APPROACH \(name)"
            }
        }
    }

    /// Unique down the list even when a route passes the same fix twice, which
    /// a hold or a procedure turn does.
    let id = UUID()

    init?(item: FlightPlanService.Item, group: Group) {
        guard let location = item.location,
              let latitude = location.latitude,
              let longitude = location.longitude,
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }

        let label = item.label
        guard !label.isEmpty else { return nil }

        self.identifier = label
        self.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self.group = group

        // Zero is the API's "unspecified" rather than sea level — an enroute
        // fix at zero feet would be a fix in the water.
        let filed = location.altitude ?? item.altitude
        self.altitudeFeet = (filed?.isFinite == true && (filed ?? 0) > 1) ? filed : nil
    }

    static func == (lhs: FlightPlanWaypoint, rhs: FlightPlanWaypoint) -> Bool {
        lhs.id == rhs.id
    }

    var altitudeLabel: String? {
        guard let altitudeFeet = altitudeFeet else { return nil }
        return "\(Format.number(altitudeFeet)) ft"
    }
}
