import Combine
import CoreLocation
import Foundation

/// Real aeroplanes, over the simulator's map.
///
/// ## What this is
///
/// A second source of traffic, from ADS-B: the position reports real aircraft
/// broadcast continuously and that a network of volunteer receivers picks up
/// and publishes. The layer asks one open aggregator what it can hear around
/// wherever the map is pointed, turns each answer into a `Flight` with
/// `origin == .realWorld`, and hands the array to whoever is drawing the world.
///
/// It is a **layer**, not a feed. Nothing here touches `LiveFeed`, and nothing
/// here reaches the logbook, the widgets, a Live Activity, the watchlist or a
/// flight window — a real airliner has no pilot profile to open, no plan filed
/// with our backend and no history for the replay to scrub through. It is
/// aeroplanes on a map, drawn in their own colour, and that is the whole of it.
///
/// ## Why it is off, loudly
///
/// Mixing real traffic into a flight simulator's map is a genuinely useful
/// thing to be able to do and a genuinely confusing thing to forget you have
/// done: every count in the app — the server's aircraft, the fields it ranks,
/// the traffic on frequency — is about Infinite Flight, and a map with two
/// hundred real aeroplanes on it can make all of them look wrong. So the layer
/// starts off, it says so on the map the entire time it is on (see
/// `RealWorldTrafficBanner`), and its aircraft are painted a colour nothing
/// else on the map uses.
///
/// ## What it is not
///
/// Not a certified source, and never presented as one. ADS-B coverage is what
/// volunteers happen to receive — excellent over Europe and North America, thin
/// over water, and missing military and other traffic that does not broadcast.
/// Nothing here is fit for any operational purpose, and the settings screen
/// says exactly that.
final class RealWorldTraffic: ObservableObject {

    static let shared = RealWorldTraffic()

    /// What the layer is doing, in the one sentence the banner and the settings
    /// row both read. They are the same sentence deliberately: the thing on the
    /// map and the thing in Settings disagreeing about whether real traffic is
    /// being drawn is the confusion this whole file exists to avoid.
    enum Status: Equatable {

        /// The switch is off. Nothing is fetched and nothing is drawn.
        case off

        /// On, but the map is zoomed too far out to draw a sweep honestly.
        /// See `AppConfig.realWorldMaxSpanDegrees`.
        case tooFarOut

        /// On, asked, nothing back yet.
        case waiting

        /// On and drawing, with however many aircraft the last sweep found.
        case live(Int)

        /// On, and the last sweep failed. Whatever is drawn is what the
        /// previous one found, until it ages out.
        case failed(String)

        /// The line under the switch, and the line on the banner.
        var label: String {
            switch self {
            case .off:        return "Off"
            case .tooFarOut:  return "Zoom in to see real traffic"
            case .waiting:    return "Looking…"
            case .live(let count):
                guard count > 0 else { return "No real traffic in range" }
                return "\(count) real aircraft"
            case .failed(let reason): return reason
            }
        }
    }

    private static let enabledKey = "realWorldTrafficEnabled"

