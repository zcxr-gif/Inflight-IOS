import Combine
import Foundation
import Network
import UIKit

/// The app's link to Infinite Flight running on another device.
///
/// ## What this is, and what it is not
///
/// Connect is a **local** API. It is served by the sim itself to whatever is on
/// the same Wi-Fi, with no account and no token, and there is no hosted
/// endpoint — so none of this can be done on the backend, and none of it works
/// away from home. It never replaces the live feed, which describes everybody's
/// flights from the cloud. It is a second source, present only sometimes, that
/// knows things the feed cannot: what the wheels were doing at the moment they
/// touched the runway, and which live flight this actually is.
///
/// Because it is sometimes-present, every consumer has to work without it. The
/// logbook still records flights inferred from the feed exactly as it always
/// has; a Connect session upgrades those rows rather than being required for
/// them.
///
/// ## Shape of a session
///
/// ```
///   discover (or take the address) -> connect -> manifest -> resolve -> poll
/// ```
///
/// The manifest step is not optional and not cacheable across aircraft: state
/// ids differ per aircraft and are not stable across Infinite Flight releases,
/// so the catalogue is fetched fresh on every connection and every path is
/// resolved against it. That is what stops an update silently turning an
/// altitude into a fuel reading.
@MainActor
final class ConnectSession: ObservableObject {

    static let shared = ConnectSession()

    enum Status: Equatable {
        case off
        case searching
        case connecting(String)
        case syncing(String)
        case live(String)

        /// Not connected, still trying, and here is why the last attempt did
        /// not work.
        ///
        /// Replaces what used to be `failed`, which was a lie about what the
        /// session was doing: the loop has always retried forever on a backoff,
        /// so a pilot who started Infinite Flight a minute later was already
        /// going to be connected automatically — while the panel sat there
        /// saying "Couldn't connect" in orange as though it had given up.
        /// Saying "waiting" is both truer and the thing that makes starting the
        /// sim second the obvious move.
        case waiting(String)

        var isBusy: Bool {
            switch self {
            case .searching, .connecting, .syncing: return true
            default: return false
            }
        }

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }

        /// Trying, and not there yet — the spinner-or-not question, and the one
        /// the settings row uses to decide whether to sound patient.
        var isWaiting: Bool {
            if case .waiting = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var telemetry = ConnectTelemetry()
    @Published private(set) var lastLanding: ConnectLanding?

    /// What has been said on frequency, newest first.
    ///
    /// Capped hard. This is a live view of a conversation, not an archive: the
    /// panel shows a handful, the live row carries a handful, and nothing keeps
    /// the rest — which is the whole reason this feature costs no storage.
    @Published private(set) var atcLog: [ConnectATCMessage] = []

    private static let atcLogLimit = 12

    /// A one-line summary of what the connected aircraft publishes, shown in
    /// the settings screen so a pilot can see the link is real.
    @Published private(set) var manifestSummary: String?

    /// Fields named in `ConnectField` that this aircraft does not publish.
    /// Surfaced rather than swallowed — it is the fastest way to find a path
    /// whose spelling has changed.
    @Published private(set) var unresolvedFields: [ConnectField] = []

    /// The address last connected to, remembered so the next flight is one tap.
    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }

    /// Whether Infinite Flight is on THIS device rather than another one.
    ///
    /// Changes three things, and is worth its own switch for each of them:
    ///
    ///   * the address becomes loopback, so there is nothing to discover and
    ///     nothing to type;
    ///   * **no local network permission is involved at all.** Apple's
    ///     local-network privacy covers the network — unicast to a LAN address,
    ///     multicast, broadcast, Bonjour. 127.0.0.1 is none of those, so a
    ///     same-device connection never raises the prompt and never needs the
    ///     multicast entitlement;
    ///   * the app stops expecting to watch a whole flight, because on one
    ///     device it cannot. See `catchUp`.
    @Published var isSameDevice: Bool {
        didSet {
            defaults.set(isSameDevice, forKey: Self.sameDeviceKey)
            guard isEnabled else { return }
            stop()
            isEnabled = true
        }
    }

