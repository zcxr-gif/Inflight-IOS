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
/// One batch per sweep, a hundred callsigns at a time, and one batch in flight
/// at a time: a light aircraft with no schedule behind it must not be asked
/// about every fifteen seconds for as long as it is on screen. An answer of
/// "no route" is therefore cached too — for ten minutes rather than the two
/// hours a route is kept, because a miss is a verdict about where the aircraft
/// is at the moment and a hit is a fact about the flight number.
///
/// ## And the one aeroplane somebody is looking at
///
/// That queue is worked in whatever order the network listed the sweep in,
/// which is fine for the four hundred aircraft drawn behind the window and no
/// good at all for the one inside it. So the window asks about its own
/// aeroplane out of turn — see `resolveNow`, which is what stops a tapped
/// contact from showing a dash where its route goes for minutes on end.
final class RealWorldRoutes: ObservableObject {

    static let shared = RealWorldRoutes()

    /// What the last lookup did, in the one sentence Settings reads.
    ///
    /// Published because a route that never appears is otherwise a silent
    /// failure: the window draws a dash, and a dash is also what an aeroplane
    /// with no schedule looks like. The two are not the same problem and this
    /// is the only place that can tell them apart.
    enum Outcome: Equatable {

        case idle
        case asking

        /// The network answered and could be read. `matched` is how many of the
        /// callsigns asked about came back with a route worth drawing.
        case answered(matched: Int, asked: Int)

        /// The network answered with something this app could not read at all,
        /// which is the shape of the response having changed.
        case unreadable

        case failed(String)

