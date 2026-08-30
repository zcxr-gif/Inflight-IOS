import Combine
import Foundation

/// The pilot's own planned flights.
///
/// One row per plan in `public.pilot_flight_plans`, read and written with the
/// account's own token. Row-level security says "yours and no other", which is
/// a rule a policy states completely, so this reads the table directly rather
/// than through a function — see `SupabaseData.select` for where that line is
/// drawn.
///
/// ## Why it needs an account
///
/// Every other store in this app works signed out, because everything else it
/// shows belongs to the world: the traffic, the fields, the weather, somebody
/// else's public profile. A plan belongs to a person, has to survive a new
/// phone, and is worth nothing if it lives only in this install's
/// `UserDefaults` — so this one asks for a sign-in, and says so plainly rather
/// than presenting an empty list that quietly loses what is typed into it.
///
/// ## Where Pro is, and is not
///
/// It is not here. Free accounts and Pro accounts write identical rows through
/// identical calls, and the server has no opinion about which wrote one. What
/// Pro buys is the *airport map* — `GateMapPicker`, where the stands are drawn
/// on the satellite image and you tap the one you want — and a free account
/// reaches the same row by typing the gate. Putting a gate on this store would
/// be a gate on typing a string, which is not a product.
@MainActor
final class FlightPlanBook: ObservableObject {

    static let shared = FlightPlanBook()

    /// Newest intention first: what is coming up soonest, then the plans with
    /// no date on them. Sorted by the server, kept in that order here.
    @Published private(set) var plans: [PlannedFlight] = []

    /// Set while the first read is in the air, so the panel shows a spinner
    /// rather than flashing "no plans yet" at somebody who has a dozen.
    @Published private(set) var isLoading = false

    @Published private(set) var isSaving = false

    /// Why the last read or write failed, in the server's own words where it
    /// had any. Cleared by the next attempt.
    @Published var problem: String?

    @Published var notice: String?

    /// Whether the account has ever been asked. Distinguishes "nobody has
    /// plans" from "nobody has looked yet", which read very differently.
    @Published private(set) var hasAnswered = false

    private init() {}

    var isSignedIn: Bool { AccountStore.shared.isSignedIn }

    /// The plans still ahead of the pilot, soonest first.
    ///
    /// A plan with no time on it counts as upcoming — it is something somebody
    /// means to fly, and hiding it because they have not decided when would be
    /// the app deciding for them. What drops out is a plan whose scheduled
    /// departure has passed by more than a day, which is history whether or not
    /// anybody marked it flown.
    var upcoming: [PlannedFlight] {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        return plans.filter { plan in
            guard plan.status == .planned else { return false }
            guard let out = plan.scheduledOut else { return true }
            return out > cutoff
        }
    }

    /// The next flight, as a row with one line has to mean it: the soonest
    /// plan that actually has a time on it.
    ///
    /// Not `upcoming.last`, which is the trap the list's own order sets. The
    /// list is newest intention first — furthest-out date at the top — and the
    /// undated plans sort below every dated one, so the last element of it is
    /// "a plan with no date" far more often than it is "the next flight".
    var next: PlannedFlight? {
        let dated = upcoming.filter { $0.scheduledOut != nil }
        if let soonest = dated.last { return soonest }
        // Nothing scheduled: the most recently touched plan is the one they
        // are thinking about, which is the best answer available.
        return upcoming.first
    }

    /// Everything `upcoming` leaves out: flown, cancelled, and the plans whose
    /// day has been and gone.
    var past: [PlannedFlight] {
        let upcomingIDs = Set(upcoming.map(\.id))
        return plans.filter { !upcomingIDs.contains($0.id) }
    }

    /// How long after its scheduled departure a plan stops being upcoming.
    ///
    /// A day rather than the moment the clock passes it: somebody who plans an
    /// 18:00 departure and pushes back at 18:40 should not watch their own plan
    /// disappear off the top of the list while they are taxiing.
    private static let staleAfter: TimeInterval = 24 * 3600

    // MARK: - Reading

    /// Re-reads the whole list.
    ///
    /// The whole list rather than a page: this is capped at 200 rows server
    /// side, they are small, and paging a list somebody scrolls once would be
    /// complexity bought with nothing.
    func load() async {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            plans = []
            hasAnswered = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let rows: [PlannedFlight] = try await SupabaseData.select(
                table: "pilot_flight_plans",
                filters: [:],
                // Matches the index the table carries, so the server sorts this
                // rather than reading every row to do it.
                order: "scheduled_out.desc.nullslast,created_at.desc",
                limit: 200,
                accessToken: token
            )
            plans = rows
            problem = nil
        } catch let failure as SupabaseData.Failure {
            problem = failure.message
        } catch {
            problem = error.localizedDescription
        }

