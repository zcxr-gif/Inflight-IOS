import Foundation

/// How many tile requests this app is willing to make, and when it stops asking.
///
/// ## Why a meter exists at all
///
/// RainViewer's free tier is metered, and since 1 January 2026 it is metered
/// hard: **100 requests per IP per minute, for everybody** — the schedule is in
/// `old/www/rainviewer.txt`. A minute is a long time on a map. A pinch from an
/// ocean down to an approach crosses a dozen zooms, each of which is a fresh
/// screenful of tile paths the caches have never seen, and a radar loop on top
/// of that multiplies the screenful by the number of frames it touches.
///
/// Nothing above this had any idea how many requests it was making. The pieces
/// that existed — four connections per host, the loop stopping when the service
/// said 429 — shape a burst and react to a refusal, and neither of them counts.
/// So the app would go over the line, get turned away, and then *keep asking at
/// the same rate*, because a refused tile is not cached and every pan asks for
/// it again. The limiter stays tripped, every tile after it is refused too, and
/// the layer sits there empty saying it is rate-limited. Which it is, by itself.
///
/// This is the counter that was missing. It sits in front of the network and
/// answers one question — may this request be made — from three things:
///
/// - a **token bucket**, held well under what the tier allows, so ordinary use
///   never reaches the line in the first place;
/// - a **pause**, entered when the bucket runs dry or the service says 429,
///   during which nothing is asked at all;
/// - a **memory of refusals**, so a tile the service has already said no to is
///   not re-requested on every pan back over the same ground.
///
/// A request this turns down is not a failure and is not reported as one: the
/// fetch falls back to the tile cache and draws whatever is already there. See
/// `RainViewerTileOverlay.fetch(at:reportingFailures:completion:)`.
///
/// ## The pause has to be announced
///
/// A tile skipped during a pause is a tile MapKit was handed nothing for, and
/// MapKit does not ask twice — so the hole stays until something makes a new
/// overlay. That is what `onPause` is for: whoever is watching gets told when
/// the holding-back started and when it ends, and can ask for the screen again
/// on the other side of it. A meter that quietly drops requests and never says
/// so trades one blank layer for a subtler one.
///
/// Only RainViewer is metered. NASA's GIBS has no quota and no key, so the
/// satellite layer is not put through this — a budget on a service that does
/// not meter is a layer drawn worse for nothing.
final class WeatherTileBudget {

    /// The meter in front of RainViewer.
    ///
    /// Sixty a minute against the hundred the tier allows, with a burst of
    /// forty. The headroom is deliberate: the index fetch, a second device on
    /// the same network, and the app's own retries all come out of the same
    /// per-IP allowance, and a budget that aims exactly at the limit is a budget
    /// that crosses it.
    static let rainViewer = WeatherTileBudget(
        requestsPerMinute: 60,
        burst: 40,
        refusedPause: 45,
        spentPause: 10
    )

    /// How long a refusal is remembered, so the same one is not fetched again
    /// on the next pan. Short enough that a frame coming back — or a tier
    /// changing — is noticed within a few minutes.
    private static let refusalMemory: TimeInterval = 5 * 60

    /// Told when requests start being held back, with the moment they will be
    /// allowed again.
    ///
    /// Set once, by `RainViewerService`, before anything asks this anything.
    /// Called on whatever thread tripped the pause and never while the lock is
    /// held, so what it does is its own business.
    var onPause: ((Date) -> Void)?

    /// Tokens added per second, and the most that can be saved up.
    private let refillPerSecond: Double
    private let burst: Double

    /// How long the app goes quiet after the *service* says it is asking too
    /// fast. Long, because being told that means the counter that matters — the
    /// service's — is already over, and the only thing that brings it down is
    /// time with no requests in it.
    private let refusedPause: TimeInterval

    /// How long it goes quiet after running out of its *own* budget. Short,
    /// because nothing has gone wrong: this is the meter doing its job a little
    /// early, and a long stall here would be the layer punishing somebody for
    /// panning around.
    private let spentPause: TimeInterval

    private let lock = NSLock()
    private var tokens: Double
    private var lastRefill: Date
    private var pausedUntilDate: Date?
    private var refusals: [String: Date] = [:]