        var label: String {
            switch self {
            case .idle:      return "Not asked yet"
            case .asking:    return "Looking…"
            case .answered(let matched, let asked):
                guard asked > 0 else { return "Nothing to look up" }
                return "\(matched) of \(asked) callsigns matched a route"
            case .unreadable: return "The route service answered with something unreadable"
            case .failed(let reason): return reason
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle

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

        /// Whether this is still worth believing.
        ///
        /// Which depends on what it says, and that is the whole point of the
        /// method: a hit is a settled fact and a miss is not. See
        /// `hitLifetime` and `missLifetime`. The miss side is passed in rather
        /// than read here because the aeroplane with a window open on it holds
        /// one for a shorter time than the sweep's queue does — see
        /// `resolveNow`.
        func isFresh(at now: Date, missLifetime: TimeInterval) -> Bool {
            let lifetime = route == nil ? missLifetime : RealWorldRoutes.hitLifetime
            return now.timeIntervalSince(at) < lifetime
        }
    }

    /// How long an answer that found a route is held.
    ///
    /// Long, because the answer is a property of the flight number rather than
    /// of the aeroplane: it does not change while the aircraft is in the air,
    /// and the whole point of the cache is that a window left open on one
    /// contact costs one lookup rather than one every sweep.
    private static let hitLifetime: TimeInterval = 2 * 60 * 60

    /// How long an answer that found *nothing* is held, which is very much
    /// shorter — and has to be.
    ///
    /// A miss is not the settled fact a hit is. A route is only handed over
    /// when the aircraft is also where that route would put it, so an
    /// aeroplane still on the stand, one that has just pushed back, or one
    /// holding off its track answers with nothing now and answers properly
    /// later; adsb.lol hold their own implausible verdicts for sixty seconds
    /// for exactly that reason, and re-check them afterwards. Held beside the
    /// hits for two hours, the first miss of a session was the last word on
    /// that aeroplane for the rest of it, and a window opened on one drew a
    /// dash for ever with nothing to say why.
    ///
    /// Still long enough to be a cache, which is what it is for: the sweep
    /// clock is fifteen seconds, so this is one lookup per aeroplane per forty
    /// sweeps rather than one per sweep.
    private static let missLifetime: TimeInterval = 10 * 60

    /// And how long a miss is held for the one aeroplane a window is open on.
    ///
    /// Shorter again, because that is the aircraft somebody is *looking at* —
    /// the dash they are reading is the one dash worth spending a request on —
    /// and because there is only ever one of it. See `resolveNow`.
    private static let focusMissLifetime: TimeInterval = 90

    /// The most callsigns one request carries.
    ///
    /// A hundred is the endpoint's own ceiling — it answers 400 to anything
    /// larger — and it is what this asks for. Sixty was the earlier figure and
    /// it was too polite to work: a sweep over a busy continent comes back with
    /// several hundred aircraft, the queue is worked in whatever order the
    /// network listed them, and at sixty a callsign near the back of a thousand
    /// waits four minutes for its turn.
    ///
    /// The aeroplane somebody has just tapped does not wait in this queue at
    /// all any more — see `resolveNow` — but everything drawn behind it still
    /// resolves out of it, so the queue moving twice as fast is worth having.
    private static let batchLimit = 100

    private var cache: [String: Entry] = [:]

    /// One at a time. A second request while the first is in the air would be
    /// asking about the same callsigns, since nothing has been written yet.
    private var isAsking = false

    /// The callsign of the one aeroplane being asked about out of turn, while
    /// that request is in the air. Nil the rest of the time.
    ///
    /// Its own flag rather than `isAsking`, because the two are asking
    /// different questions and neither should wait on the other: the batch is
    /// a hundred aircraft nobody has looked at, and this is the one somebody
    /// is reading. What it does stop is the window asking twice about the same
    /// aeroplane — it calls on every sweep, and a request in flight is the
    /// answer already arriving. See `resolveNow`.
    private var focusKey: String?

    /// Nothing is asked before this, after a request that did not work.
    ///
    /// The sweep clock is fifteen seconds and a service that is refusing or
    /// unreachable will still be refusing fifteen seconds later, so without
    /// this a bad afternoon is four requests a minute for as long as the layer
    /// is on.
    private var retryAfter: Date?

    private static let retryDelay: TimeInterval = 60

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
        if let retryAfter = retryAfter, now < retryAfter { return }
        var wanted: [(key: String, flight: Flight)] = []
        var asked: Set<String> = []

        for flight in flights where flight.origin == .realWorld {
            guard let key = Self.key(for: flight), !asked.contains(key) else { continue }
            if let entry = cache[key],
               entry.isFresh(at: now, missLifetime: Self.missLifetime) { continue }

            asked.insert(key)
            wanted.append((key, flight))
            if wanted.count >= Self.batchLimit { break }
        }

        guard !wanted.isEmpty,
              let url = AppConfig.realWorldRoutesURL,
              let body = Self.body(for: wanted)
        else { return }

        isAsking = true
        outcome = .asking

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.publicAPIUserAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Parsed off the main thread, and nil means the body could not be
            // read as an answer at all.
            let found = (200..<300).contains(code) ? Self.parse(data) : nil

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAsking = false

                // A request that did not work writes NOTHING.
                //
                // This is the whole reason the distinction exists. Caching a
                // failure as "this callsign has no route" for two hours poisons
                // every callsign it asked about, and since each sweep asks
                // about the ones it has no answer for, a single bad response
                // works its way through the whole sky in a couple of minutes
                // and the layer never shows a route again. A miss is only a
                // miss when the service actually answered.
                guard let found = found else {
                    self.retryAfter = Date().addingTimeInterval(Self.retryDelay)
                    self.outcome = Self.trouble(code: code, error: error)
                    return
                }

                self.retryAfter = nil

                let at = Date()
                // Now every callsign asked about is written, including the ones
                // the answer said nothing about — a miss that is not remembered
                // is a request made again on every sweep for as long as the
                // aeroplane is in range.
                var matched = 0
                for (key, _) in wanted {
                    let route = found[key] ?? nil
                    if route != nil { matched += 1 }
                    self.cache[key] = Entry(route: route, at: at)
                }

                self.outcome = .answered(matched: matched, asked: wanted.count)
                completion(matched > 0)
            }
        }.resume()
    }

    /// Look one aeroplane up now, ahead of the sweep's queue.
    ///
    /// The flight window is why this exists, and the report it comes from was
    /// simply that a real aeroplane's window has no departure and no
    /// destination in it. The routes were being fetched; they were being
    /// fetched for the wrong aircraft first. The batch above works through a
    /// sweep in whatever order the network listed it, and a sweep over a busy
    /// part of the world is several hundred contacts — so the one aeroplane
    /// somebody has just tapped sits behind a queue of aircraft nobody has
    /// looked at, for minutes, drawing a dash where its route goes. Long
    /// enough that the window simply looked like it did not have the feature.
    ///
    /// So the window asks about its own aeroplane directly: one callsign, its
    /// own request, alongside the batch rather than behind it. There is only
    /// ever one window open, the answer is written into the same cache the
    /// batch reads, and a hit here means the batch never asks about that
    /// callsign at all.
    ///
    /// Free to call on every sweep, which is how the window calls it. An
    /// aeroplane whose route is already known, whose lookup is already in the
    /// air, or that has no callsign to look up costs nothing.
    func resolveNow(_ flight: Flight, completion: @escaping (Bool) -> Void) {
        guard flight.origin == .realWorld, focusKey == nil else { return }

        let now = Date()
        if let retryAfter = retryAfter, now < retryAfter { return }

        guard let key = Self.key(for: flight) else { return }

        // A hit is the end of it. A miss is not — it is held for ninety
        // seconds here rather than the ten minutes the queue holds one,
        // because this is the aeroplane being looked at and the service
        // re-checks its own implausible verdicts on a shorter clock than that.
        if let entry = cache[key],
           entry.isFresh(at: now, missLifetime: Self.focusMissLifetime) { return }

        guard let url = AppConfig.realWorldRoutesURL,
              let body = Self.body(for: [(key: key, flight: flight)])
        else { return }

        focusKey = key
        if outcome == .idle { outcome = .asking }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.publicAPIUserAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let found = (200..<300).contains(code) ? Self.parse(data) : nil

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.focusKey = nil

                // The same rule the batch keeps, and for the same reason: a
                // request that did not work writes nothing. Caching this one as
                // "no route" would put a dash on the aeroplane somebody is
                // actually reading and hold it there.
                guard let found = found else {
                    self.retryAfter = Date().addingTimeInterval(Self.retryDelay)
                    self.outcome = Self.trouble(code: code, error: error)
                    return
                }

                self.retryAfter = nil

                let route = found[key] ?? nil
                self.cache[key] = Entry(route: route, at: Date())

                // Reported only when there is nothing better there. "1 of 1
                // callsigns matched" is a true sentence about a request nobody
                // asked for, and a much less useful one than "78 of 100" — but
                // it is a great deal more useful than a settings line left
                // saying "Looking…" because the sweep's own batch has not
                // landed yet.
                if self.outcome == .idle || self.outcome == .asking {
                    self.outcome = .answered(matched: route == nil ? 0 : 1, asked: 1)
                }

                completion(route != nil)
            }
        }.resume()
    }

    /// Why a request did not produce an answer, in words rather than a number —
    /// the same shape `RealWorldTraffic.reason` uses for the sweep itself.
    private static func trouble(code: Int, error: Error?) -> Outcome {
        if code == 429 { return .failed("The route service is asking for fewer requests") }
        if code == 404 { return .failed("The route service has moved") }
        if code >= 500 { return .failed("The route service is having trouble") }
        if code >= 400 { return .failed("The route service refused the request") }
        if error != nil { return .failed("No connection to the route service") }
        return .unreadable
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

    /// Callsign to route, with an inner nil for "asked, and there is none worth
    /// having" — and an **outer** nil for "this was not an answer".
    ///
    /// The two are worth the extra optional. See the completion above: one is
    /// a fact about an aeroplane and the other is a fact about the network, and
    /// treating the second as the first is what makes a layer go quiet for
    /// hours over one bad response.
    private static func parse(_ data: Data?) -> [String: Route?]? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

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
            return nil
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

    /// One row, taken if it is readable and not explicitly implausible.
    private static func route(from row: [String: Any]) -> Route? {
        guard isPlausible(row["plausible"]) else { return nil }

        // "EGSS-LEBL", and "unknown" when their database has nothing. A few
        // carry more than two legs — "EGLL-OMDB-VABB" — and the useful pair is
        // the two ends of the journey rather than whichever leg is being flown,
        // which the row does not say.
        //
        // The ICAO pair is what is wanted, because that is what the airport
        // table can place and therefore what turns into a distance to run. The
        // IATA pair behind it is a fallback rather than an equal: "STN-BCN"
        // draws as a route and resolves to no airport, which is what every
        // other tracker shows anyway and is better than a dash. The third name
        // is there for the same reason `RealWorldTraffic.parse` reads both `ac`
        // and `aircraft` — which spelling arrives is the service's business.
        let codes = (row["airport_codes"] as? String)
            ?? (row["_airport_codes_iata"] as? String)
            ?? (row["airportCodes"] as? String)
        guard let codes = codes else { return nil }

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

    /// Whether this row is allowed to be drawn.
    ///
    /// The endpoint answers with 1 and 0, read here as a number, a bool or a
    /// string because which of the three it is is their business rather than
    /// ours.
    ///
    /// **Absent is not false.** A row that does not carry the field at all —
    /// a schema that moved, a shape this app has not seen — falls through to
    /// yes, and that is deliberate. Rejecting on a field that cannot be found
    /// turns one surprise into a layer that silently draws nothing and gives
    /// nobody a reason why, which is exactly the failure this whole file was
    /// just debugged out of. An explicit 0 or false is still a refusal, so
    /// nothing is lost while the shape is the one expected.
    private static func isPlausible(_ value: Any?) -> Bool {
        guard let value = value, !(value is NSNull) else { return true }

        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String {
            return !["0", "false", "no"].contains(text.lowercased())
        }
        return true
    }

    private func isEmpty(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
