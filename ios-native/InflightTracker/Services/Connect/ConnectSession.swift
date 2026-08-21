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

    /// When the last connection was attempted, where, and how it went.
    ///
    /// The panel had no way of showing that anything was being tried at all —
    /// only a status word, which reads the same whether the session is knocking
    /// once a second or has never run. That is the difference between "the sim
    /// is refusing" and "this feature is switched off and nobody said so", and
    /// a pilot cannot tell them apart without it.
    struct Attempt: Equatable {
        let at: Date
        let address: String
        let outcome: String
        let succeeded: Bool
    }

    @Published private(set) var lastAttempt: Attempt?

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

            // Switching this on when reading is off used to do nothing
            // whatsoever, silently — every path below is gated on `isEnabled`,
            // so the pilot got a switch that moved and a feature that never
            // ran. Worse, the two rows read as alternatives: one says "read
            // from the sim", the other says "it's on this device", and turning
            // the first off to choose the second is the obvious thing to do
            // and is exactly wrong.
            //
            // There is only one thing "the sim is on this device" can mean, and
            // it is "read from the sim, which is here". So it says that.
            guard isEnabled else {
                if isSameDevice { isEnabled = true }
                return
            }
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

    /// Whether this run of the loop has already offered the sim's held landing
    /// to the logbook. Once per run rather than once per attach: a reconnection
    /// mid-flight is not a landing to catch up on, and re-offering the same one
    /// on every retry would be work for nothing.
    private var hasCaughtUpThisRun = false

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

    /// Backoff inside a background window, where the entire budget is about
    /// thirty seconds and a sixty-second wait is indistinguishable from not
    /// trying again.
    ///
    /// Infinite Flight can take most of a minute to get from a tap on its icon
    /// to a state where it answers on 10112, and the pilot who has just left
    /// this app is usually launching it rather than returning to it already
    /// running. So the window keeps knocking for as long as it has.
    private static let windowRetryDelays: [UInt64] = [1, 1, 2, 3, 5]
    private var retryIndex = 0

    /// How many attempts a remembered address gets before the session goes
    /// back out and looks for the sim again. Three, because the first failure
    /// is usually the sim not being started yet -- a state that fixes itself
    /// and wants no searching -- while a third is a number that has moved.
    private static let attemptsBeforeRediscovery = 3

    /// Whether the pilot has been left waiting since they turned this on, and
    /// so is owed the notification when it finally attaches.
    ///
    /// Separate from `retryIndex`, which cannot answer this and was the reason
    /// the notification never arrived. `retryIndex` is reset by `start()`, and
    /// `start()` runs every time the app comes back to the foreground — which
    /// is precisely the moment the connection succeeds, because the pilot has
    /// just been in Infinite Flight switching Connect on. So the one path that
    /// always ends in a successful attach was also the one path guaranteed to
    /// have forgotten that anybody was waiting.
    ///
    /// This is set when a connection fails and cleared only when the notice has
    /// been sent or the switch has been turned off, so it survives the app
    /// being suspended and resumed as many times as it takes.
    private var isOwedConnectionNotice = false

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
            Task { @MainActor in self?.handleBackgrounding() }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                // Whatever is left of the background window is finished with:
                // the sim is behind us again and the pilot is looking at this
                // screen, which is where the panel does the telling.
                self.endBackgroundWindow(expired: false)

                guard self.isEnabled else { return }

                // The catch-up used to be here, and only here. It now lives at
                // the top of `run()` instead, so the cold launch gets it too --
                // see the note there. Coming back to the foreground is just
                // another start.
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
            // Whatever a previous attempt left open is closed from here rather
            // than from wherever it was cancelled. Both used to be spawned as
            // free-standing tasks, so a stale close could land on top of this
            // attempt's fresh socket and take it down; done in order it cannot.
            await self?.closeTransport()
            await self?.run()
        }
    }

    /// Closes the socket in the caller's own order of operations.
    private func closeTransport() async {
        await transport.close()
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
        hasCaughtUpThisRun = false
        atcLog = []
        lastCatchUp = nil
        // Turning it off is not waiting for it. Only `stop()` clears this —
        // `suspend()` deliberately does not, because being suspended IS the
        // wait.
        isOwedConnectionNotice = false
        announcedProblem = nil
        hasAnnouncedThisWindow = false
        simUsernameMismatch = nil
        endBackgroundWindow(expired: false)
    }

    /// Backgrounded: drop the socket but keep the intention to reconnect.
    private func suspend() {
        pollTask?.cancel()
        pollTask = nil
        cancelDiscovery()
        Task { await transport.close() }
        if isEnabled { status = .off }
    }

    // MARK: - The one window a phone has
    //
    // On a single phone the two apps can never both be in front, and until now
    // that meant the link could never be made at all: every attempt was made
    // from our own foreground, which is exactly when iOS has Infinite Flight
    // suspended and its Connect socket is answering nobody. A pilot switching
    // back and forth to see whether it had worked was watching the one state
    // where it cannot work, and the panel sat on "Waiting for Infinite Flight"
    // for the whole flight while nothing was wrong with either app.
    //
    // The moment it *can* work is the moment we are put away, because the app
    // replacing us is the simulator. iOS grants a finite window to an app that
    // asks for one on the way out — around thirty seconds, no entitlement, no
    // background mode, nothing claimed that is not true — and thirty seconds is
    // enough to attach, read the flight id, take a telemetry sample, publish a
    // live status the server can then keep alive from the feed, and say so.
    //
    // This is not the fourteen-hour socket that `CONNECT.md` explains cannot be
    // had. It is one window per app switch, which is what makes "open Infinite
    // Flight, come back" produce something rather than nothing.

    /// The finite window iOS has granted, if any.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Whether this window has already had its say, so an attach and a failure
    /// inside the same thirty seconds do not both raise a banner.
    private var hasAnnouncedThisWindow = false

    /// The last thing announced as blocking the link. Kept so the identical
    /// sentence is not delivered again on the next app switch — a pilot who has
    /// not switched Connect on inside the sim needs telling once, not every
    /// time they change apps.
    private var announcedProblem: String?

    private func handleBackgrounding() {
        // Two devices: nothing here changes anything there. The sim is on the
        // other one and does not care which app is in front on this one, so
        // there is nothing to gain by staying awake and a battery cost to it.
        guard isEnabled, isSameDevice else {
            suspend()
            return
        }

        hasAnnouncedThisWindow = false
        beginBackgroundWindow()

        // Start again rather than continue. Whatever the session was doing a
        // moment ago it was doing against a suspended simulator; this attempt
        // is the first one with the sim actually in front, and it should not
        // have to wait out a sixty-second backoff earned by attempts that never
        // had a chance. `stop()` is deliberately not used: it would clear the
        // record of the pilot having been kept waiting, which is the only thing
        // that decides whether attaching is worth announcing.
        pollTask?.cancel()
        pollTask = nil
        cancelDiscovery()
        start()
    }

    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Infinite Flight Connect"
        ) { [weak self] in
            // Called on the main thread when iOS wants the time back. It has to
            // end promptly, so the session is torn down here rather than left
            // to be killed with the process.
            Task { @MainActor in self?.endBackgroundWindow(expired: true) }
        }
    }

    /// Gives the window back. `expired` distinguishes iOS taking it from the
    /// pilot returning to the app, which are different endings: only the first
    /// has anything to report, because only the first happens while they are
    /// still looking at Infinite Flight.
    private func endBackgroundWindow(expired: Bool) {
        let task = backgroundTask
        backgroundTask = .invalid

        if expired {
            announceOutcome()
            suspend()
        }

        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// One banner, at the end of a window, and only when it says something the
    /// pilot could not already see.
    ///
    /// This is the half of the feature that used to be impossible. The notice
    /// existed before and could only ever fire while the app was open, which is
    /// the one moment it tells nobody anything. Fired from the window instead it
    /// arrives over the top of Infinite Flight — where the pilot is, and where
    /// the switch that fixes it lives.
    private func announceOutcome() {
        guard !hasAnnouncedThisWindow else { return }

        if status.isLive {
            // Attaching already announced itself. Nothing to add.
            return
        }

        guard case let .waiting(reason) = status else { return }
        guard reason != announcedProblem else { return }

        hasAnnouncedThisWindow = true
        announcedProblem = reason

        PushService.shared.post(
            title: "Not reading Infinite Flight",
            body: reason,
            // Its own identifier, so the failure and the success replace
            // themselves rather than each other: a pilot who fixes it should
            // see the connected notice arrive alongside, not silently overwrite
            // the explanation they were following.
            identifier: "connect.blocked"
        )
    }

    /// Forget the remembered address and go back out to look for the sim.
    ///
    /// The address field cannot express this on its own: it is prefilled with
    /// whatever was last used and its button is disabled when empty, so a
    /// pilot whose sim has moved to a new address had no way to say so short
    /// of typing the new one -- which is the thing they came here not knowing.
    func searchAgain() {
        host = ""
        guard isEnabled else { return }
        stop()
        start()
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
        // Same device: the flight just flown happened while this app was
        // suspended behind Infinite Flight -- or was not running at all, which
        // is the ordinary case after a long one, because iOS jettisons a
        // backgrounded app to give the sim its memory back. Either way the
        // simulator is still holding the landing, so a session asks for it
        // before the poll loop takes the socket.
        //
        // This hung off `willEnterForeground` alone, which a cold launch does
        // not deliver to an object that does not exist yet: `shared` is first
        // touched by `ContentView.onAppear`, by which point the notification
        // has been and gone. So the one path that matters most -- land, come
        // back, open the app -- was the one path that never caught up, and the
        // pilot saw nothing happen.
        //
        // It used to be a whole second connection of its own, opened and closed
        // before the poll loop was allowed to dial. That cost a connect and an
        // entire manifest fetch -- seconds -- at the exact moment there are
        // only seconds: on a phone the simulator is reachable for a short
        // while after the pilot switches away from it, and whichever of the
        // two attempts came first was spending that time twice over. It is now
        // done from the poll loop's own connection, on its first attach, which
        // is why `attach` takes the landing before adopting it as the baseline.
        hasCaughtUpThisRun = false

        while !Task.isCancelled {
            do {
                let address = try await resolveHost()

                try await attach(to: address)
                retryIndex = 0
                lastAttempt = Attempt(at: Date(), address: address, outcome: "Connected", succeeded: true)

                // Tell them if they were kept waiting — a connection that
                // worked first time while they watched needs no announcement —
                // and tell them in a background window whether they were kept
                // waiting or not, because in a window they are inside Infinite
                // Flight and the panel that would otherwise say so is behind
                // it. That is the whole point of the window: the answer to
                // "did it connect?" arriving where the question is asked.
                let inWindow = backgroundTask != .invalid
                if isOwedConnectionNotice || (inWindow && !hasAnnouncedThisWindow) {
                    isOwedConnectionNotice = false
                    announceConnected(to: address)
                }

                try await poll()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .waiting(error.localizedDescription)
                lastAttempt = Attempt(
                    at: Date(),
                    address: isSameDevice ? Self.loopback : host,
                    outcome: error.localizedDescription,
                    succeeded: false
                )
                await transport.close()

                // From here on there is something to announce, and a reason to
                // be able to announce it. Asking now rather than when the
                // switch was flipped means the prompt only ever appears to
                // somebody who is actually being made to wait, with the
                // question in front of them.
                if !isOwedConnectionNotice {
                    isOwedConnectionNotice = true
                    // Only ever asked with the app in front. A permission
                    // prompt raised from a background window would be held by
                    // iOS and shown much later, out of the context that
                    // justified it.
                    if PushService.shared.authorization == .notDetermined,
                       UIApplication.shared.applicationState == .active {
                        PushService.shared.requestAuthorization()
                    }
                }

                let schedule = backgroundTask != .invalid ? Self.windowRetryDelays : Self.retryDelays
                let delay = schedule[min(retryIndex, schedule.count - 1)]
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
        hasAnnouncedThisWindow = true
        // Whatever was blocking this is no longer blocking it, so the next time
        // it does block the explanation is new again and worth sending.
        announcedProblem = nil

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

        // A remembered address is tried first. It is usually right, it costs
        // nothing, and it is the only thing that works at all on a network
        // where discovery is refused.
        //
        // What it is not is permanent. The address is a DHCP lease: the device
        // running the sim reboots, rejoins the Wi-Fi, or is a different device
        // this time, and the number moves. Discovery only ever ran when `host`
        // was empty, so nothing ever went to look again -- the session dialled
        // an address nobody was answering on, once a minute, for the length of
        // a flight, while the panel sat on "Waiting for Infinite Flight" with
        // no way out but typing a new address by hand.
        if !host.isEmpty && retryIndex < Self.attemptsBeforeRediscovery {
            return host
        }

        status = .searching
        do {
            let found = try await discover()
            host = found
            return found
        } catch {
            // Nothing announced itself. A remembered address that has been
            // failing is still a better guess than no address at all, so it
            // takes the next attempt rather than the session giving up on it.
            guard !host.isEmpty else { throw error }
            return host
        }
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
        // connection existed. Adopted silently as the mark to beat -- but on a
        // same-device session it is also the landing the pilot has just made
        // and come back to have recorded, so it is offered to the logbook on
        // the way past. Offering it twice is free: `pilot_logbook_attach_
        // landing` only ever fills columns that are still empty.
        landingBaseline = nil
        let catchingUp = isSameDevice && !hasCaughtUpThisRun
        hasCaughtUpThisRun = true
        try await readLanding(adoptingBaseline: true, offeringToLogbook: catchingUp)

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

            // The first pass is the first moment there is a position to share,
            // and on one device it may also be one of the few. Publishing on it
            // rather than waiting for the 45-second heartbeat is what puts the
            // flight in front of other people at all when the connection lasts
            // half a minute.
            if pass == 0 { LiveStatusPublisher.shared.publishNow() }

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

        adoptIdentity(from: next)
    }

    /// The pilot's own name, taken from the simulator rather than asked for.
    ///
    /// `infiniteflight/current_user` has been read on every connection since
    /// Connect existed, shown in the panel, and then dropped on the floor —
    /// while the same name, typed by hand into a settings field, is what joins
    /// this account to an aeroplane on the map. Everything that needs to know
    /// which flight is yours needs that join: the map's "this is me", and the
    /// server's announcements about your own flight, which cannot be addressed
    /// without it.
    ///
    /// Asking somebody to type a name the app is already being told is how the
    /// join ends up blank or misspelled, so a blank one is filled in from here.
    /// A DIFFERENT one is not overwritten: a profile is public, and rewriting
    /// the name on it because a simulator disagreed is a surprise rather than a
    /// repair. `ConnectPanel` offers that swap instead, with both names in
    /// front of the pilot.
    private func adoptIdentity(from snapshot: ConnectTelemetry) {
        guard let raw = snapshot.username?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }

        // The local one first: it is what the map highlights your own aeroplane
        // by, it is nobody else's business, and a blank one there is pure loss.
        if !PilotIdentity.shared.isSet {
            PilotIdentity.shared.set(raw)
        }

        guard let profile = ProfileStore.shared.profile else { return }
        let stored = profile.ifUsername.trimmingCharacters(in: .whitespacesAndNewlines)

        if stored.isEmpty {
            Task { await ProfileStore.shared.adoptSimUsername(raw) }
            simUsernameMismatch = nil
        } else if stored.lowercased() != raw.lowercased() {
            simUsernameMismatch = raw
        } else {
            simUsernameMismatch = nil
        }
    }

    /// The name the sim reports, when the profile says something else.
    ///
    /// Surfaced rather than acted on. It is the likeliest reason a pilot who
    /// has done everything right hears nothing about their own flight — the
    /// server is looking for the name on the profile and the map is showing the
    /// one in the sim — and it is not a thing to fix behind their back.
    @Published private(set) var simUsernameMismatch: String?

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
        /// There is nowhere to put a landing. A logbook belongs to a profile,
        /// so without one this cannot do anything — and used to say nothing
        /// either, which made the button look broken rather than inapplicable.
        case needsAccount

        var label: String {
            switch self {
            case let .attached(fpm):    return "Landing recorded: \(fpm) fpm"
            case .nothingToAttach:      return "No new landing to record"
            case .simulatorNotReachable: return "Infinite Flight wasn't running"
            case .needsAccount:         return "Sign in and claim a handle to record landings"
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
        guard AccountStore.shared.isSignedIn, ProfileStore.shared.hasProfile else {
            lastCatchUp = .needsAccount
            return
        }

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
            // A cancelled catch-up is the switch being turned off mid-read, and
            // `stop()` has already cleared this. Reporting it would put the
            // result back after the state it belongs to has gone.
            guard !Task.isCancelled else { return }
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

    private func readLanding(
        adoptingBaseline: Bool = false,
        offeringToLogbook: Bool = false
    ) async throws {
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
            if offeringToLogbook { lastCatchUp = .nothingToAttach }
            return
        }

        var candidate = landing
        candidate.noticedAt = .distantPast

        // Opening the connection adopts whatever is already there without
        // reporting it. See `landingBaseline`.
        if adoptingBaseline {
            landingBaseline = candidate

            // ...except on the first attach of a same-device session, where
            // "whatever is already there" is very likely the touchdown the
            // pilot has just come back to the app to have recorded.
            if offeringToLogbook, let rate = landing.verticalSpeedFPM {
                lastLanding = landing
                let held = landing
                let flightID = telemetry.flightID
                // Not awaited: the poll loop owns this connection and the
                // logbook write is a round trip to Supabase. Making the first
                // telemetry pass wait on it would spend the seconds this whole
                // reordering exists to save.
                Task { [weak self] in
                    let attached = await LogbookRecorder.shared.attach(held, flightID: flightID)
                    self?.lastCatchUp = attached ? .attached(fpm: Int(rate.rounded())) : .nothingToAttach
                }
            }
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
        case .atcFacility:
            let name = value.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.atcFacility = (name?.isEmpty ?? true) ? nil : name
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
