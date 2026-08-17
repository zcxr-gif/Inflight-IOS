import Foundation

/// Fetches the route an aircraft filed.
///
/// Addressed by session rather than by server, so every lookup resolves the
/// session first — `SessionService` holds that for five minutes, which means
/// this is one request in practice.
///
/// A plan is filed once and rarely amended, so an answer is held for the
/// session. The one thing that does move is where the aircraft is along it, and
/// that is worked out on the device from a position the feed is already
/// sending.
final class FlightPlanService {

    static let shared = FlightPlanService()

    private struct Entry {
        let plan: FlightPlan?
        let fetched: Date
    }

    private var cache: [String: Entry] = [:]
    private var waiting: [String: [(FlightPlan?) -> Void]] = [:]
    private let lock = NSLock()

    /// Long enough that opening the same aircraft twice is instant, short
    /// enough to pick up a route amended in the air.
    private let lifetime: TimeInterval = 300

    private init() {}

    func cached(flightId: String) -> FlightPlan? {
        lock.lock()
        defer { lock.unlock() }
        return cache[flightId]?.plan
    }

    /// `completion` runs on the main thread. Nil means no plan filed, which is
    /// cached like any other answer — most aircraft on a casual server have
    /// none, and re-asking every time one is opened would be a request per tap
    /// for a reply that will not change.
    func plan(flightId: String, server: String, completion: @escaping (FlightPlan?) -> Void) {
        lock.lock()
        if let entry = cache[flightId], Date().timeIntervalSince(entry.fetched) < lifetime {
            let plan = entry.plan
            lock.unlock()
            DispatchQueue.main.async { completion(plan) }
            return
        }

        if waiting[flightId] != nil {
            waiting[flightId]?.append(completion)
            lock.unlock()
            return
        }
        waiting[flightId] = [completion]
        lock.unlock()

        SessionService.shared.sessionId(for: server) { [weak self] sessionId in
            guard let self = self else { return }

            guard let sessionId = sessionId,
                  let encodedFlight = flightId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "\(AppConfig.socketURLString)/flights/\(encodedSession)/\(encodedFlight)/plan")
            else {
                // No session is a failure to ask rather than an answer, so it
                // is reported without being cached — the next open tries again.
                self.finish(flightId: flightId, plan: nil, cache: false)
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12

            URLSession.shared.dataTask(with: request) { data, _, _ in
                let plan = data.flatMap { Self.decode($0) }
                self.finish(flightId: flightId, plan: plan, cache: true)
            }
            .resume()
        }
    }

    private func finish(flightId: String, plan: FlightPlan?, cache shouldCache: Bool) {
        lock.lock()
        if shouldCache {
            // A busy session opens a lot of aircraft; this is a session-long
            // cache, not a permanent one.
            if cache.count > 120 { cache.removeAll(keepingCapacity: true) }
            cache[flightId] = Entry(plan: plan, fetched: Date())
        }
        let waiters = waiting.removeValue(forKey: flightId) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for waiter in waiters { waiter(plan) }
        }
    }

    // MARK: - Decoding

    /// One entry in `flightPlanItems`.
    ///
    /// Recursive: a departure or arrival procedure arrives as an item whose
    /// `children` are its fixes. Both spellings of the name are read — the
    /// backend has used `identifier` for fixes and `name` for procedures, and
    /// either can be the one that is filled in.
    struct Item: Decodable {
        struct Location: Decodable {
            let latitude: Double?
            let longitude: Double?
            let altitude: Double?
        }

        let name: String?
        let identifier: String?
        let altitude: Double?
        let location: Location?
        let children: [Item]?

        /// What to call it, preferring the shorter of the two — `identifier` is
        /// the fix's published name, `name` is often the same thing spelled out.
        var label: String {
            let candidates = [identifier, name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return candidates.first ?? ""
        }
    }

    private struct Envelope: Decodable {
        struct Plan: Decodable {
            let flightPlanItems: [Item]?
        }

        let ok: Bool?
        let plan: Plan?
    }

    private static func decode(_ data: Data) -> FlightPlan? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.ok != false,
              let items = envelope.plan?.flightPlanItems,
              !items.isEmpty else { return nil }

        return FlightPlan.from(items: items)
    }
}
