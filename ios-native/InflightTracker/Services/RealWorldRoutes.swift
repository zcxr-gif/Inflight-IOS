import Foundation

/// Where a real aeroplane is going, which its own transmissions never say.
///
/// ## Why this has to exist at all
///
/// ADS-B carries an address, a callsign, a position, an altitude, a velocity
/// and a squawk. It carries no origin and no destination — there is no field
/// for either in the protocol, so no receiver anywhere heard one and no feed,
/// free or paid, can hand one over. Every tracker that shows a route is joining
/// the *callsign* to a separate database afterwards, and so is this.
///
/// adsb.lol publish that join as `routeset`: a batched POST that takes callsigns
/// with the position they were heard at and answers with an airport pair. It is
/// the same endpoint tar1090 fills its route column from, it takes no key, and
/// it is the same network the positions already come from — which matters, since
/// it means one attribution rather than two.
///
/// ## Why `plausible` is not optional
///
/// The underlying data is callsign-to-airport-pair with no date on it, and
/// flight numbers are reused: they churn seasonally, and regional operators
/// share them. Measured against filed flight plans it is right about four times
/// in five outside the United States and about one time in four inside it. So a
/// route is taken only when the answer also says it is `plausible` — adsb.lol's
/// own check that the aircraft is where that route would put it. It throws away
/// a good deal of what comes back, and what survives is worth drawing.
///
/// This is still an inference and the window says so. It is never presented as a
/// filed plan, because it is not one.
///
/// ## What it is careful about
///
/// One request in flight at a time, one batch per sweep, and an answer of "no
/// route" is cached exactly as firmly as an answer with one — a light aircraft
/// with no schedule behind it must not be asked about every fifteen seconds for
/// as long as it is on screen.
final class RealWorldRoutes {

    static let shared = RealWorldRoutes()

    /// Both ends, as ICAO codes the airport table can resolve.
    struct Route: Equatable {
        let departure: String
        let arrival: String
    }

    private struct Entry {
        /// Nil is an answer: this callsign has no route anybody knows, or the
        /// one on offer was not plausible where the aircraft actually is.
        let route: Route?
        let at: Date
    }

    /// How long an answer is held.
    ///
    /// Long, because the answer is a property of the flight number rather than
    /// of the aeroplane: it does not change while the aircraft is in the air,
    /// and the whole point of the cache is that a window left open on one
    /// contact costs one lookup rather than one every sweep.
    private static let lifetime: TimeInterval = 2 * 60 * 60

    /// The most callsigns one request carries.
    ///
    /// A sweep over a busy continent can come back with several hundred
    /// aircraft, and asking about all of them at once is a large body posted to
    /// a community service on a fifteen-second clock. The cap means a crowded
    /// map resolves over a few sweeps instead of in one — which nobody notices,
    /// because what is being looked at is the aircraft somebody tapped.
    private static let batchLimit = 60

    private var cache: [String: Entry] = [:]

    /// One at a time. A second request while the first is in the air would be
    /// asking about the same callsigns, since nothing has been written yet.
    private var isAsking = false

    private init() {}

    // MARK: - Reading

    /// Every route already known, written onto the aircraft that own it.
    ///
    /// Written onto `Flight` rather than kept beside it so that everything
    /// downstream simply works: the route card, the board, the widget peek's
    /// route line, and `FlightProgress`, which is what turns two airports into
    /// a distance to run and a time to get there. A store the views had to
    /// consult separately would mean teaching every one of them about a second
    /// kind of aircraft.
    ///
    /// Anything that already has a route keeps it. Nothing here overwrites what
    /// a feed actually reported.
    func attaching(to flights: [Flight]) -> [Flight] {
        guard !cache.isEmpty else { return flights }

        return flights.map { flight in
            guard flight.origin == .realWorld,
                  isEmpty(flight.departureIcao), isEmpty(flight.arrivalIcao),
                  let key = Self.key(for: flight),
                  // Two unwraps, not one: an entry exists for every callsign
                  // asked about, and its route is nil for the ones that came
                  // back with nothing worth drawing.
                  let entry = cache[key], let route = entry.route
            else { return flight }

            var resolved = flight
            resolved.departureIcao = route.departure
            resolved.arrivalIcao = route.arrival
            return resolved
        }
    }

    // MARK: - Asking

