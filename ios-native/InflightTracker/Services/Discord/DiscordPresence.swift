import Combine
import Foundation
import Security

/// Rich Presence: what someone is doing in the app, shown on their Discord
/// profile as "Playing Inflight".
///
/// Three things it can say, most specific first:
///
/// - **Flying** — Infinite Flight is connected and the pilot is in the sim:
///   their callsign, aircraft, route, level, and a countdown to arrival.
/// - **Watching** — a flight window is open: whose flight, the route, the
///   aircraft, and when it gets in.
/// - **Tracking** — just the map: how many aircraft are up on which server.
///
/// ## What it costs
///
/// Nothing while it is switched off or unlinked: no client, no timer. While
/// live, one composition every fifteen seconds and on the two events that
/// change what it says (a window opening or closing, the sim connecting), and
/// a send only when the card would actually read differently. Discord rate
/// limits presence, so a countdown that moves by a few seconds is not a
/// change; one that moves by two minutes is.
///
/// ## What it can't do
///
/// Presence lives as long as the app's connection to Discord, and iOS suspends
/// an app shortly after it leaves the screen. So the card shows while the app
/// is open — including side by side with Infinite Flight on an iPad — and
/// Discord takes it down a little while after it is put away. It comes back on
/// its own when the app does.
@MainActor
final class DiscordPresence: ObservableObject {

    static let shared = DiscordPresence()

    enum Link: Equatable {
        /// This build has no SDK, or no Discord application configured.
        case unavailable
        case unlinked
        case linking
        case connecting
        case live
        case failed(String)
    }

    @Published private(set) var link: Link

