import ActivityKit
import Combine
import Foundation

/// The live banner: Dynamic Island, lock screen, and the widget that keeps
/// counting down after the phone is put away.
///
/// There are two ways one starts, and the difference matters:
///
///   - the user taps Banner on a flight, and we `request` it here. The system
///     hands back a token we register so the backend can push progress.
///   - a watched pilot takes off and the *backend* starts it, spending the
///     push-to-start token registered below. Nothing in the app runs at that
///     moment — the phone may be in a pocket — so the activity appears without
///     this process being involved at all.
///
/// The second is the interesting one, and it is why `observeRemoteStarts` has
/// to exist: an activity the server started still needs its per-activity
/// update token sent back, or it appears once and then never moves again.
final class LiveActivityController: ObservableObject {

    static let shared = LiveActivityController()

    /// Flight ids with a banner currently running, so the UI can offer Stop
    /// instead of Start. Published rather than recomputed from
    /// `Activity.activities` on every render — that call is not free, and the
    /// flight window asks on every packet.
    @Published private(set) var trackedFlightIds: Set<String> = []

    private var observationsStarted = false

    private init() {}

    var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isTracking(flightId: String) -> Bool { trackedFlightIds.contains(flightId) }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Lifecycle

    /// Called once per launch. Picks up activities that outlived the app —
    /// started on a previous run, or started by the backend while the app was
    /// not running at all.
    func resumeTracking() {
        guard !observationsStarted else { return }
        observationsStarted = true

        for activity in Activity<InflightActivityAttributes>.activities {
            adopt(activity)
        }

        observeRemoteStarts()
        registerPushToStartToken()
    }

    /// Take responsibility for an activity: remember which flight it belongs
    /// to, follow its token stream, and drop it from the tracked set once it
    /// ends — whether this process ended it or the backend did.
    private func adopt(_ activity: Activity<InflightActivityAttributes>) {
        let flightId = activity.attributes.flightId
        guard !flightId.isEmpty else {
            // An activity with no flight id can still be pushed to; it just
            // can't be matched to a row in the UI.
            observeTokens(of: activity, flightId: nil)
            return
        }

        onMain { [weak self] in self?.trackedFlightIds.insert(flightId) }
        observeTokens(of: activity, flightId: flightId)

        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .dismissed || state == .ended else { continue }
                self?.onMain { self?.trackedFlightIds.remove(flightId) }
                return
            }
        }
    }

    // MARK: - Starting

    /// Start a banner for a flight the user picked.
    ///
    /// Returns false when Live Activities are switched off for the app, which
    /// the caller turns into an explanation rather than a silent no-op.
    @discardableResult
    func start(for flight: Flight) -> Bool {
        guard isSupported else { return false }
        guard !trackedFlightIds.contains(flight.id) else { return true }

        let progress = FlightProgress(flight: flight)
        let ete = progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) ?? 0
        let arrival = Date().addingTimeInterval(ete)

        let attributes = InflightActivityAttributes(
            callsign: flight.displayName,
            airlineName: flight.liveryName,
            aircraftType: flight.aircraftName,
            liveryName: flight.liveryName,
            registration: flight.registration ?? "",
            departureIcao: flight.departureIcao ?? "",
            arrivalIcao: flight.arrivalIcao ?? "",
            scheduledDeparture: Date(),
            scheduledArrival: arrival,
            totalDistanceNm: progress?.totalNM ?? 0,
            pilotUsername: flight.username ?? "",
            flightId: flight.id
        )

        let state = InflightActivityAttributes.ContentState(
            distanceToDestinationNm: progress?.remainingNM ?? 0,
            currentETA: arrival,
            isLanded: false,
            lastUpdated: Date(),
            altitudeFt: Int(flight.altitudeFeet),
            groundSpeedKt: Int(flight.groundSpeedKnots)
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                // Token, not local: the backend drives this for the whole
                // flight, which is hours the app will not be running for.
                pushType: .token
            )
            adopt(activity)
            return true
        } catch {
            print("[live-activity] Could not start: \(error.localizedDescription)")
            return false
        }
    }

    /// Ends the banner for one flight, and only that one. Matching on the
    /// flight id in the attributes matters: somebody watching three friends
    /// has three activities running, and stopping one must not clear the lot.
    func stop(flightId: String) {
        trackedFlightIds.remove(flightId)
        Task {
            for activity in Activity<InflightActivityAttributes>.activities
            where activity.attributes.flightId == flightId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Tokens

    /// The push-to-start token: one per install, and the thing that lets a
    /// takeoff raise a banner on a phone nobody is holding.
    func registerPushToStartToken() {
        guard isSupported else { return }
        Task { [weak self] in
            for await tokenData in Activity<InflightActivityAttributes>.pushToStartTokenUpdates {
                await self?.register(token: Self.hex(tokenData), kind: "start", flightId: nil)
            }
        }
    }

    /// Per-activity update tokens. Re-issued by the system over the life of an
    /// activity, so this is a stream rather than a single read — registering
    /// only the first one leaves the banner frozen partway through the flight.
    private func observeTokens(of activity: Activity<InflightActivityAttributes>, flightId: String?) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                await self?.register(
                    token: Self.hex(tokenData),
                    kind: "update",
                    flightId: flightId ?? activity.attributes.flightId,
                    activityId: activity.id
                )
            }
        }
    }

    /// Activities that appeared without this process asking for one — i.e.
    /// started by the backend off a takeoff.
    private func observeRemoteStarts() {
        Task { [weak self] in
            for await activity in Activity<InflightActivityAttributes>.activityUpdates {
                self?.adopt(activity)
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The backend files Live Activity tokens against the APNs device token,
    /// so a token registered before APNs has answered would have nothing to
    /// belong to. Skipped rather than queued: the system re-issues these on
    /// every launch, and by the next one the device token is in hand.
    private func register(token: String, kind: String, flightId: String?, activityId: String? = nil) async {
        guard let deviceToken = PushService.shared.deviceToken,
              let url = AppConfig.liveActivityTokensURL else { return }
        // The backend can't file an update token without knowing which flight
        // it updates, and would answer 400. Nothing to salvage — skip it here
        // rather than log a rejection every time the system reissues.
        if kind == "update", (flightId ?? "").isEmpty { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body: [String: Any] = ["deviceToken": deviceToken, "token": token, "kind": kind]
        if let flightId = flightId, !flightId.isEmpty { body["flightId"] = flightId }
        if let activityId = activityId { body["activityId"] = activityId }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                print("[live-activity] Token registration rejected: HTTP \(http.statusCode)")
            }
        } catch {
            print("[live-activity] Token registration failed: \(error.localizedDescription)")
        }
    }
}
