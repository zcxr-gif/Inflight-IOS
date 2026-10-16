import Combine
import Foundation

/// Kudos and RateMyATC: thanking a controller, rating a session, and reading
/// what pilots have said about them.
///
/// Every call is a `security definer` function the website uses too
/// (`supabase/migrations/20261015000000_atc_commendations.sql` and
/// `20261016000000_atc_ratings.sql`), so the rules live on the server: one
/// kudos and one rating per pilot per session, sessions older than two days
/// are closed, nobody rates themselves, and a 1–3★ comment is only ever handed
/// to the controller it is about. Nothing here could weaken that if it tried.
///
/// ## What is public
///
/// Stars are public, every one of them. Comments on 4–5★ ratings are public.
/// Comments on 1–3★ ratings are private feedback, read only by the controller
/// through `inbox()`. The rating sheet says so before anything is sent.
@MainActor
final class AtcKudosStore: ObservableObject {

    static let shared = AtcKudosStore()

    enum Kind: String, CaseIterable, Identifiable {
        case thumbsUp = "thumbs_up"
        case goodDay = "good_day"

        var id: String { rawValue }

        var emoji: String { self == .thumbsUp ? "👍" : "☀️" }

        var label: String { self == .thumbsUp ? "Thumbs up" : "Good day" }
    }

    /// What the rows on screen show about one controller, and what the reader
    /// has already given them this session.
    struct Stats: Equatable {
        var kudos = 0
        var thumbsUp = 0
        var goodDay = 0
        var myKind: Kind?
        var myKudosSession: Date?
        var ratingAvg: Double?
        var ratingCount = 0
        var myStars: Int?
        var myRatedSession: Date?
        var at = Date.distantPast
    }

    /// By controller id. Published whole: a row only ever wants its own entry,
    /// and the list is a few dozen controllers at most.
    @Published private(set) var stats: [String: Stats] = [:]

    /// Kudos and private feedback the signed-in controller has not looked at.
    @Published private(set) var unseen = 0

    /// Fresh enough to draw without asking again. Short, because the point of
    /// a kudos count is that it moves while the controller is still on.
    private static let freshFor: TimeInterval = 60

    private static let seenKey = "inflight.atcKudos.seenAt"

    /// Ids asked for by rows as they appear, sent together a moment later so a
    /// panel of thirty controllers is one request rather than thirty.
    private var queued = Set<String>()
    private var flush: Task<Void, Never>?
    private var inFlight = Set<String>()

    private init() {}

    func accountChanged() {
        stats.removeAll()
        unseen = 0
    }

    // MARK: - Counts

