import Combine
import Foundation

/// Everybody else.
///
/// One object for reading profiles that are not yours and for the three things
/// you can do about them — follow, block, report. Every read goes through a
/// `security definer` function on the server rather than through a table:
/// "which of these may this reader see" depends on the profile's own settings,
/// on who has blocked whom, and on how many people have reported it, and none
/// of that belongs in a client that a determined reader can edit.
///
/// ## Why this caches
///
/// A profile is opened from a tapped aeroplane, and the traffic on a busy
/// server changes every few seconds. Without a cache, panning the map past the
/// same pilot twice is two round trips for a picture that has not changed, and
/// a friends list of forty is forty rows of avatar that each want their own.
/// The cache is deliberately short — a follow count is meant to move — and is
/// dropped wholesale when the account changes, because every card carries
/// "does the reader follow this pilot" and that answer is about the reader.
@MainActor
final class PilotDirectory: ObservableObject {

    static let shared = PilotDirectory()

    /// How long a fetched card is reused. Long enough to survive a sheet being
    /// dismissed and reopened, short enough that a follow made on another
    /// device shows up without the app being restarted.
    private static let cacheLifetime: TimeInterval = 90

    private struct Cached<Value> {
        let value: Value
        let at: Date

        var isFresh: Bool { Date().timeIntervalSince(at) < PilotDirectory.cacheLifetime }
    }

    private var cards: [String: Cached<PilotProfile>] = [:]

    /// Profiles resolved from a name on the map, including the misses.
    ///
    /// A miss is cached too, and that is the important half: most pilots on the
    /// server have never claimed a handle here, so most lookups find nothing,
    /// and without remembering that the app would ask again every time the same
    /// aeroplane was tapped.
    private var byIfUsername: [String: Cached<String?>] = [:]

    private init() {}

    /// Dropped when somebody signs in or out. Every card carries the reader's
    /// own relationship to the pilot, so a cache built for one account is
    /// wrong for the next one — and quietly wrong, which is worse.
    func accountChanged() {
        cards.removeAll()
        byIfUsername.removeAll()
    }

    // MARK: - Reading

    func card(handle: String, refresh: Bool = false) async -> PilotProfile? {
        let key = handle.lowercased()
        if !refresh, let cached = cards[key], cached.isFresh { return cached.value }

        let token = await AccountStore.shared.currentAccessToken()
        do {
            let rows: [PilotProfile] = try await SupabaseData.rpc(
                "pilot_profile_card",
                arguments: ["p_handle": key],
                accessToken: token
            )
            guard let card = rows.first else { return nil }
            cards[key] = Cached(value: card, at: Date())
            return card
        } catch {
            // The last known card, if there is one. A profile is not a thing to
            // make disappear because a request timed out.
            return cards[key]?.value
        }
    }

    /// The profile behind a name on the map, if that pilot has claimed one.
    ///
    /// This is the join that makes the whole feature worth having: the live
    /// feed names an aircraft's pilot and knows nothing about Inflight
    /// accounts, so without this a tapped aeroplane is a string. Nothing is
    /// verified — anybody can claim any Infinite Flight name — so everything
    /// that shows the result says so.
    func card(ifUsername: String) async -> PilotProfile? {
        let key = ifUsername.lowercased()
        guard !key.isEmpty else { return nil }

        if let cached = byIfUsername[key], cached.isFresh {
            guard let handle = cached.value else { return nil }
            return await card(handle: handle)
        }

        let token = await AccountStore.shared.currentAccessToken()
        do {
            let rows: [PilotProfile] = try await SupabaseData.rpc(
                "pilot_profile_by_if_username",
                arguments: ["p_username": key],
                accessToken: token
            )
            byIfUsername[key] = Cached(value: rows.first?.handle, at: Date())
            if let card = rows.first {
                cards[card.handle] = Cached(value: card, at: Date())
            }
            return rows.first
        } catch {
            return nil
        }
    }

    func friends(of handle: String, limit: Int = 60) async -> [PilotSummary] {
        await list("pilot_profile_friends", arguments: [
            "p_handle": handle.lowercased(), "p_limit": limit
        ])
    }

    func connections(
        of handle: String,
        direction: Direction,
        limit: Int = 60,
        offset: Int = 0
    ) async -> [PilotSummary] {
        await list("pilot_profile_connections", arguments: [
            "p_handle": handle.lowercased(),
            "p_direction": direction.rawValue,
            "p_limit": limit,
            "p_offset": offset
        ])
    }

    enum Direction: String {
        case followers
        case following
    }

    func search(_ query: String, limit: Int = 25) async -> [PilotSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        return await list("pilot_directory_search", arguments: [
            "p_query": trimmed, "p_limit": limit
        ])
    }

    func blocked() async -> [PilotSummary] {
        guard let token = await AccountStore.shared.currentAccessToken() else { return [] }
        return (try? await SupabaseData.rpc("pilot_blocked_list", accessToken: token)) ?? []
    }

    // MARK: - The logbook on somebody's profile

    func logbook(of handle: String, limit: Int = 50, offset: Int = 0) async -> [LogbookEntry] {
        let token = await AccountStore.shared.currentAccessToken()
        return (try? await SupabaseData.rpc(
            "pilot_logbook_entries",
            arguments: [
                "p_handle": handle.lowercased(), "p_limit": limit, "p_offset": offset
            ],
            accessToken: token
        )) ?? []
    }