    /// Whether the app should attach automatically when it can.
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private static let hostKey = "connect.host"
    private static let enabledKey = "connect.enabled"
    private static let sameDeviceKey = "connect.sameDevice"

    /// Infinite Flight serves Connect on every interface it has, loopback
    /// included, so an app on the same device reaches it here.
    ///
    /// `nonisolated` so the transport can name it when explaining a failure:
    /// this class is `@MainActor`, which isolates its statics too, and the
    /// error translator runs on Network.framework's queue.
    nonisolated static let loopback = "127.0.0.1"

    private let defaults: UserDefaults
    private let transport = ConnectTransport()

    private var manifest = ConnectManifest()
    private var resolved: [ConnectField: ConnectManifest.Entry] = [:]

    /// The landing the sim was already holding when this connection opened.
    ///
    /// Infinite Flight keeps the last touchdown until the next one, so the
    /// first read after attaching returns whatever the pilot did before the app
    /// was even looking — possibly days ago, possibly on a flight already in
    /// the logbook. Without a baseline that stale reading is indistinguishable
    /// from a landing that has just happened, and the first thing this feature
    /// would do on every connection is record a flight that did not occur.
    private var landingBaseline: ConnectLanding?

    private var pollTask: Task<Void, Never>?
    private var discoveryListener: NWListener?

    /// How often the landing group is read, counted in passes of the fast loop.
    /// Landings do not happen every second and each extra read slows the
    /// position updates that do.
    private static let landingEveryNPasses = 5

    /// How often configuration and weather are read. Gear, flaps and wind
    /// change on the scale of a phase of flight; reading twenty-five states
    /// every pass would quarter the rate of the eight that actually move.
    private static let periodicEveryNPasses = 8