    /// The person's switch. Linking turns it on; it can be turned off without
    /// unlinking, which keeps the account for next time.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? resume() : suspend()
        }
    }

    private static let enabledKey = "discordPresenceEnabled"

    private var client: DiscordSDKClient?
    private weak var feed: LiveFeed?
    private var watchedFlightId: String?
    private var lastSent: DiscordActivity?
    private var lastSentAt: Date = .distantPast
    private var tick: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var sessionStart = Date()
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if !DiscordSDKClient.isCompiledIn || AppConfig.discordApplicationId == nil {
            link = .unavailable
        } else {
            link = DiscordTokenStore.read() == nil ? .unlinked : .connecting
        }
    }

    var isAvailable: Bool { link != .unavailable }

    // MARK: - Lifecycle

    /// Called once at launch, beside the other services.
    func start(feed: LiveFeed) {
        self.feed = feed
        guard isAvailable else { return }

        // The sim connecting or dropping is the one change worth saying at
        // once rather than on the next tick.
        ConnectSession.shared.$status
            .map(\.isLive)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }
            .store(in: &subscriptions)

        if isEnabled { resume() }
    }

    /// The app came back to the screen. Presence went with the connection
    /// when iOS suspended it, so it is sent again rather than assumed.
    func didBecomeActive() {
        sessionStart = Date()
        lastSent = nil
        if isEnabled { resume() }
    }

    /// The flight whose window is open, or nil when none is.
    func watching(_ flightId: String?) {
        guard flightId != watchedFlightId else { return }
        watchedFlightId = flightId
        schedule()
    }

    // MARK: - Linking

    func linkAccount() {
        guard isAvailable, let client = makeClient() else { return }
        link = .linking
        client.authorize { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tokens):
                DiscordTokenStore.save(tokens)
                // Switching it on connects, through `resume`; when it was on
                // already, nothing else will.
                if self.isEnabled {
                    self.connect(with: tokens)
                } else {
                    self.isEnabled = true
                }
            case .failure(let error):
                self.link = .failed(error.localizedDescription)
            }
        }
    }

    func unlinkAccount() {
        client?.clear()
        client?.disconnect()
        client = nil
        stopTicking()
        DiscordTokenStore.clear()
        lastSent = nil
        isEnabled = false
        if isAvailable { link = .unlinked }
    }

    // MARK: - Connection

    private func makeClient() -> DiscordSDKClient? {
        if let client { return client }
        guard let id = AppConfig.discordApplicationId,
              let made = DiscordSDKClient(applicationId: id) else { return nil }
        made.onStatus = { [weak self] status in self?.handle(status) }
        client = made
        return made
    }

    private func resume() {
        guard isAvailable, let tokens = DiscordTokenStore.read() else { return }
        guard let client = makeClient() else { return }

        if tokens.needsRefresh {
            link = .connecting
            client.refresh(tokens.refreshToken) { [weak self] result in
                switch result {
                case .success(let fresh):
                    DiscordTokenStore.save(fresh)
                    self?.connect(with: fresh)
                case .failure:
                    // A refresh token Discord no longer honours — revoked from
                    // the Discord side, or simply too old. Nothing to do but
                    // ask again.
                    DiscordTokenStore.clear()
                    self?.link = .unlinked
                }
            }
        } else if link != .live {
            connect(with: tokens)
        } else {
            startTicking()
        }
    }

    private func suspend() {
        client?.clear()
        lastSent = nil
        stopTicking()
    }

    private func connect(with tokens: DiscordTokens) {
        link = .connecting
        makeClient()?.connect(accessToken: tokens.accessToken)
    }

    private func handle(_ status: DiscordSDKClient.Status) {
        switch status {
        case .ready:
            link = .live
            lastSent = nil
            if isEnabled { startTicking() } else { client?.clear() }
        case .connecting:
            if link != .linking { link = .connecting }
        case .disconnected:
            stopTicking()
            if DiscordTokenStore.read() != nil { link = .connecting }
        case .failed(let message):
            stopTicking()
            link = .failed(message)
        }
    }

    // MARK: - Sending

    private func startTicking() {
        guard tick == nil else { schedule(); return }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.send()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func stopTicking() {
        tick?.cancel()
        tick = nil
        pending?.cancel()
        pending = nil
    }

    /// A send soon, coalescing a burst — opening one window after another, a
    /// connection that flaps — into one.
    private func schedule() {
        guard isEnabled, link == .live else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.send()
        }
    }

    private func send() {
        guard isEnabled, link == .live, let client else { return }
        let activity = compose()

        guard Self.differs(activity, from: lastSent) else { return }

        // Discord allows a handful of updates every twenty seconds; this keeps
        // well inside that even with a window being flicked open and shut.
        guard Date().timeIntervalSince(lastSentAt) >= 4 else { schedule(); return }

        lastSent = activity
        lastSentAt = Date()
        client.update(activity) { [weak self] error in
            // Sent again on the next tick rather than retried here: the tick
            // is never more than fifteen seconds away.
            if error != nil { self?.lastSent = nil }
        }
    }

    /// Whether the card would read differently. Times are compared loosely —
    /// an arrival estimate that drifts by seconds every packet is the same
    /// card, and resending it would spend the rate limit on nothing.
    private static func differs(_ new: DiscordActivity, from old: DiscordActivity?) -> Bool {
        guard let old else { return true }
        var looseNew = new, looseOld = old
        looseNew.end = nil; looseOld.end = nil
        if looseNew != looseOld { return true }
        switch (new.end, old.end) {
        case (nil, nil): return false
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) > 120
        default: return true
        }
    }

    // MARK: - What it says

    private func compose() -> DiscordActivity {
        let flights = feed?.flights ?? []
        let server = feed?.server ?? ""

        var buttons: [DiscordActivity.Button] = []
        if let handle = ProfileStore.shared.handle, let url = AppConfig.publicProfileURL(handle: handle) {
            buttons.append(.init(label: "Pilot profile", url: url))
        }
        buttons.append(.init(label: "Get Inflight", url: AppConfig.siteURL))

        // Flying, from the sim itself.
        let session = ConnectSession.shared
        if session.status.isLive {
            let track = LogbookRecorder.shared.inProgress
            let own = session.telemetry.flightID.flatMap { id in flights.first { $0.id == id } }

            let callsign = track?.callsign ?? own?.displayName ?? "a flight"
            let aircraft = track?.aircraft ?? own?.aircraftName
            let origin = track?.originIcao ?? own?.departureIcao
            let destination = track?.destinationIcao ?? own?.arrivalIcao

            return DiscordActivity(
                details: Self.join("Flying \(callsign)", aircraft),
                state: Self.join(Self.route(origin, destination), Self.level(session.telemetry.altitudeMSL)),
                largeImage: AppConfig.discordLargeImageKey,
                largeText: "Inflight",
                smallImage: AppConfig.discordFlyingImageKey,
                smallText: session.telemetry.serverName ?? track?.server,
                start: track?.departedAt ?? track?.startedAt,
                end: own.flatMap(Self.arrival),
                buttons: buttons
            )
        }

        // Watching one aircraft.
        if let id = watchedFlightId, let flight = flights.first(where: { $0.id == id }) {
            return DiscordActivity(
                details: Self.join("Watching \(flight.displayName)", flight.aircraftName),
                state: Self.join(Self.route(flight.departureIcao, flight.arrivalIcao), Self.level(flight.altitudeFeet)),
                largeImage: AppConfig.discordLargeImageKey,
                largeText: "Inflight",
                smallImage: AppConfig.discordWatchingImageKey,
                smallText: server.isEmpty ? nil : server,
                start: sessionStart,
                end: Self.arrival(flight),
                buttons: buttons
            )
        }

        // The map.
        let count = flights.count
        return DiscordActivity(
            details: "Tracking live flights",
            state: count > 0
                ? "\(count) aircraft up\(server.isEmpty ? "" : " on \(server)")"
                : nil,
            largeImage: AppConfig.discordLargeImageKey,
            largeText: "Inflight",
            start: sessionStart,
            buttons: buttons
        )
    }

    private static func arrival(_ flight: Flight) -> Date? {
        FlightProgress(flight: flight)?
            .estimatedTimeEnroute(for: flight)
            .map { Date().addingTimeInterval($0) }
    }

    private static func route(_ origin: String?, _ destination: String?) -> String? {
        let from = origin?.uppercased() ?? "", to = destination?.uppercased() ?? ""
        switch (from.isEmpty, to.isEmpty) {
        case (false, false): return "\(from) → \(to)"
        case (true, false): return "to \(to)"
        case (false, true): return "from \(from)"
        case (true, true): return nil
        }
    }

    /// Flight levels up high, feet down low — the way a controller says it.
    private static func level(_ feet: Double?) -> String? {
        guard let feet, feet.isFinite, feet > 500 else { return nil }
        if feet >= 18_000 { return String(format: "FL%03d", Int((feet / 100).rounded())) }
        return "\(Int((feet / 100).rounded()) * 100) ft"
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The linked account's tokens, in the Keychain beside the app's own session
/// and for the same reasons — see `SessionKeychain`.
enum DiscordTokenStore {

    private static let service = "com.tracker.Inflight.discord"
    private static let account = "tokens"

    static func save(_ tokens: DiscordTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read() -> DiscordTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DiscordTokens.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