    /// A row's way in: queued, and fetched with whatever else appears with it.
    func request(_ id: String) {
        queued.insert(id)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self = self else { return }
            let ids = Array(self.queued)
            self.queued.removeAll()
            self.flush = nil
            await self.ensure(ids)
        }
    }

    /// Fetches counts for any of these controllers not already fresh.
    func ensure(_ ids: [String], force: Bool = false) async {
        let now = Date()
        let wanted = Array(Set(ids.filter { id in
            guard !id.isEmpty, force || !inFlight.contains(id) else { return false }
            guard !force, let hit = stats[id] else { return true }
            return now.timeIntervalSince(hit.at) >= Self.freshFor
        }))
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }

        let token = await AccountStore.shared.currentAccessToken()
        // The server reads at most a hundred ids per call.
        for start in stride(from: 0, to: wanted.count, by: 100) {
            let chunk = Array(wanted[start..<min(start + 100, wanted.count)])
            async let kudos: [CountRow] = SupabaseData.rpc(
                "atc_commendation_counts",
                arguments: ["p_controller_if_ids": chunk],
                accessToken: token
            )
            async let ratings: [RatingCountRow] = SupabaseData.rpc(
                "atc_rating_counts",
                arguments: ["p_controller_if_ids": chunk],
                accessToken: token
            )
            guard let k = try? await kudos else { continue }
            let r = (try? await ratings) ?? []
            let byId = Dictionary(r.map { ($0.controller_if_id, $0) }, uniquingKeysWith: { a, _ in a })

            for id in chunk {
                let row = k.first { $0.controller_if_id == id }
                let rating = byId[id]
                stats[id] = Stats(
                    kudos: row?.total ?? 0,
                    thumbsUp: row?.thumbs_up ?? 0,
                    goodDay: row?.good_day ?? 0,
                    myKind: row?.my_kind.flatMap(Kind.init(rawValue:)),
                    myKudosSession: Self.date(row?.my_session_started_at),
                    ratingAvg: rating?.rating_avg?.value,
                    ratingCount: rating?.rating_count ?? 0,
                    myStars: rating?.my_stars,
                    myRatedSession: Self.date(rating?.my_session_started_at),
                    at: now
                )
            }
        }
    }

    /// The kudos the reader gave this session, if any.
    func myKind(for facility: AtcFacility) -> Kind? {
        guard let id = facility.controllerId, let s = stats[id], let kind = s.myKind else { return nil }
        return Self.sameSecond(s.myKudosSession, facility.openedAt) ? kind : nil
    }

    /// The stars the reader gave this session, if any.
    func myStars(for facility: AtcFacility) -> Int? {
        guard let id = facility.controllerId, let s = stats[id], let stars = s.myStars else { return nil }
        return Self.sameSecond(s.myRatedSession, facility.openedAt) ? stars : nil
    }

    // MARK: - Giving

    /// One tap, no note needed. Pressing the kudos already given takes it back.
    func toggle(_ kind: Kind, for facility: AtcFacility) async throws {
        guard let id = facility.controllerId, let opened = facility.openedAt else { return }
        let token = try await requireToken("give kudos")

        if myKind(for: facility) == kind {
            try await SupabaseData.perform(
                "atc_commendation_withdraw",
                arguments: ["p_controller_if_id": id, "p_session_started_at": Self.iso(opened)],
                accessToken: token
            )
        } else {
            try await SupabaseData.perform(
                "atc_commend",
                arguments: sessionArguments(facility, id: id, opened: opened).merging([
                    "p_kind": kind.rawValue,
                    "p_note": NSNull()
                ]) { _, new in new },
                accessToken: token
            )
        }
        await ensure([id], force: true)
    }

    /// Adds or changes the note on a kudos, sending the kudos if it wasn't yet.
    func commend(_ kind: Kind, note: String, for facility: AtcFacility) async throws {
        guard let id = facility.controllerId, let opened = facility.openedAt else { return }
        let token = try await requireToken("give kudos")
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try await SupabaseData.perform(
            "atc_commend",
            arguments: sessionArguments(facility, id: id, opened: opened).merging([
                "p_kind": kind.rawValue,
                "p_note": Self.orNull(text)
            ]) { _, new in new },
            accessToken: token
        )
        await ensure([id], force: true)
    }

    /// Rates this session. Re-rating the same session replaces the old one.
    func rate(_ stars: Int, comment: String, for facility: AtcFacility) async throws {
        guard let id = facility.controllerId, let opened = facility.openedAt else { return }
        let token = try await requireToken("rate a controller")
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        try await SupabaseData.perform(
            "atc_rate",
            arguments: sessionArguments(facility, id: id, opened: opened).merging([
                "p_stars": stars,
                "p_comment": Self.orNull(text)
            ]) { _, new in new },
            accessToken: token
        )
        await ensure([id], force: true)
    }

    // MARK: - Reading

    func profile(controllerId: String) async -> ControllerProfile? {
        let token = await AccountStore.shared.currentAccessToken()
        async let kudos: [KudosProfile] = SupabaseData.rpc(
            "atc_commendation_profile",
            arguments: ["p_controller_if_id": controllerId, "p_limit": 20],
            accessToken: token
        )
        async let ratings: [RatingProfile] = SupabaseData.rpc(
            "atc_rating_profile",
            arguments: ["p_controller_if_id": controllerId, "p_limit": 10],
            accessToken: token
        )
        guard let k = (try? await kudos)?.first else { return nil }
        return ControllerProfile(kudos: k, ratings: (try? await ratings)?.first)
    }

    /// The RateMyATC board. `days` of 0 is all time.
    func leaderboard(days: Int) async -> Leaderboard? {
        let token = await AccountStore.shared.currentAccessToken()
        let rows: [Leaderboard]? = try? await SupabaseData.rpc(
            "atc_leaderboard",
            arguments: ["p_days": days, "p_limit": 50],
            accessToken: token
        )
        return rows?.first
    }

    /// What the signed-in pilot has received as a controller, matched on the
    /// Infinite Flight name on their profile. Nil signed out.
    func inbox() async -> Inbox? {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            unseen = 0
            return nil
        }
        var arguments: [String: Any] = ["p_limit": 20]
        if let seen = UserDefaults.standard.object(forKey: Self.seenKey) as? Date {
            arguments["p_since"] = Self.iso(seen)
        }
        let rows: [Inbox]? = try? await SupabaseData.rpc("atc_kudos_inbox", arguments: arguments, accessToken: token)
        guard let inbox = rows?.first else { return nil }
        unseen = (inbox.unseen ?? 0) + (inbox.feedback_unseen ?? 0)
        return inbox
    }

    func markInboxSeen() {
        UserDefaults.standard.set(Date(), forKey: Self.seenKey)
        unseen = 0
    }

    // MARK: - Plumbing

    private func requireToken(_ what: String) async throws -> String {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            throw SupabaseData.Failure(message: Lf("Sign in to %@.", L(what)))
        }
        return token
    }

    private func sessionArguments(_ f: AtcFacility, id: String, opened: Date) -> [String: Any] {
        var arguments: [String: Any] = [
            "p_controller_if_id": id,
            "p_controller_username": f.controller,
            "p_airport_icao": NSNull(),
            "p_facility_type": NSNull(),
            "p_session_started_at": Self.iso(opened)
        ]
        if !f.isCenter { arguments["p_airport_icao"] = f.station }
        if f.kind != .unknown { arguments["p_facility_type"] = f.kind.rawValue }
        return arguments
    }

    /// An empty note is no note, which the server wants as SQL null.
    private nonisolated static func orNull(_ text: String) -> Any {
        text.isEmpty ? NSNull() as Any : text as Any
    }

    private nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Postgres writes six fractional digits, which not every formatter takes;
    /// the server truncates sessions to the second anyway, so drop them.
    nonisolated static func date(_ text: String?) -> Date? {
        guard var text = text, !text.isEmpty else { return nil }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return ISO8601DateFormatter().date(from: text.replacingOccurrences(of: " ", with: "T"))
    }

    /// The feed's start time and the stored one take different routes here;
    /// compare them to the second, as the server does.
    private nonisolated static func sameSecond(_ a: Date?, _ b: Date?) -> Bool {
        guard let a = a, let b = b else { return false }
        return floor(a.timeIntervalSince1970) == floor(b.timeIntervalSince1970)
    }
}