    func logbookSummary(of handle: String) async -> LogbookSummary? {
        let token = await AccountStore.shared.currentAccessToken()
        let rows: [LogbookSummary]? = try? await SupabaseData.rpc(
            "pilot_logbook_summary",
            arguments: ["p_handle": handle.lowercased()],
            accessToken: token
        )
        return rows?.first
    }

    /// What one pilot's simulator is reporting right now.
    ///
    /// Empty for every reason at once, and deliberately so: not flying, not
    /// broadcasting, not visible to you, or stale. Distinguishing them would
    /// turn this into a way to find out who has hidden what from whom.
    func liveStatus(of handle: String) async -> PilotLiveStatus? {
        let token = await AccountStore.shared.currentAccessToken()
        let rows: [PilotLiveStatus]? = try? await SupabaseData.rpc(
            "pilot_live_status_for",
            arguments: ["p_handle": handle],
            accessToken: token
        )
        return rows?.first
    }

    /// Everybody you follow who is in the air.
    ///
    /// The reason the whole live-status feature is worth having: a friends list
    /// that says who is flying, where, and what they are doing.
    func liveFollowing(limit: Int = 50) async -> [PilotLiveSummary] {
        guard let token = await AccountStore.shared.currentAccessToken() else { return [] }
        return (try? await SupabaseData.rpc(
            "pilot_live_following",
            arguments: ["p_limit": limit],
            accessToken: token
        )) ?? []
    }

    /// The landing board for the people this account follows.
    ///
    /// Computed on the server from the logbook every time it is asked for. That
    /// is deliberate and costs nothing worth saving: the alternative is a stored
    /// leaderboard, which is a table to maintain, a backfill when the rule
    /// changes, and a number that can be wrong.
    func landingBoard(windowDays: Int = 30, limit: Int = 25) async -> [PilotLandingBoardEntry] {
        guard let token = await AccountStore.shared.currentAccessToken() else { return [] }
        return (try? await SupabaseData.rpc(
            "pilot_landing_board",
            arguments: ["p_window_days": windowDays, "p_limit": limit],
            accessToken: token
        )) ?? []
    }

    func badges(of handle: String) async -> [PilotBadge] {
        let token = await AccountStore.shared.currentAccessToken()
        return (try? await SupabaseData.rpc(
            "pilot_badges",
            arguments: ["p_handle": handle.lowercased()],
            accessToken: token
        )) ?? []
    }

    // MARK: - Doing something about somebody

    /// Follows or unfollows, and hands back the card as it now stands.
    ///
    /// The card is re-read rather than patched locally, because following
    /// somebody who already follows you makes you friends — which changes the
    /// button, the friend count, and whether you appear on each other's public
    /// lists. Working that out on the device would be a second copy of a rule
    /// the server already applies.
    @discardableResult
    func setFollowing(_ following: Bool, handle: String) async throws -> PilotProfile? {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            throw SupabaseData.Failure(message: "Sign in to follow a pilot.")
        }

        try await SupabaseData.perform(
            following ? "pilot_follow" : "pilot_unfollow",
            arguments: ["p_handle": handle.lowercased()],
            accessToken: token
        )

        cards[handle.lowercased()] = nil
        return await card(handle: handle, refresh: true)
    }

    /// Blocks or unblocks. Silent to the other person by design: being told you
    /// have been blocked is an invitation to make another account.
    func setBlocked(_ blocked: Bool, handle: String) async throws {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            throw SupabaseData.Failure(message: "Sign in first.")
        }

        try await SupabaseData.perform(
            "pilot_block",
            arguments: ["p_handle": handle.lowercased(), "p_blocked": blocked],
            accessToken: token
        )

        // Blocking severs the follow both ways on the server, so everything
        // cached about this pilot — and about anybody whose friends list they
        // were on — is now wrong.
        accountChanged()
    }

    /// Why a profile is being reported. The same seven the server accepts, and
    /// in the order somebody scanning a list would find theirs.
    enum ReportReason: String, CaseIterable, Identifiable {
        case sexual
        case hate
        case harassment
        case impersonation
        case spam
        case violence
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sexual: return "Sexual or adult content"
            case .hate: return "Hate speech"
            case .harassment: return "Harassment or bullying"
            case .impersonation: return "Pretending to be someone else"
            case .spam: return "Spam or advertising"
            case .violence: return "Violence or threats"
            case .other: return "Something else"
            }
        }
    }

    func report(handle: String, reason: ReportReason, detail: String?) async throws {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            throw SupabaseData.Failure(message: "Sign in to report a profile.")
        }

        var arguments: [String: Any] = [
            "p_handle": handle.lowercased(),
            "p_reason": reason.rawValue
        ]
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            arguments["p_detail"] = detail
        }

        try await SupabaseData.perform("pilot_report", arguments: arguments, accessToken: token)
    }

    // MARK: - Plumbing

    private func list(
        _ function: String,
        arguments: [String: Any]
    ) async -> [PilotSummary] {
        let token = await AccountStore.shared.currentAccessToken()
        return (try? await SupabaseData.rpc(
            function,
            arguments: arguments,
            accessToken: token
        )) ?? []
    }
}
