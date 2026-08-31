import Combine
import Foundation

/// Keeps one account's settings the same on every device it signs into.
///
/// One row in `public.pilot_settings`, one blob, read on the way in and
/// written a few seconds after anything changes. The server never looks inside
/// it — see the migration for why it is a blob rather than forty columns.
///
/// ## Which side wins
///
/// **The account, on the way in.** Signing in adopts what the account holds,
/// whatever this device had. That is the whole feature: a new phone should come
/// up looking like the old one, and an install that had been used signed out
/// for a week is exactly the case where "the device wins" would quietly
/// overwrite a year of choices with a fortnight of them.
///
/// The one exception is an account with nothing saved yet — a first sign-in
/// ever, or the first launch after this shipped. Then there is nothing to adopt
/// and this device *seeds* the row, so somebody who has been using the app
/// signed out and finally makes an account keeps everything they had set up.
///
/// **The most recent write, thereafter.** Two devices in use at once is a real
/// case and there is no merge that would be right for it: the settings are not
/// a set of independent facts, they are one person's idea of how the app should
/// look, and half of one and half of the other is a state neither of them
/// asked for. So the last device to change something wins, and the others take
/// it the next time they are opened. `updated_at` is the server's clock — see
/// the guard trigger — because a client that could set that could set it
/// backwards and win every race.
///
/// ## What signing out does
///
/// Nothing. The settings on this device stay exactly as they are, because they
/// are also this device's settings and taking them away would be punishing
/// somebody for signing out. Nothing more is written until they sign in again.
@MainActor
final class AccountSync: ObservableObject {

    static let shared = AccountSync()

    /// Where the sync has got to, for the account panel's row to say so.
    enum State: Equatable {
        /// Signed out. Nothing is being carried.
        case off

        case reading
        case writing

        /// Last agreed with the server at this moment on the device's clock.
        /// Only ever shown, never compared against anything.
        case synced(Date)

        /// In the server's words. Cleared by the next attempt that works.
        case failed(String)
    }

    @Published private(set) var state: State = .off

    private static let table = "pilot_settings"

    /// Which shape of blob this build writes. Nothing reads it yet; it is
    /// stored so a future build that changes what a key means can tell its own
    /// writes from an older app's without inferring it from the contents.
    private static let revision = 1

    /// How long after a change the push goes out.
    ///
    /// Long enough that dragging a colour picker or working down the filters is
    /// one write rather than thirty, short enough that closing the app straight
    /// after changing something still catches it. Every change restarts it.
    private static let quietPeriod: Duration = .seconds(4)

    /// The server's `updated_at` for the blob this device has agreed with.
    ///
    /// The whole of the conflict resolution. A pull applies the row only when
    /// this is older than what came back, which is what stops a device
    /// re-applying its own write and stops a foreground refresh undoing an
    /// edit made thirty seconds ago on this phone.
    private var agreedStamp: Date?

    /// The last snapshot actually sent. An identical capture is not sent again
    /// — which matters more than it sounds, because several of the observed
    /// stores publish on things that are not settings at all: the appearance
    /// store republishes whenever iOS changes light or dark, and the hints
    /// store on every strip that appears.
    private var lastPushed: SyncedSettings?

    /// True while `apply` is running, so the changes it makes to seven stores
    /// do not come straight back through the observers as a push.
    private var isApplying = false

    /// Set the moment something changes and cleared only by a write that
    /// landed. Kept on disk, which is the point of it.
    ///
    /// Without this there is a way to lose a change, and it is not a rare one:
    /// somebody picks a colour, swipes the app away two seconds later, and the
    /// quiet period never elapses. `flush()` on the way to the background is
    /// the first defence and iOS is free to suspend the process before the
    /// request finishes. The next launch would then pull the account's older
    /// blob and apply it straight over the change — which is not "the account
    /// wins", it is the change never having existed.
    ///
    /// So a device carrying something the account has never seen pushes it
    /// rather than adopting. That is not a second conflict policy: the account
    /// still wins every case where both sides have a saved answer. This is the
    /// case where only one of them does.
    private var hasUnsentChange: Bool {
        get { UserDefaults.standard.bool(forKey: Self.unsentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.unsentKey) }
    }

    private static let unsentKey = "accountSync.unsentChange"

    private var observers: Set<AnyCancellable> = []
    private var pushTask: Task<Void, Never>?

    private init() {}

    // MARK: - The account's lifecycle

    /// A session has been adopted. Take what the account holds, then start
    /// watching for changes.
    func signedIn() async {
        await pull(isFirstRead: true)
        startObserving()
    }

    /// Signed out, or the account deleted. Stop writing; leave the device
    /// exactly as it is.
    func signedOut() {
        pushTask?.cancel()
        pushTask = nil
        observers.removeAll()
        agreedStamp = nil
        lastPushed = nil
        // Belongs to the account that just left. Carrying it would have the
        // next person to sign in on this phone push these settings up as if
        // they were theirs.
        hasUnsentChange = false
        state = .off
    }

    /// The app has come back to the foreground, where another device may have
    /// changed something while this one was away. Cheap and quiet: one row, and
    /// nothing is applied unless it is genuinely newer.
    func refresh() async {
        guard AccountStore.shared.isSignedIn else { return }
        // A change made seconds before the app went away is still sitting out
        // its quiet period. Send it before reading, or the read lands on top
        // of it.
        if pushTask != nil { await flush() }
        await pull(isFirstRead: false)
    }