    /// Backoff between reconnection attempts, in seconds. A sim that is closed
    /// stays closed, and a client that retries every second on a phone in
    /// somebody's pocket is a battery complaint.
    private static let retryDelays: [UInt64] = [2, 5, 10, 30, 60]
    private var retryIndex = 0

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        host = defaults.string(forKey: Self.hostKey) ?? ""
        isSameDevice = defaults.bool(forKey: Self.sameDeviceKey)
        isEnabled = defaults.bool(forKey: Self.enabledKey)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // iOS suspends us shortly after this and the socket dies with the
            // process's attention. Closing deliberately means the next
            // foreground starts from a known state rather than from a
            // half-dead connection whose reads all time out.
            Task { @MainActor in self?.suspend() }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }

                // Same device: the flight happened while this app was
                // suspended, so the first thing to do on coming back is ask
                // the sim what it is still holding. Then resume normally,
                // which on an iPad in Split View is a full live session and on
                // a phone is a connection that will not outlive the switch
                // away.
                if self.isSameDevice {
                    await self.catchUp()
                }
                self.start()
            }
        }
    }

    // MARK: - Driving

    func start() {
        guard isEnabled else { return }
        guard pollTask == nil else { return }

        retryIndex = 0
        pollTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        cancelDiscovery()
        Task { await transport.close() }
        status = .off
        telemetry = ConnectTelemetry()
        manifestSummary = nil
        unresolvedFields = []
        landingBaseline = nil
        atcLog = []
        lastCatchUp = nil
    }

    /// Backgrounded: drop the socket but keep the intention to reconnect.
    private func suspend() {
        pollTask?.cancel()
        pollTask = nil
        cancelDiscovery()
        Task { await transport.close() }
        if isEnabled { status = .off }
    }

    /// Connect to a specific address, remembering it.
    func connect(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        host = trimmed
        if !isEnabled { isEnabled = true } else { stop(); start() }
    }

    // MARK: - The loop

    private func run() async {
        while !Task.isCancelled {
            do {
                let address = try await resolveHost()
                let hadBeenWaiting = retryIndex > 0

                try await attach(to: address)
                retryIndex = 0

                // Tell them, but only if they were kept waiting.
                //
                // The whole point of retrying quietly is that the pilot can
                // start Infinite Flight whenever they like and put the phone
                // down; the notification is what closes that loop, and it has
                // to reach them with this app in the background, which is
                // exactly where they will be. A connection that worked first
                // time needs no announcement — they were watching.
                if hadBeenWaiting { announceConnected(to: address) }

                try await poll()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .waiting(error.localizedDescription)
                await transport.close()

                let delay = Self.retryDelays[min(retryIndex, Self.retryDelays.count - 1)]
                retryIndex += 1

                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// One line, once, when a link the pilot has been waiting for comes up.
    private func announceConnected(to address: String) {
        let place = address == Self.loopback ? "on this device" : "at \(address)"
        PushService.shared.post(
            title: "Connected to Infinite Flight",
            body: "Reading your aircraft from the sim \(place).",
            // One identifier for this event, so reconnecting through a flaky
            // Wi-Fi replaces the notice instead of stacking a column of them.
            identifier: "connect.attached"
        )
    }

    private func resolveHost() async throws -> String {
        // Same device: there is nothing to find and nothing to ask permission
        // for. Straight to loopback.
        if isSameDevice { return Self.loopback }

        if !host.isEmpty { return host }

        status = .searching
        let found = try await discover()
        host = found
        return found
    }

    private func attach(to address: String) async throws {
        status = .connecting(address)
        try await transport.connect(host: address)

        status = .syncing(address)
        let raw = try await transport.manifest()
        manifest = ConnectManifest(raw: raw)

        guard !manifest.isEmpty else {
            throw ConnectTransport.Failure.socket("Infinite Flight sent an empty manifest.")
        }

        // Every path the app knows about, resolved once per connection. A field
        // that is absent here is simply never read; the feature that wanted it
        // is the one that goes quiet, and everything else carries on.
        resolved = [:]
        var missing: [ConnectField] = []
        for field in ConnectField.allCases {
            if let entry = manifest.resolve(field.candidates) {
                resolved[field] = entry
            } else {
                missing.append(field)
            }
        }
        unresolvedFields = missing

        let shape = manifest.namespaceCounts
            .prefix(4)
            .map { "\($0.count) \($0.name)" }
            .joined(separator: ", ")
        manifestSummary = "\(manifest.count) states — \(shape)"

        // Identity first: without the flight id this is telemetry from nowhere
        // in particular, and the whole integration is that it is not.
        try await readSession()

        // Whatever landing the sim is already holding belongs to before this
        // connection existed. Adopted silently as the mark to beat.
        landingBaseline = nil
        try await readLanding(adoptingBaseline: true)

        await attachATC()

        status = .live(address)
    }

    private func poll() async throws {
        var pass = 0

        while !Task.isCancelled {
            var next = telemetry

            for field in ConnectField.live {
                guard let entry = resolved[field] else { continue }
                let value = try await read(entry)
                apply(field, value, to: &next)
            }

            next.sampledAt = Date()
            telemetry = next

            if pass % Self.periodicEveryNPasses == 0 {
                try await readPeriodic()
            }

            if pass % Self.landingEveryNPasses == 0 {
                try await readLanding()
            }

            // Re-read the session identity occasionally rather than every pass.
            // It changes when the pilot ends a flight and starts another, which
            // is rare enough that once every few seconds is instant and often
            // enough that a stale flight id never reaches the logbook.
            if pass % 20 == 0 && pass > 0 {
                try await readSession()
            }

            pass &+= 1

            // A breath between passes. Without it this is a tight loop of
            // round trips that heats the phone and gains nothing: the sim does
            // not move meaningfully in 50 milliseconds.
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func read(_ entry: ConnectManifest.Entry) async throws -> ConnectProtocol.Value? {
        let payload = try await transport.read(entry.id)
        return ConnectProtocol.decode(entry.type, from: payload)
    }

    private func readPeriodic() async throws {
        var next = telemetry
        for field in ConnectField.periodic {
            guard let entry = resolved[field] else { continue }
            let value = try await read(entry)
            apply(field, value, to: &next)
        }
        next.sampledAt = Date()
        telemetry = next
    }

    private func readSession() async throws {
        var next = telemetry
        for field in ConnectField.session {
            guard let entry = resolved[field] else { continue }
            let value = try await read(entry)
            apply(field, value, to: &next)
        }
        next.sampledAt = Date()
        telemetry = next
    }

    // MARK: - Catching up on one device
    //
    // ## Why a whole flight cannot be watched on one device
    //
    // While you fly, Infinite Flight is in front and iOS suspends everything
    // behind it — this app included. There is no honest way around that: the
    // background modes that would keep a socket alive for fourteen hours are
    // `audio` and `location`, and claiming either to poll a flight simulator
    // would be a lie to the user and to App Review.
    //
    // ## Why it does not matter for the thing that matters
    //
    // The simulator HOLDS the last landing until the next one. Nobody has to be
    // watching at the moment of touchdown — the measurement is still sitting
    // there when you come back. So the flight is recorded from the live feed
    // exactly as it always is, and this fills the landing in afterwards.
    //
    // ## Where it is genuinely live instead
    //
    // iPad, in Split View or Stage Manager. Both apps are on screen, neither is
    // backgrounded, and the ordinary poll loop runs for the whole flight over
    // loopback. That is the good configuration and it needs no permission at
    // all. On a phone, this catch-up is the whole feature.

    /// Whether the last catch-up found something, for the panel to report.
    @Published private(set) var lastCatchUp: CatchUpResult?

    enum CatchUpResult: Equatable {
        case attached(fpm: Int)
        case nothingToAttach
        case simulatorNotReachable

        var label: String {
            switch self {
            case let .attached(fpm):    return "Landing recorded: \(fpm) fpm"
            case .nothingToAttach:      return "No new landing to record"
            case .simulatorNotReachable: return "Infinite Flight wasn't running"
            }
        }
    }

    /// Opens a short connection, reads the landing the sim is still holding, and
    /// attaches it to the flight the feed already recorded.
    ///
    /// Deliberately a separate path from the poll loop rather than a special
    /// case inside it. It has to work in the seconds after switching apps —
    /// possibly the only seconds available before iOS suspends Infinite Flight
    /// behind us — so it does the least it can: connect, manifest, read two
    /// groups, hang up. No polling, no landing baseline, no live status.
    ///
    /// Duplicates are not its problem. `pilot_logbook_attach_landing` only ever
    /// fills columns that are still empty, so offering the same landing twice
    /// is free and offering it to an already-measured flight does nothing.
    func catchUp() async {
        guard isEnabled, isSameDevice else { return }
        guard AccountStore.shared.isSignedIn, ProfileStore.shared.hasProfile else { return }

        // Already live — an iPad in Split View — so the poll loop is watching
        // properly and there is nothing to catch up on.
        guard !status.isLive else { return }

        do {
            try await transport.connect(host: Self.loopback, timeout: 3)

            let raw = try await transport.manifest(timeout: 8)
            let catalogue = ConnectManifest(raw: raw)
            guard !catalogue.isEmpty else { throw ConnectTransport.Failure.notConnected }

            // The sim's own flight id, when it still has one. After the pilot
            // has ended their flight it will be absent, and the server falls
            // back to the most recent flight with no landing on it.
            var flightID: String?
            if let entry = catalogue.resolve(ConnectField.flightID.candidates),
               let value = try? await read(entry) {
                flightID = value.text
            }

            var landing = ConnectLanding()
            for field in ConnectField.landing {
                guard let entry = catalogue.resolve(field.candidates) else { continue }
                guard let value = try? await read(entry) else { continue }

                switch field {
                case .landingVerticalSpeed:     landing.verticalSpeedFPM = value.number
                case .landingScore:             landing.score = value.number
                case .landingGForce:            landing.maxGForce = value.number
                case .landingCentrelineOffset:  landing.centrelineOffsetMetres = value.number
                case .landingAimingPointOffset: landing.aimingPointOffsetMetres = value.number
                case .landingGroundSpeed:       landing.groundSpeedKnots = value.number
                case .landingAirspeed:          landing.indicatedAirspeedKnots = value.number
                default: break
                }
            }

            await transport.close()

            guard landing.isRecorded, let rate = landing.verticalSpeedFPM else {
                lastCatchUp = .nothingToAttach
                return
            }

            lastLanding = landing
            let attached = await LogbookRecorder.shared.attach(landing, flightID: flightID)
            lastCatchUp = attached ? .attached(fpm: Int(rate.rounded())) : .nothingToAttach

        } catch {
            await transport.close()
            // Not an error worth showing as one. On a phone the simulator being
            // gone by the time you switch across is the ordinary case, not a
            // fault.
            lastCatchUp = .simulatorNotReachable
        }
    }

    // MARK: - ATC
    //
    // The one part of this that is genuinely pushed rather than polled: once
    // the stream is on, Infinite Flight sends a frame every time something is
    // said on frequency, without being asked. `ConnectTransport` routes frames
    // nobody asked for here rather than handing them to whichever read happened
    // to be outstanding — which is what stops an ATC transcript arriving where
    // an altitude was expected.

    private func attachATC() async {
        atcLog = []

        guard let message = resolved[.atcMessage] else { return }

        await transport.onUnsolicited { [weak self] id, payload in
            guard id == message.id else { return }
            guard case let .string(text)? = ConnectProtocol.decode(.string, from: payload) else {
                return
            }
            Task { @MainActor in self?.noteATC(text) }
        }

        // Turning the stream on. Best-effort by nature — whether a state accepts
        // a write is published nowhere — so a failure here means the log stays
        // empty rather than anything breaking.
        if let toggle = resolved[.atcStreamEnable] {
            _ = try? await transport.write(toggle.id, .boolean(true), as: toggle.type)
        }
    }

    private func noteATC(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The sim repeats the current message on some paths, so an identical
        // line arriving straight after the last one is the same line rather
        // than a controller saying it twice.
        if atcLog.first?.text == ConnectATCMessage(raw: trimmed).text { return }

        atcLog.insert(ConnectATCMessage(raw: trimmed), at: 0)
        if atcLog.count > Self.atcLogLimit {
            atcLog.removeLast(atcLog.count - Self.atcLogLimit)
        }
    }

    // MARK: - Landings

    private func readLanding(adoptingBaseline: Bool = false) async throws {
        var landing = ConnectLanding()

        for field in ConnectField.landing {
            guard let entry = resolved[field] else { continue }
            let value = try await read(entry)

            switch field {
            case .landingVerticalSpeed:     landing.verticalSpeedFPM = value?.number
            case .landingScore:             landing.score = value?.number
            case .landingGForce:            landing.maxGForce = value?.number
            case .landingCentrelineOffset:  landing.centrelineOffsetMetres = value?.number
            case .landingAimingPointOffset: landing.aimingPointOffsetMetres = value?.number
            case .landingGroundSpeed:       landing.groundSpeedKnots = value?.number
            case .landingAirspeed:          landing.indicatedAirspeedKnots = value?.number
            case .landingLatitude:          landing.latitude = value?.number
            case .landingLongitude:         landing.longitude = value?.number
            case .landingFlightTime:        landing.flightTimeSeconds = value?.number
            default: break
            }
        }

        guard landing.isRecorded else {
            // Nothing recorded at all. On a fresh install of the sim, or after
            // it has been restarted, this is the honest state and the first
            // real landing will be new by definition.
            if adoptingBaseline { landingBaseline = ConnectLanding() }
            return
        }

        var candidate = landing
        candidate.noticedAt = .distantPast

        // Opening the connection adopts whatever is already there without
        // reporting it. See `landingBaseline`.
        if adoptingBaseline {
            landingBaseline = candidate
            return
        }

        // The sim holds the last landing until the next one, so the same values
        // come back on every pass. A landing is *new* when the numbers change —
        // compared ignoring `noticedAt`, the one field that differs every time
        // by construction.
        guard let baseline = landingBaseline else {
            // Attached without a baseline, which should not happen. Treat this
            // reading as the baseline rather than as a landing: under-reporting
            // one touchdown is a great deal better than inventing one.
            landingBaseline = candidate
            return
        }

        guard candidate != baseline else { return }

        landingBaseline = candidate
        landing.noticedAt = Date()
        lastLanding = landing

        LogbookRecorder.shared.note(landing: landing, flightID: telemetry.flightID)
    }

    // MARK: - Mapping

    private func apply(
        _ field: ConnectField,
        _ value: ConnectProtocol.Value?,
        to snapshot: inout ConnectTelemetry
    ) {
        guard let value else { return }

        switch field {
        case .flightID:          snapshot.flightID = value.text
        case .serverID:          snapshot.serverID = value.text
        case .serverName:        snapshot.serverName = value.text
        case .username:          snapshot.username = value.text
        case .appState:          snapshot.appState = value.text
        case .appVersion:        snapshot.appVersion = value.text
        case .engineCount:       snapshot.engineCount = value.number.map { Int($0) }

        case .latitude:          snapshot.latitude = value.number
        case .longitude:         snapshot.longitude = value.number
        case .altitudeMSL:       snapshot.altitudeMSL = value.number
        case .altitudeAGL:       snapshot.altitudeAGL = value.number
        case .headingMagnetic:   snapshot.headingMagnetic = value.number
        case .groundSpeed:       snapshot.groundSpeed = value.number
        case .indicatedAirspeed: snapshot.indicatedAirspeed = value.number
        case .trueAirspeed:      snapshot.trueAirspeed = value.number
        case .verticalSpeed:     snapshot.verticalSpeed = value.number
        case .pitch:             snapshot.pitch = value.number
        case .bank:              snapshot.bank = value.number
        case .turnRate:          break

        case .gearState:         snapshot.gearState = value.number.map { Int($0) }
        case .flapsState:        snapshot.flapsState = value.number.map { Int($0) }
        case .flapsAngle:        break
        case .spoilersState:     snapshot.spoilersState = value.number.map { Int($0) }
        case .parkingBrake:      snapshot.parkingBrake = value.flag
        case .reverseThrust:     snapshot.reverseThrust = value.flag
        case .transponderCode:   snapshot.transponderCode = value.number.map { Int($0) }
        case .seatbeltSign:      break

        case .beaconLights:      snapshot.beaconLights = value.flag
        case .landingLights:     snapshot.landingLights = value.flag
        case .navLights:         snapshot.navLights = value.flag
        case .strobeLights:      snapshot.strobeLights = value.flag

        case .fuelRemaining:     snapshot.fuelRemainingKg = value.number
        case .engineN1:          snapshot.engineN1 = value.number
        case .engineThrust:      snapshot.engineThrust = value.number

        case .warningStalling:   snapshot.isStalling = value.flag
        case .warningOverspeed:  snapshot.isOverspeeding = value.flag

        case .windDirection:     snapshot.windDirection = value.number
        case .windVelocity:      snapshot.windVelocity = value.number
        case .windGust:          snapshot.windGust = value.number
        case .temperature:       snapshot.temperature = value.number
        case .turbulence:        break

        case .nearestAirport:    snapshot.nearestAirport = value.text
        case .nextWaypoint:      snapshot.nextWaypoint = value.text
        case .flightTime:        snapshot.flightTimeSeconds = value.number

        case .landingVerticalSpeed, .landingScore, .landingGForce,
             .landingCentrelineOffset, .landingAimingPointOffset,
             .landingGroundSpeed, .landingAirspeed,
             .landingLatitude, .landingLongitude, .landingFlightTime:
            // Collected into `ConnectLanding` by `readLanding`, never onto the
            // rolling snapshot: a landing is an event with its own lifetime,
            // not a reading that happens to be current.
            break

        case .atcStreamEnable, .atcMessage:
            // Neither is ever polled. The first is written once to turn the
            // stream on; the second arrives unasked and is routed to `noteATC`
            // by the transport's unsolicited sink.
            break
        }
    }

    // MARK: - Discovery

    /// Listens for the broadcast Infinite Flight sends while Connect is on.
    ///
    /// This is the part iOS may refuse. Local network access needs
    /// `NSLocalNetworkUsageDescription` and the user's permission, and Apple
    /// additionally gates broadcast and multicast behind an entitlement granted
    /// by application. Whether passively receiving a broadcast falls under that
    /// gate is genuinely unclear, so discovery is treated throughout as a
    /// convenience: it is tried, it is given ten seconds, and when it fails the
    /// settings screen asks for the address by hand — which always works.
    private func discover(timeout: TimeInterval = 10) async throws -> String {
        cancelDiscovery()

        guard let port = NWEndpoint.Port(rawValue: ConnectProtocol.broadcastPort) else {
            throw ConnectTransport.Failure.socket("Bad broadcast port.")
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: port)
        discoveryListener = listener

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let settled = Settled()

                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    connection.receiveMessage { data, _, _, _ in
                        guard let data,
                              let address = Self.address(fromBroadcast: data) else {
                            connection.cancel()
                            return
                        }
                        connection.cancel()
                        if settled.claim() { continuation.resume(returning: address) }
                    }
                }

                listener.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        if settled.claim() {
                            continuation.resume(
                                throwing: ConnectTransport.Failure.socket(error.localizedDescription)
                            )
                        }
                    }
                }

                listener.start(queue: .main)

                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if settled.claim() {
                        continuation.resume(
                            throwing: ConnectTransport.Failure.socket(
                                "Couldn't find Infinite Flight on this network. "
                                + "Check Connect is switched on in its settings, "
                                + "or enter the device's address by hand."
                            )
                        )
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelDiscovery() }
        }
    }

    private func cancelDiscovery() {
        discoveryListener?.stateUpdateHandler = nil
        discoveryListener?.newConnectionHandler = nil
        discoveryListener?.cancel()
        discoveryListener = nil
    }

    /// Pulls an IPv4 address out of the broadcast payload.
    ///
    /// The device advertises every address it holds — Wi-Fi, cellular, and any
    /// link-local it happens to have. Only a routable IPv4 is any use: the
    /// link-local `169.254.x.x` and the loopback are addresses this phone
    /// cannot reach, and picking one of those would fail with a timeout rather
    /// than an explanation.
    ///
    /// The key is matched without regard to case, because its spelling is not
    /// stable: the Connect v2 documentation shows `addresses`, older payload
    /// dumps show `Addresses`, and a literal subscript for either one silently
    /// finds nothing against the other — which looks exactly like Infinite
    /// Flight not being on the network, and sends the pilot to type an address
    /// by hand for no reason.
    nonisolated static func address(fromBroadcast data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addresses = payload.first(where: {
                  $0.key.caseInsensitiveCompare("addresses") == .orderedSame
              })?.value as? [String] else { return nil }

        return addresses.first { candidate in
            let parts = candidate.split(separator: ".")
            guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
            if candidate.hasPrefix("127.") || candidate.hasPrefix("169.254.") { return false }
            return true
        }
    }
}

/// A one-shot latch, so a continuation reachable from two callbacks is only
/// resumed once.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