        hasAnswered = true
    }

    /// Reads the list once, and not again.
    ///
    /// Safe to call on every appearance of the panel: a list already read stays
    /// read, and `load()` is there for a deliberate refresh.
    func loadIfNeeded() async {
        guard !hasAnswered, !isLoading else { return }
        await load()
    }

    // MARK: - Writing

    /// Files a new plan, or amends one that is already there.
    ///
    /// Returns whether it landed, so the editor knows whether to close. It
    /// deliberately does not close itself on a failure: what somebody typed is
    /// still on screen, and dismissing the sheet would throw it away to show
    /// them an error about it.
    @discardableResult
    func save(_ plan: PlannedFlight) async -> Bool {
        guard plan.isComplete else {
            problem = "A plan needs an airport at both ends."
            return false
        }

        guard let token = await AccountStore.shared.currentAccessToken() else {
            problem = "Sign in to keep your flight plans."
            return false
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let data: Data
            if plan.isSaved {
                data = try await SupabaseData.patch(
                    table: "pilot_flight_plans",
                    filters: ["id": "eq.\(plan.id)"],
                    row: plan.row,
                    accessToken: token
                )
            } else {
                data = try await SupabaseData.insert(
                    table: "pilot_flight_plans",
                    row: plan.row,
                    accessToken: token
                )
            }

            // The row that comes back is the row the *server* holds — trimmed,
            // upper-cased, with its id and its timestamps filled in. Merging
            // that rather than what was sent is what stops the list showing
            // `egll` for the second between saving and the next read.
            if let saved = Self.decode(data) {
                merge(saved)
            } else {
                // A write that succeeded but answered with something
                // unreadable is still a write. Re-reading is cheap and is the
                // only way back to a list that matches the table.
                await load()
            }

            problem = nil
            notice = plan.isSaved ? "Plan updated." : "Plan filed."
            return true
        } catch let failure as SupabaseData.Failure {
            problem = failure.message
            return false
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Marks a plan flown or cancelled without opening the editor.
    @discardableResult
    func setStatus(_ status: PlannedFlight.Status, on plan: PlannedFlight) async -> Bool {
        var amended = plan
        amended.status = status
        return await save(amended)
    }

    @discardableResult
    func delete(_ plan: PlannedFlight) async -> Bool {
        guard plan.isSaved else {
            // Never saved, so there is nothing on the server to remove and the
            // caller is simply throwing away a draft.
            return true
        }

        guard let token = await AccountStore.shared.currentAccessToken() else {
            problem = "Sign in to change your flight plans."
            return false
        }

        // Taken out of the list first. A delete that reaches the server and
        // then leaves the row on screen until a refresh reads as a delete that
        // did not work, and people tap it again.
        let previous = plans
        plans.removeAll { $0.id == plan.id }

        do {
            try await SupabaseData.delete(
                table: "pilot_flight_plans",
                filters: ["id": "eq.\(plan.id)"],
                accessToken: token
            )
            problem = nil
            notice = "Plan deleted."
            return true
        } catch let failure as SupabaseData.Failure {
            plans = previous
            problem = failure.message
            return false
        } catch {
            plans = previous
            problem = error.localizedDescription
            return false
        }
    }

    /// Forgets everything, for a sign-out.
    ///
    /// Called rather than left to expire, because the next account to sign in
    /// on this device must not see the last one's plans for the second before
    /// the first read lands.
    func clear() {
        plans = []
        hasAnswered = false
        problem = nil
        notice = nil
    }

    // MARK: - Plumbing

    /// Puts a saved row into the list, in the right place.
    private func merge(_ plan: PlannedFlight) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        } else {
            plans.append(plan)
        }
        plans.sort(by: Self.newestIntentionFirst)
    }

    /// The order the server returns them in, applied locally so a row saved
    /// between reads lands where it belongs rather than at the bottom.
    private static func newestIntentionFirst(_ lhs: PlannedFlight, _ rhs: PlannedFlight) -> Bool {
        switch (lhs.scheduledOut, rhs.scheduledOut) {
        case let (.some(left), .some(right)):
            if left != right { return left > right }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }

    /// PostgREST answers a write with an array of the rows it wrote.
    private static func decode(_ data: Data) -> PlannedFlight? {
        guard !data.isEmpty else { return nil }
        if let rows = try? JSONDecoder().decode([PlannedFlight].self, from: data) {
            return rows.first
        }
        return try? JSONDecoder().decode(PlannedFlight.self, from: data)
    }
}