    /// Sends anything outstanding right now rather than waiting out the quiet
    /// period — for the app going to the background, which is where a debounce
    /// otherwise loses the last change somebody made.
    func flush() async {
        guard !observers.isEmpty else { return }
        pushTask?.cancel()
        pushTask = nil
        await push()
    }

    // MARK: - Reading

    private func pull(isFirstRead: Bool) async {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            state = .off
            return
        }

        state = .reading

        do {
            let rows: [Row] = try await SupabaseData.select(
                table: Self.table,
                columns: "settings,updated_at",
                filters: [:],
                limit: 1,
                accessToken: token
            )

            guard let row = rows.first else {
                // Nothing saved against this account yet. What is on this
                // device becomes what the account holds — see the note above on
                // seeding.
                await push(force: true)
                return
            }

            // This device is carrying something that never reached the server.
            // See `hasUnsentChange`.
            if hasUnsentChange {
                await push(force: true)
                return
            }

            // Ours, or one we have already taken. Either way there is nothing
            // to apply, and applying it anyway would undo an edit made on this
            // device since.
            if let stamp = row.updatedAt, let agreed = agreedStamp, stamp <= agreed, !isFirstRead {
                state = .synced(Date())
                return
            }

            isApplying = true
            row.settings.apply()
            isApplying = false

            agreedStamp = row.updatedAt
            // What is now on the device is what the server holds, so the next
            // capture has nothing to send — and nothing is outstanding.
            lastPushed = SyncedSettings.capture()
            hasUnsentChange = false
            state = .synced(Date())
        } catch let failure as SupabaseData.Failure {
            isApplying = false
            state = .failed(failure.message)
        } catch {
            isApplying = false
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Writing

    /// Captures the device and sends it, unless it would be the same blob
    /// again.
    ///
    /// `force` is the seeding case, where there is no row on the server and
    /// "the same as last time" is true only because last time was this launch.
    private func push(force: Bool = false) async {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            state = .off
            return
        }

        let settings = SyncedSettings.capture()
        guard force || settings != lastPushed else { return }

        state = .writing

        do {
            let blob = try settings.jsonObject()
            let data = try await SupabaseData.upsert(
                table: Self.table,
                row: ["settings": blob, "revision": Self.revision],
                accessToken: token,
                onConflict: "user_id"
            )

            lastPushed = settings
            hasUnsentChange = false
            // The row that came back carries the server's own clock, which is
            // what the next pull compares against. Without taking it here, the
            // next foreground refresh would see a row newer than anything this
            // device has agreed with — its own — and apply it back over itself.
            if let echoed = Self.decode(data)?.updatedAt {
                agreedStamp = echoed
            }
            state = .synced(Date())
        } catch let failure as SupabaseData.Failure {
            state = .failed(failure.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Noticing a change

    /// Subscribes to every store whose contents travel.
    ///
    /// `objectWillChange` rather than a call from each store's `didSet`, and
    /// that is deliberate: a `markDirty()` sprinkled through forty property
    /// observers is forty chances to add the forty-first and forget. This way
    /// a new setting on an already-watched store is carried the moment it is
    /// added to `SyncedSettings`, and there is one place that knows a sync
    /// exists.
    ///
    /// The cost is that these publishers fire for things that are not settings
    /// — `FlightInfoAppearance` republishes when iOS turns dark, `HintsStore`
    /// when a strip retires a line — which is what the equality check in
    /// `push` is for. A spurious wake costs a capture and a comparison, not a
    /// request.
    private func startObserving() {
        observers.removeAll()

        // Listed as the concrete publishers rather than as `any
        // ObservableObject`: every one of these classes takes the synthesized
        // `ObservableObjectPublisher`, and reaching for `objectWillChange`
        // through an existential means going through an associated type for no
        // benefit.
        let publishers: [ObservableObjectPublisher] = [
            FriendsStore.shared.objectWillChange,
            PilotHighlightPreferences.shared.objectWillChange,
            FlightInfoAppearance.shared.objectWillChange,
            MapFilters.shared.objectWillChange,
            WeatherPreferences.shared.objectWillChange,
            InstrumentPreferences.shared.objectWillChange,
            HintsStore.shared.objectWillChange
        ]

        for publisher in publishers {
            publisher
                .sink { [weak self] _ in
                    // The publisher fires *before* the value lands, so the
                    // capture has to happen after this turn of the run loop —
                    // which the quiet period already guarantees.
                    self?.schedulePush()
                }
                .store(in: &observers)
        }
    }

    private func schedulePush() {
        guard !isApplying else { return }

        hasUnsentChange = true

        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    // MARK: - The row

    private struct Row: Decodable {
        let settings: SyncedSettings
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case settings
            case updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A blob this build cannot read at all is an empty one rather than
            // a thrown error: the settings are the least important thing in the
            // app to get back, and failing the whole sign-in over one
            // unreadable key would be the wrong trade by a distance.
            settings = (try? c.decode(SyncedSettings.self, forKey: .settings)) ?? SyncedSettings()
            // Postgres stamps carry a variable number of fractional digits,
            // which `.iso8601` alone refuses. `SupabaseAuth.Timestamp` already
            // knows that; a second answer here could drift from it.
            updatedAt = SupabaseAuth.Timestamp.date(
                from: (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
            )
        }
    }

    /// The single row PostgREST echoes back from a write.
    private static func decode(_ data: Data) -> Row? {
        (try? JSONDecoder().decode([Row].self, from: data))?.first
    }
}