    /// Look up whatever on this sweep has not been answered for yet.
    ///
    /// `completion` runs on the main thread and reports whether anything new
    /// was learned, so the caller can redraw what is already on screen rather
    /// than leaving an open window waiting for the next sweep.
    func resolve(_ flights: [Flight], completion: @escaping (Bool) -> Void) {
        guard !isAsking else { return }

        let now = Date()
        var wanted: [(key: String, flight: Flight)] = []
        var asked: Set<String> = []

        for flight in flights where flight.origin == .realWorld {
            guard let key = Self.key(for: flight), !asked.contains(key) else { continue }
            if let entry = cache[key], now.timeIntervalSince(entry.at) < Self.lifetime { continue }

            asked.insert(key)
            wanted.append((key, flight))
            if wanted.count >= Self.batchLimit { break }
        }

        guard !wanted.isEmpty,
              let url = AppConfig.realWorldRoutesURL,
              let body = Self.body(for: wanted)
        else { return }

        isAsking = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.publicAPIUserAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let found = Self.parse(data)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAsking = false

                let at = Date()
                // Every callsign asked about is written, including the ones the
                // answer said nothing about. A miss is an answer, and a miss
                // that is not remembered is a request made again on every
                // sweep for as long as the aeroplane is in range.
                for (key, _) in wanted {
                    self.cache[key] = Entry(route: found[key] ?? nil, at: at)
                }

                completion(found.values.contains { $0 != nil })
            }
        }.resume()
    }

    // MARK: - The request

    /// What the endpoint is keyed on: the callsign, as it was broadcast.
    ///
    /// Nil for anything without one, which is a great many light aircraft —
    /// they fly under a registration, there is no flight number behind it and
    /// no schedule to look up.
    private static func key(for flight: Flight) -> String? {
        let callsign = (flight.callsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // A registration is not a callsign for this purpose. `Flight.init(adsb:)`
        // falls back to the tail number so that every mark on the map has a
        // name, and asking a schedule database about N512QS can only ever miss.
        guard callsign.count >= 3, callsign.contains(where: \.isNumber) else { return nil }
        return callsign
    }

    private static func body(for wanted: [(key: String, flight: Flight)]) -> Data? {
        let planes: [[String: Any]] = wanted.map { entry in
            [
                "callsign": entry.key,
                // Where it was heard. This is what the plausibility check is
                // made against, so it is the position rather than a guess.
                "lat": entry.flight.latitude,
                "lng": entry.flight.longitude
            ]
        }

        return try? JSONSerialization.data(withJSONObject: ["planes": planes])
    }

    // MARK: - Reading the answer

    /// Callsign to route, with nil for "asked, and there is none worth having".
    private static func parse(_ data: Data?) -> [String: Route?] {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }

        // An array is what the endpoint answers with. The dictionary branch is
        // for the day it is wrapped in one, which costs two lines here and
        // saves the layer going silent if it ever is.
        let rows: [Any]
        if let array = root as? [Any] {
            rows = array
        } else if let object = root as? [String: Any],
                  let array = object.values.first(where: { $0 is [Any] }) as? [Any] {
            rows = array
        } else {
            return [:]
        }

        var out: [String: Route?] = [:]

        for case let row as [String: Any] in rows {
            guard let callsign = (row["callsign"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
                  !callsign.isEmpty
            else { continue }

            out[callsign] = route(from: row)
        }

        return out
    }

    /// One row, taken only if it is both readable and plausible.
    private static func route(from row: [String: Any]) -> Route? {
        guard isPlausible(row["plausible"]) else { return nil }

        // "EGSS-LEBL", and "unknown" when their database has nothing. A few
        // carry more than two legs — "EGLL-OMDB-VABB" — and the useful pair is
        // the two ends of the journey rather than whichever leg is being flown,
        // which the row does not say.
        guard let codes = row["airport_codes"] as? String else { return nil }

        let legs = codes
            .uppercased()
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Alphanumeric rather than letters only. ICAO codes are four letters
        // nearly always and not quite always, and a code the airport table
        // cannot place is harmless — the window draws the pair and simply has
        // no distance to run. A filter that threw away real routes to avoid
        // that would be the worse mistake.
        guard legs.count >= 2,
              let departure = legs.first, let arrival = legs.last,
              departure != arrival,
              legs.allSatisfy({ leg in
                  (3...4).contains(leg.count)
                      && leg.allSatisfy({ $0.isLetter || $0.isNumber })
              })
        else { return nil }

        return Route(departure: departure, arrival: arrival)
    }

    /// The endpoint answers with 1 and 0. Read as a number or a bool, because
    /// which of the two it is is their business rather than ours, and a route
    /// drawn on a misread flag is a route drawn on nothing.
    private static func isPlausible(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String { return text == "1" || text.lowercased() == "true" }
        return false
    }

    private func isEmpty(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