    /// The switch, from Settings.
    ///
    /// Persisted, like every other preference in the app — a setting that
    /// silently resets itself is a setting nobody can rely on. What answers
    /// "did I leave this on" is not forgetting the choice but showing it: the
    /// banner over the map, and the colour the traffic is drawn in.
    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.enabledKey)
            isOn ? start() : stop()
        }
    }

    /// The real aircraft, ready to be drawn. Empty whenever the layer is off,
    /// out of range, or its last sweep has aged out.
    @Published private(set) var flights: [Flight] = []

    @Published private(set) var status: Status = .off

    /// When the last sweep that actually answered came back.
    @Published private(set) var lastUpdate: Date?

    /// Moves whenever `flights` does, and at no other time.
    ///
    /// The maps skip their whole annotation diff unless the stamp they were
    /// built from has changed, and they are handed one number rather than an
    /// array to compare — see `ContentView.trafficRevision`. Published so that
    /// a sweep landing is itself what redraws the map.
    @Published private(set) var revision = 0

    /// Where the map is looking, as last reported. Nil until something has
    /// drawn a map at all.
    private var centre: CLLocationCoordinate2D?

    /// How much of the world is on screen, in degrees of latitude.
    private var spanDegrees: Double = .greatestFiniteMagnitude

    private var lastFetch: Date?
    private var isFetching = false

    /// Whether a reported region is already waiting to be acted on, so a drag
    /// that reports sixty times a second schedules one piece of work rather
    /// than sixty. See `report`.
    private var isActingOnReport = false

    /// The sweep clock. Runs only while the layer is on, so an app with the
    /// switch off does exactly nothing here.
    private var timer: Timer?

    /// The sweep that has been asked for, so one can be abandoned when the
    /// layer is switched off mid-flight rather than landing on an empty map.
    private var task: URLSessionDataTask?

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.enabledKey)
        // Nothing is started here. `report` is what starts it, once something
        // has drawn a map and knows where it is pointed — asking the network
        // for traffic around a position the app has not worked out yet is a
        // request that can only be wrong.
        if isOn { status = .waiting }
    }

    // MARK: - What the map tells us

    /// Where the world is currently being drawn, and how much of it fits.
    ///
    /// Called from the flat map when it settles, from the planet on every
    /// frame of a drag, and from the flat map's own update pass as a safety
    /// net for a camera restored on launch that never fires a region change.
    /// So it is deliberately cheap: it writes two numbers and schedules.
    ///
    /// ## Why the rest is deferred a turn
    ///
    /// Two reasons, and either alone would be enough. The first is
    /// correctness: one of the callers is `updateUIView`, which runs *inside*
    /// a SwiftUI update, and everything this would otherwise do synchronously
    /// — starting the clock, publishing `tooFarOut`, moving the status to
    /// `waiting` — writes a `@Published` property that the view being updated
    /// is observing. The second is that the planet calls this per frame, and
    /// coalescing a drag's worth of calls into one is free here and is not
    /// free anywhere else.
    func report(centre: CLLocationCoordinate2D, spanDegrees: Double) {
        guard centre.latitude.isFinite, centre.longitude.isFinite else { return }

        self.centre = centre
        self.spanDegrees = spanDegrees.isFinite ? spanDegrees : .greatestFiniteMagnitude

        guard isOn, !isActingOnReport else { return }
        isActingOnReport = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isActingOnReport = false
            guard self.isOn else { return }

            // Also where the clock is started on a launch that already had the
            // switch on. It is deliberately not started in `init`: until
            // something has drawn a map there is no position to sweep around,
            // and a timer firing against nothing only burns battery.
            guard self.timer != nil else { return self.start() }

            self.refreshIfNeeded()
        }
    }

    // MARK: - The sweep clock

    private func start() {
        status = .waiting
        timer?.invalidate()
        // Tolerant on purpose: this is a background poll of a shared community
        // feed, and letting iOS line it up with whatever else is waking the
        // app is worth more than landing on the exact second.
        let timer = Timer(timeInterval: AppConfig.realWorldInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = AppConfig.realWorldInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refreshIfNeeded(force: true)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        isFetching = false
        lastFetch = nil
        lastUpdate = nil
        // Off means gone, on the same frame. A layer that empties a sweep later
        // would leave real aeroplanes on the map after the switch said they
        // were not there.
        publish(flights: [], status: .off)
    }

    private func tick() {
        guard isOn else { return }
        expireIfStale()
        refreshIfNeeded()
    }

    /// Drops a sweep that is too old to stand for what is in the sky now.
    ///
    /// The interval is fifteen seconds and this is ninety, so it takes several
    /// failures in a row — which in practice means no connection. Better an
    /// empty layer that says so than aeroplanes frozen where they were.
    private func expireIfStale() {
        guard !flights.isEmpty, let last = lastUpdate,
              Date().timeIntervalSince(last) > AppConfig.realWorldLifetime else { return }

        let reason: Status = {
            if case .failed = status { return status }
            return .failed("No answer from the network")
        }()
        publish(flights: [], status: reason)
    }

    private func refreshIfNeeded(force: Bool = false) {
        guard isOn else { return }

        // Too far out to be honest about. One sweep is a circle 250 miles
        // across, and at continent scale that is a blot rather than a picture
        // of the world's traffic — so nothing is drawn and the banner says
        // why. Whatever the last sweep found goes with it.
        guard spanDegrees <= AppConfig.realWorldMaxSpanDegrees else {
            task?.cancel()
            task = nil
            isFetching = false
            if !flights.isEmpty || status != .tooFarOut {
                publish(flights: [], status: .tooFarOut)
            }
            return
        }

        if !force, let last = lastFetch,
           Date().timeIntervalSince(last) < AppConfig.realWorldInterval {
            return
        }

        guard !isFetching, let centre = centre else { return }
        guard let url = AppConfig.realWorldTrafficURL(
            latitude: centre.latitude,
            longitude: centre.longitude,
            radiusNM: AppConfig.realWorldMaxRadiusNM
        ) else { return }

        isFetching = true
        lastFetch = Date()
        if flights.isEmpty, status != .waiting { status = .waiting }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // The open aggregators ask callers to identify themselves, so that a
        // client misbehaving at scale can be told rather than simply blocked.
        request.setValue(AppConfig.publicAPIUserAgent, forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            let parsed = Self.parse(data)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let cancelled = (error as? URLError)?.code == .cancelled

            DispatchQueue.main.async {
                // Abandoned — the layer was switched off, or the map zoomed
                // out past the limit, while this one was in the air. Whoever
                // cancelled it has already reset the bookkeeping and published
                // what should be on the map, so touching either here would be
                // this sweep undoing that.
                guard !cancelled else { return }

                self.isFetching = false
                self.task = nil

                guard self.isOn else { return }

                guard let parsed = parsed else {
                    // Whatever is drawn stays drawn until it ages out: one
                    // dropped request on a train is not a reason to empty the
                    // map. `expireIfStale` is what eventually does.
                    self.status = .failed(Self.reason(code: code, error: error))
                    return
                }

                self.lastUpdate = Date()

                // The same store the server's traffic writes to, told which
                // source this batch is — see `FlightTrailStore.record`. It is
                // what gives a real aeroplane a flown path on the map and a
                // profile in its window: not the backend's history, which does
                // not exist for one of these, but what this device has watched
                // since the layer was switched on.
                FlightTrailStore.shared.record(parsed, from: .realWorld)

                self.publish(flights: parsed, status: .live(parsed.count))
            }
        }

        self.task = task
        task.resume()
    }

    /// One place that writes both, so the drawn traffic and the sentence
    /// describing it can never disagree.
    private func publish(flights: [Flight], status: Status) {
        self.flights = flights
        self.status = status
        revision &+= 1
    }

    // MARK: - Reading the answer

    /// Nil for a response that could not be read at all, which is held apart
    /// from an empty sweep — a quiet corner of the world with no receivers
    /// nearby genuinely answers with no aircraft, and that is not a failure.
    private static func parse(_ data: Data?) -> [Flight]? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // `ac` is what the readsb-shaped endpoints answer with; `aircraft` is
        // the same array under the name some of them use. Read both, because
        // which one arrives is the aggregator's business and not ours.
        let raw = (root["ac"] as? [Any]) ?? (root["aircraft"] as? [Any])
        guard let raw = raw else { return nil }

        var out: [Flight] = []
        out.reserveCapacity(raw.count)

        for case let entry as [String: Any] in raw {
            guard let flight = Flight(adsb: entry) else { continue }
            out.append(flight)
        }

        return out
    }

    /// What the banner says when a sweep fails, in words rather than a number.
    private static func reason(code: Int, error: Error?) -> String {
        if code == 429 { return "The network is asking for fewer requests" }
        if code >= 500 { return "The network is having trouble" }
        if code >= 400 { return "The network refused the request" }
        if error != nil { return "No connection to the network" }
        return "Nothing readable came back"
    }
}
