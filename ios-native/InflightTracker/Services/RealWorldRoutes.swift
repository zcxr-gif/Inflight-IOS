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
/// ## Two databases, asked in different shapes
///
/// **adsb.lol's `routeset`** is a batched POST: up to a hundred callsigns with
/// the positions they were heard at, and an airport pair back for each. It is
/// the same endpoint tar1090 fills its route column from, it takes no key, and
/// it is the same network the positions already come from. That shape is right
/// for the map, where several hundred aircraft need a route each and none of
/// them is being read closely.
///
/// **adsbdb's callsign endpoint** is a plain GET with the callsign in the path.
/// One aeroplane, one request, an airport pair in the body and a 404 when it
/// has never heard of the callsign. That shape is right for the flight window,
/// which is one aeroplane somebody is actually looking at — and it is a
/// different project with a different pipeline, so a callsign missing from one
/// is quite often in the other, and a day when one is down is no longer a day
/// with no routes at all.
///
/// The window asks adsbdb first and falls back to the batch endpoint for its
/// one callsign; the sweep asks the batch endpoint only. Both write the same
/// cache. See `resolveNow`.
///
/// ## What the answer is worth
///
/// The standing data behind both is callsign-to-airport-pair with no date on
/// it, and flight numbers are reused: they churn seasonally, and regional
/// operators share them. Measured against filed flight plans it is right about
/// four times in five outside the United States and about one time in four
/// inside it.
///
/// This is therefore an inference, and the window says so — it is never
/// presented as a filed plan, because it is not one. What it is *not* is
/// filtered by adsb.lol's `plausible` flag any more; see `route(from:)` for
/// why that flag does not mean what it reads as, and what rejecting on it cost.
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
        /// Nil is an answer: neither database has a route for this callsign.
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
    /// A miss is not the settled fact a hit is. Standing data is reloaded,
    /// caches upstream expire, and the two databases are asked in a different
    /// order depending on where the question came from — so a callsign that
    /// nobody could place a minute ago is quite often placed now. Held beside
    /// the hits for two hours, the first miss of a session was the last word
    /// on that aeroplane for the rest of it, and a window opened on one drew a
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

    /// Look one aeroplane up now, ahead of the sweep's queue — and from the
    /// other database first.
    ///
    /// The flight window is why this exists, and the report it comes from was
    /// simply that a real aeroplane's window has no departure and no
    /// destination in it. Two things were wrong and this is where both of them
    /// are answered.
    ///
    /// The first is order. The batch above works through a sweep in whatever
    /// order the network listed it, and a sweep over a busy part of the world
    /// is several hundred contacts — so the one aeroplane somebody has just
    /// tapped sits behind a queue of aircraft nobody has looked at, drawing a
    /// dash where its route goes. So the window asks about its own aeroplane
    /// directly, out of turn.
    ///
    /// The second is the source. Everything the app knew about routes came
    /// through one batched endpoint, which is the wrong shape for finding out
    /// why *one* aeroplane has none: a hundred answers arrive together and any
    /// of them may be a miss for its own reasons. So this asks adsbdb — a
    /// different project, a different pipeline, and a plain GET with the
    /// callsign in the path — and only falls back to the batch endpoint for
    /// that one callsign if adsbdb has nothing. Two databases with overlapping
    /// but different standing data, and two independent ways for the route to
    /// arrive.
    ///
    /// Whichever answers, the route is written into the one cache the batch
    /// also reads, so a hit here means the sweep never asks about that
    /// callsign again.
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
        // because this is the aeroplane being looked at.
        if let entry = cache[key],
           entry.isFresh(at: now, missLifetime: Self.focusMissLifetime) { return }

        focusKey = key
        if outcome == .idle { outcome = .asking }

        askAdsbdb(key) { [weak self] answer in
            guard let self = self else { return }

            switch answer {
            case .route(let route):
                self.focusKey = nil
                self.finishFocus(key: key, route: route, completion: completion)

            // Both of the others go on to the second source, and that is the
            // point of having one. A definite "never heard of it" is still
            // worth asking the other database about — the two are built on
            // different standing data and each holds callsigns the other does
            // not — and a request that did not work has said nothing at all.
            case .unknown, .noAnswer:
                self.askAdsbLol(key: key, flight: flight) { route in
                    self.focusKey = nil

                    guard let route = route else {
                        // Nothing from either. Whether that is worth writing
                        // down depends on what adsbdb said: "never heard of
                        // it" is a fact about the flight number and is cached,
                        // where a request that did not work is a fact about
                        // the network and is cached for nothing.
                        if case .unknown = answer {
                            self.cache[key] = Entry(route: nil, at: Date())
                        }
                        if self.outcome == .asking {
                            self.outcome = .answered(matched: 0, asked: 1)
                        }
                        completion(false)
                        return
                    }

                    self.finishFocus(key: key, route: route, completion: completion)
                }
            }
        }
    }

    /// One answer written, one line of diagnostics kept, one caller told.
    private func finishFocus(
        key: String,
        route: Route,
        completion: @escaping (Bool) -> Void
    ) {
        retryAfter = nil
        cache[key] = Entry(route: route, at: Date())

        // Reported only when there is nothing better there. "1 of 1 callsigns
        // matched" is a true sentence about a request nobody asked for, and a
        // much less useful one than "78 of 100" — but it is a great deal more
        // useful than a settings line left saying "Looking…" because the
        // sweep's own batch has not landed yet.
        if outcome == .idle || outcome == .asking {
            outcome = .answered(matched: 1, asked: 1)
        }

        completion(true)
    }

    /// What one callsign lookup came back with.
    private enum FocusAnswer {
        /// A route worth drawing.
        case route(Route)

        /// The service answered and has no route for this callsign. A fact
        /// about the flight number.
        ///
        /// Named `unknown` rather than `none` on purpose: a case called `none`
        /// is matched against `Optional.none` in half the places you write it,
        /// and the compiler is right to be unsure which you meant.
        case unknown

        /// The request did not work, or could not be read. A fact about the
        /// network, and never cached as if it were the one above.
        case noAnswer
    }

    /// The second database, asked about one callsign.
    ///
    /// A GET with the callsign in the path and an airport pair in the body,
    /// which is as simple as this gets — and simple is the point. See
    /// `AppConfig.realWorldRouteURL(callsign:)`.
    ///
    /// Answers on the main thread, like everything else that writes the cache.
    private func askAdsbdb(_ key: String, completion: @escaping (FocusAnswer) -> Void) {
        guard let url = AppConfig.realWorldRouteURL(callsign: key) else {
            return completion(.noAnswer)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.publicAPIUserAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            let answer: FocusAnswer = {
                // Their own way of saying they have never heard of it, and the
                // one status that is an answer rather than a failure.
                if code == 404 { return .unknown }
                guard (200..<300).contains(code) else { return .noAnswer }
                guard let route = Self.parseAdsbdb(data) else { return .unknown }
                return .route(route)
            }()

            DispatchQueue.main.async { completion(answer) }
        }.resume()
    }

    /// The batch endpoint, asked about one callsign — the fallback.
    ///
    /// Nil for anything that is not a route, which the caller reads together
    /// with what adsbdb said: neither source having one is a miss worth
    /// remembering, and a request that failed is not.
    private func askAdsbLol(
        key: String,
        flight: Flight,
        completion: @escaping (Route?) -> Void
    ) {
        guard let url = AppConfig.realWorldRoutesURL,
              let body = Self.body(for: [(key: key, flight: flight)])
        else { return completion(nil) }

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
                guard let self = self else { return completion(nil) }

                // A failure here backs the *batch* off too, which is the same
                // rule the sweep keeps: a service that is refusing will still
                // be refusing in fifteen seconds.
                guard let found = found else {
                    self.retryAfter = Date().addingTimeInterval(Self.retryDelay)
                    self.outcome = Self.trouble(code: code, error: error)
                    return completion(nil)
                }

                self.retryAfter = nil
                completion(found[key] ?? nil)
            }
        }.resume()
    }

    /// adsbdb's answer: `response.flightroute.origin.icao_code` and the same
    /// under `destination`.
    ///
    /// Read leniently, like everything else here. A body that cannot be walked
    /// to those two codes is no route rather than an error — the caller has
    /// already separated "they answered" from "the request worked" out of the
    /// status, which is the distinction that matters for the cache.
    private static func parseAdsbdb(_ data: Data?) -> Route? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let flightroute = response["flightroute"] as? [String: Any]
        else { return nil }

        // The midpoint a few of them carry is deliberately ignored: the useful
        // pair is the two ends of the journey, which is the same choice the
        // batch endpoint's multi-leg strings get.
        guard let departure = icao(flightroute["origin"]),
              let arrival = icao(flightroute["destination"]),
              departure != arrival
        else { return nil }

        return Route(departure: departure, arrival: arrival)
    }

    /// One end of an adsbdb route, as an ICAO code.
    ///
    /// The IATA code beside it is deliberately not a fallback here. The batch
    /// endpoint hands over a string that may be either and taking the IATA pair
    /// is better than a dash; this one carries both separately, so a missing
    /// `icao_code` means the field is genuinely absent rather than that a
    /// different spelling arrived.
    private static func icao(_ value: Any?) -> String? {
        guard let airport = value as? [String: Any],
              let code = (airport["icao_code"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .uppercased(),
              (3...4).contains(code.count),
              code.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }

        return code
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

    /// One row, taken if it is readable.
    ///
    /// ## Why `plausible` is no longer consulted
    ///
    /// It was, and it is why a great many aeroplanes drew a dash. The field
    /// reads as a judgement about the aircraft — adsb.lol's own check that it
    /// is where that route would put it — and the app rejected a row without
    /// it, which is a defensible thing to do with a judgement like that.
    ///
    /// It is not that judgement. In their `calc_plausible` the geometry is
    /// worked out and then thrown away: the helper it calls returns a *tuple*
    /// of the verdict and the distance, and a non-empty tuple is true whichever
    /// way the verdict went. So the loop returns true on its first pass and the
    /// field only ever comes back false when the loop did not run at all —
    /// which happens when fewer than two of the route's airports could be found
    /// in their own airport table.
    ///
    /// That is a fact about a lookup table, not about an aeroplane, and
    /// rejecting on it threw away routes that were perfectly good: the pair of
    /// ICAO codes was right there in the row being discarded.
    ///
    /// So the pair is taken whenever it can be read. The cost is that a row
    /// their data places badly is now drawn, and the honest answer to that is
    /// the one the window already gives — it has never called this a filed
    /// plan, and the credit under it names it an estimate.
    private static func route(from row: [String: Any]) -> Route? {
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

    private func isEmpty(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