    init(
        requestsPerMinute: Double,
        burst: Double,
        refusedPause: TimeInterval,
        spentPause: TimeInterval
    ) {
        self.refillPerSecond = requestsPerMinute / 60
        self.burst = burst
        self.refusedPause = refusedPause
        self.spentPause = spentPause
        self.tokens = burst
        self.lastRefill = Date()
    }

    /// When the pause ends, or nil when nothing is holding requests back.
    ///
    /// What `RainViewerService` checks before deciding the coast is clear: a
    /// throttle that only cleared on a successful tile could never clear,
    /// because the throttle is the reason no tile is being fetched.
    var pausedUntil: Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let until = pausedUntilDate, until > Date() else { return nil }
        return until
    }

    /// Whether a request for this address may go to the network now.
    ///
    /// Spends a token when it says yes, so this is asked once per request and
    /// the answer acted on — calling it to *look* would quietly spend the
    /// budget.
    func permits(_ address: String) -> Bool {
        let now = Date()

        lock.lock()
        let allowed = decide(address, now: now)
        let began = paused
        paused = nil
        lock.unlock()

        if let began = began { onPause?(began) }
        return allowed
    }

    /// What a request that *was* permitted came back as.
    ///
    /// Only permitted requests are reported here. A request this budget turned
    /// down never reached the service and says nothing about it.
    func note(address: String, status: Int, failed: Bool) {
        let now = Date()

        lock.lock()
        record(address, status: status, failed: failed, now: now)
        let began = paused
        paused = nil
        lock.unlock()

        if let began = began { onPause?(began) }
    }

    /// Forget the pause and the refusals. For a change of layer, or a fresh
    /// index — both are a fresh chance for tiles that were being turned away.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pausedUntilDate = nil
        paused = nil
        refusals.removeAll(keepingCapacity: true)
        tokens = burst
        lastRefill = Date()
    }

    // MARK: - Under the lock

    /// A pause entered by the call in progress, to be announced once the lock is
    /// let go. Announcing it while holding the lock would run somebody else's
    /// code inside this one's critical section.
    private var paused: Date?

    private func decide(_ address: String, now: Date) -> Bool {
        if let until = pausedUntilDate {
            if until > now { return false }
            // The pause is spent. Start again with a full bucket rather than
            // whatever it had drained to, so the first look afterwards draws a
            // screenful instead of trickling in a tile at a time.
            pausedUntilDate = nil
            tokens = burst
            lastRefill = now
        }

        if let refused = refusals[address] {
            if refused > now { return false }
            refusals.removeValue(forKey: address)
        }

        tokens = min(burst, tokens + now.timeIntervalSince(lastRefill) * refillPerSecond)
        lastRefill = now

        guard tokens >= 1 else {
            hold(from: now, for: spentPause)
            return false
        }

        tokens -= 1
        return true
    }

    private func record(_ address: String, status: Int, failed: Bool, now: Date) {
        guard failed else {
            refusals.removeValue(forKey: address)
            return
        }

        switch status {
        case 429:
            // Over the line despite the bucket — a second device on the same
            // address, most likely, or an allowance smaller than published.
            // Stop entirely, and drain what is left so the pause is not undone
            // by a token that survived it.
            tokens = 0
            hold(from: now, for: refusedPause)
        case 401, 402, 403, 404:
            // A settled no: this tile, at this zoom, is not served. Asking
            // again in a moment gets the same answer and spends the allowance
            // that the zooms which *are* served need.
            remember(address, from: now)
        default:
            // A 5xx or an unreachable host is the service having a bad minute
            // or the device having no signal. Neither is a reason to stop
            // asking for this tile specifically.
            break
        }
    }

    /// Starts a pause, or extends one, and queues the announcement.
    private func hold(from now: Date, for duration: TimeInterval) {
        let until = now.addingTimeInterval(duration)
        guard until > (pausedUntilDate ?? .distantPast) else { return }
        pausedUntilDate = until
        paused = until
    }

    /// Remembers one refused address, keeping the table from growing without
    /// bound over a long session of panning.
    private func remember(_ address: String, from now: Date) {
        if refusals.count > 512 {
            refusals = refusals.filter { $0.value > now }
            if refusals.count > 512 { refusals.removeAll(keepingCapacity: true) }
        }
        refusals[address] = now.addingTimeInterval(Self.refusalMemory)
    }
}