// MARK: - Wire types

/// `numeric` arrives as a JSON number, but a proxy or a future PostgREST
/// setting can make it a string. Both read.
struct LenientDouble: Decodable, Equatable {
    let value: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        let s = try c.decode(String.self)
        guard let d = Double(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number")
        }
        value = d
    }
}

extension AtcKudosStore {

    struct CountRow: Decodable {
        let controller_if_id: String
        let total: Int?
        let thumbs_up: Int?
        let good_day: Int?
        let my_session_started_at: String?
        let my_kind: String?
    }

    struct RatingCountRow: Decodable {
        let controller_if_id: String
        let rating_avg: LenientDouble?
        let rating_count: Int?
        let my_session_started_at: String?
        let my_stars: Int?
    }

    /// Who left something public. Empty for a pilot without a public profile,
    /// who is shown as "A pilot".
    struct By: Decodable, Hashable {
        let handle: String?
        let display_name: String?

        var label: String {
            if let name = display_name, !name.isEmpty { return name }
            if let handle = handle, !handle.isEmpty { return "@\(handle)" }
            return "A pilot"
        }
    }

    struct KudosEntry: Decodable, Hashable {
        let airport_icao: String?
        let facility_type: Int?
        let kind: String?
        let note: String?
        let created_at: String?
        let by: By?

        var kudosKind: Kind? { kind.flatMap(Kind.init(rawValue:)) }
        var date: Date? { AtcKudosStore.date(created_at) }
    }

    struct KudosProfile: Decodable {
        let controller_if_id: String?
        let total: Int?
        let thumbs_up: Int?
        let good_day: Int?
        let sessions: Int?
        let airports: [AirportCount]?
        let recent: [KudosEntry]?

        struct AirportCount: Decodable, Hashable {
            let icao: String?
            let count: Int?
        }
    }

    struct RatingComment: Decodable, Hashable {
        let stars: Int?
        let comment: String?
        let airport_icao: String?
        let facility_type: Int?
        let created_at: String?
        let by: By?

        var date: Date? { AtcKudosStore.date(created_at) }
    }

    struct RatingProfile: Decodable {
        let avg: LenientDouble?
        let count: Int?
        let dist: [String: Int]?
        let comments: [RatingComment]?
    }

    struct ControllerProfile {
        let kudos: KudosProfile
        let ratings: RatingProfile?
    }

    struct BoardRow: Decodable, Identifiable, Hashable {
        let controller_if_id: String
        let username: String?
        let last_airport: String?
        let last_at: String?
        let rating_avg: LenientDouble?
        let rating_count: Int?
        let kudos: Int?
        let thumbs_up: Int?
        let good_day: Int?

        var id: String { controller_if_id }

        static func == (a: BoardRow, b: BoardRow) -> Bool { a.controller_if_id == b.controller_if_id }
        func hash(into hasher: inout Hasher) { hasher.combine(controller_if_id) }
    }

    struct Leaderboard: Decodable {
        let days: Int?
        let board_avg: LenientDouble?
        let controllers: Int?
        let ratings: Int?
        let kudos: Int?
        let top_rated: [BoardRow]?
        let most_kudos: [BoardRow]?
        let most_rated: [BoardRow]?
    }

    struct Inbox: Decodable {
        let linked: Bool?
        let owner: Bool?
        let username: String?
        let controller_if_id: String?
        let total: Int?
        let unseen: Int?
        let recent: [KudosEntry]?
        let rating_avg: LenientDouble?
        let rating_count: Int?
        let feedback_unseen: Int?
        let feedback: [RatingComment]?
    }
}
