import Combine
import Foundation

/// Infinite Flight's own record of a pilot, fetched and remembered.
///
/// ## Why this exists next to `PilotDirectory`
///
/// They answer different questions about the same person and neither can
/// answer the other's. `PilotDirectory` reads Inflight's database — the profile
/// somebody made here, and the reader's relationship to it. This reads the
/// game's own API through our backend — the grade, the virtual airline, the
/// totals — which no Supabase function has and never will.
///
/// ## Why it caches, and why it caches misses
///
/// The card that uses this is drawn every time an aeroplane is tapped, and the
/// numbers behind it move on the scale of a flight rather than a packet: a
/// grade changes a few times a year. The backend already holds a five-minute
/// cache of its own, so without one here the app would be making a request per
/// tap to be handed the same cached block back over the network.
///
/// The misses are cached for the same reason `PilotDirectory` caches its own:
/// a name that resolves to nothing resolves to nothing every time, and the
/// failure is the *expensive* lookup — two calls into the Live API before the
/// backend can say no.
@MainActor
final class PilotStatsService: ObservableObject {

    static let shared = PilotStatsService()

    /// Long by the standards of this app, and still short by the standards of
    /// what it holds. A grade is not a live number.
    private nonisolated static let lifetime: TimeInterval = 10 * 60

    private struct Cached {
        let value: IFPilotStats?
        let at: Date

        var isFresh: Bool { Date().timeIntervalSince(at) < PilotStatsService.lifetime }
    }

    /// Keyed by account id, and by lowercased name for the lookups that had to
    /// start from one. Two maps rather than one namespaced key: a name lookup
    /// answers with an id, and the second map is what lets the id it resolved
    /// serve an aeroplane tapped a moment later.
    private var byUserId: [String: Cached] = [:]
    private var byUsername: [String: Cached] = [:]

    /// In-flight requests, so four views asking about the same pilot in the
    /// same layout pass make one request between them.
    private var pending: [String: Task<IFPilotStats?, Never>] = [:]

    private init() {}

    // MARK: - Reading

    /// The block for one account id. Nil when the backend has nothing, which
    /// for a pilot who has never flown online is an ordinary answer.
    func stats(userId: String) async -> IFPilotStats? {
        let key = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = byUserId[key], cached.isFresh { return cached.value }

        return await fetch(key: "id:\(key)", url: AppConfig.pilotStatsURL(userId: key)) { [weak self] answer in
            self?.byUserId[key] = Cached(value: answer, at: Date())
            if let name = answer?.username?.lowercased(), !name.isEmpty {
                self?.byUsername[name] = Cached(value: answer, at: Date())
            }
        }
    }

    /// The block for one Infinite Flight username.
    ///
    /// Used where there is no account id to start from: a flight from a backend
    /// too old to send one, and the profile setup, where the whole point is to
    /// find out whether the name a person typed is real.
    func stats(ifUsername: String) async -> IFPilotStats? {
        let raw = ifUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = raw.lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = byUsername[key], cached.isFresh { return cached.value }

        return await fetch(key: "name:\(key)", url: AppConfig.pilotStatsURL(ifUsername: raw)) { [weak self] answer in
            self?.byUsername[key] = Cached(value: answer, at: Date())
            if let id = answer?.userId, !id.isEmpty {
                self?.byUserId[id] = Cached(value: answer, at: Date())
            }
        }
    }

    /// Whichever way round is available, preferring the id.
    ///
    /// The convenience the flight window actually uses: it holds a `Flight`,
    /// which usually carries an id and always carries a name, and the caller
    /// has no business knowing which of the two routes that turns into.
    func stats(for flight: Flight) async -> IFPilotStats? {
        if let id = flight.userId, !id.isEmpty {
            return await stats(userId: id)
        }
        guard let name = flight.username, !name.isEmpty else { return nil }
        return await stats(ifUsername: name)
    }

    /// The same lookup as `stats(ifUsername:)`, keeping the difference between
    /// "no such pilot" and "could not ask".
    ///
    /// Everywhere else that difference is noise — a card with no grade on it
    /// looks the same either way, and a view has nothing useful to do with the
    /// distinction. On the setup screen it is the whole answer: "check the
    /// spelling" and "we couldn't reach Infinite Flight, carry on" are opposite
    /// instructions, and telling somebody their own username is wrong when the
    /// truth is that a request timed out is the worst thing that screen could
    /// say.
    func resolve(ifUsername: String) async -> Resolution {
        let raw = ifUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = raw.lowercased()
        guard !key.isEmpty else { return .missing }

        if let cached = byUsername[key], cached.isFresh {
            return cached.value.map(Resolution.found) ?? .missing
        }

        guard let url = AppConfig.pilotStatsURL(ifUsername: raw) else { return .missing }

        switch await Self.request(url) {
        case .answered(let stats):
            byUsername[key] = Cached(value: stats, at: Date())
            if let id = stats?.userId, !id.isEmpty {
                byUserId[id] = Cached(value: stats, at: Date())
            }
            return stats.map(Resolution.found) ?? .missing

        case .unreachable:
            return .unreachable
        }
    }

    enum Resolution: Equatable {
        case found(IFPilotStats)
        case missing
        case unreachable
    }

    /// Forgets one pilot, so the next look is a fresh one. Used after a profile
    /// setup syncs a name — the pilot has just been told what we found, and a
    /// stale block behind that would be the one thing they would notice.
    func forget(ifUsername: String) {
        let key = ifUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        if let id = byUsername[key]?.value?.userId { byUserId.removeValue(forKey: id) }
        byUsername.removeValue(forKey: key)
    }

    // MARK: - Plumbing

    /// One request per key at a time, cached on the way out through `store`.
    private func fetch(
        key: String,
        url: URL?,
        store: @escaping @MainActor (IFPilotStats?) -> Void
    ) async -> IFPilotStats? {
        guard let url = url else { return nil }

        if let running = pending[key] { return await running.value }

        let task = Task<IFPilotStats?, Never> {
            switch await Self.request(url) {
            case .answered(let stats):
                store(stats)
                return stats
            case .unreachable:
                // Not remembered. See `request`.
                return nil
            }
        }
        pending[key] = task
        let answer = await task.value
        pending.removeValue(forKey: key)
        return answer
    }

    /// The difference between "no such pilot" and "we could not ask".
    ///
    /// It is the whole reason this is not an optional. A 404 is an answer and
    /// is worth remembering for ten minutes; a timeout is the absence of one,
    /// and caching it would hide a pilot's grade for ten minutes because a
    /// single request was dropped on a train.
    private enum Answer {
        case answered(IFPilotStats?)
        case unreachable
    }

    /// `{ ok, userId, username, stats: {...} }`, or a 404 for a pilot the Live
    /// API has never heard of.
    private nonisolated static func request(_ url: URL) async -> Answer {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .unreachable
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 is the backend saying it looked and found nobody. Every other
        // refusal — a rate limit, a 500, the Live API being down — is the
        // backend saying it could not look.
        if code == 404 { return .answered(nil) }
        guard (200...299).contains(code) else { return .unreachable }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["stats"] as? [String: Any],
              let payload = try? JSONSerialization.data(withJSONObject: block),
              var stats = try? JSONDecoder().decode(IFPilotStats.self, from: payload) else {
            return .answered(nil)
        }

        // The two identifying fields sit beside the block rather than inside
        // it, because the block is the same shape whichever route answered.
        stats.userId = root["userId"] as? String
        if let name = root["username"] as? String, !name.isEmpty { stats.username = name }
        return .answered(stats.isEmpty ? nil : stats)
    }
}
