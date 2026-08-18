import Combine
import Foundation

/// Which pilots the user wants to hear about, and which events they want.
///
/// The list lives on the device. There is no sign-in anywhere in this app, and
/// inventing an account system to hold a dozen usernames would be a bigger
/// feature than the one being asked for — so the APNs device token is the
/// identity the backend files these under. That has a real consequence worth
/// being honest about: the list doesn't follow you to a new phone. It is
/// written into the app group so a reinstall over the top keeps it, and the
/// backend can hand it back if the token survives, but a genuinely new device
/// starts empty.
///
/// Stored in the shared container rather than standard defaults because the
/// widgets read the friend count from the same snapshot.
final class FriendsStore: ObservableObject {

    static let shared = FriendsStore()

    /// Lowercased usernames, in the order they were added.
    @Published private(set) var friends: [String] = []

    @Published var preferences: NotificationPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persist()
            syncToBackend()
        }
    }

    /// What the backend says it can do. Nil until the probe answers.
    @Published private(set) var capabilities: Capabilities?

    private static let friendsKey = "friends.usernames"
    private static let preferencesKey = "friends.preferences"

    private let defaults: UserDefaults

    private init() {
        // Falls back to standard defaults when the app group isn't provisioned
        // — the friends list still works, the widgets just can't see it.
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard

        friends = defaults.stringArray(forKey: Self.friendsKey) ?? []
        if let data = defaults.data(forKey: Self.preferencesKey),
           let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    // MARK: - Membership

    var count: Int { friends.count }

    func contains(_ username: String) -> Bool {
        friends.contains(normalize(username))
    }

    /// What happened when a name was offered to the list.
    ///
    /// An enum rather than a `Bool`, because the three ways this can decline
    /// need three different sentences and the caller cannot work out which one
    /// applies by re-deriving the checks — the moment it tries, the free limit
    /// is being enforced in two places that can disagree.
    enum AddOutcome: Equatable {
        case added

        /// Already watched. Not an error, and the panel says so gently.
        case alreadyWatching

        /// Not a display name — a pasted URL, an email, something with spaces.
        case unusableName

        /// The free list is full. Carries the limit so the copy and the gate
        /// cannot drift.
        case needsPro(limit: Int)
    }

    /// Adds a pilot to the watchlist, if this account may have another.
    ///
    /// THE FREE LIMIT IS ENFORCED HERE, not in the panel that calls it. It used
    /// to be checked in `FriendsPanel.commit` and again in `FlightWatchRow`,
    /// which worked exactly as long as those stayed the only two ways to watch
    /// somebody — and this app already has a URL scheme, widgets and a
    /// notification tap that reach the same store. A gate on the mutation is a
    /// gate on every caller, including the ones that do not exist yet.
    ///
    /// The cap is on *adding*, never on what is already there: an account that
    /// watched a dozen pilots before the limit existed keeps all twelve and
    /// only meets the limit when it tries for a thirteenth.
    @discardableResult
    func add(_ username: String) -> AddOutcome {
        let name = normalize(username)
        guard !name.isEmpty, name.count <= 64 else { return .unusableName }
        guard !friends.contains(name) else { return .alreadyWatching }

        guard Entitlements.shared.canWatchMore(current: friends.count) else {
            return .needsPro(limit: ProFeature.freeWatchlistLimit)
        }

        friends.append(name)
        persist()
        syncToBackend()
        return .added
    }

    func remove(_ username: String) {
        let name = normalize(username)
        guard let index = friends.firstIndex(of: name) else { return }
        friends.remove(at: index)
        persist()
        syncToBackend()
    }

    /// Returns what the add did, so a caller that toggles can still explain a
    /// refusal. Removing always succeeds.
    @discardableResult
    func toggle(_ username: String) -> AddOutcome? {
        if contains(username) {
            remove(username)
            return nil
        }
        return add(username)
    }

    private func normalize(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persist() {
        defaults.set(friends, forKey: Self.friendsKey)
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
    }

    // MARK: - Backend sync

    /// Pushes the whole list every time rather than diffing it.
    ///
    /// The endpoint replaces the device's subscription wholesale, which makes
    /// this idempotent and self-healing: a sync that failed while the phone
    /// was on a plane is fixed by the next one, with no reconciliation to get
    /// wrong. Called on every change and on every launch.
    func syncToBackend() {
        guard let deviceToken = PushService.shared.deviceToken,
              let url = AppConfig.pushSubscriptionsURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "deviceToken": deviceToken,
            "usernames": friends,
            "events": preferences.wireFormat
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                // Nothing to retry here on purpose: the next add, removal or
                // launch re-sends the whole list.
                print("[friends] Subscription sync failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                print("[friends] Subscription sync rejected: HTTP \(http.statusCode)")
            }
        }
        .resume()
    }

    /// Asks the backend what it supports. Failure leaves `capabilities` nil,
    /// which the UI reads as "assume it works" — a probe that can't reach the
    /// server tells us nothing about the server.
    func refreshCapabilities() {
        guard let url = AppConfig.watchlistCapabilitiesURL else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let decoded = try? JSONDecoder().decode(Capabilities.self, from: data) else { return }
            DispatchQueue.main.async { self?.capabilities = decoded }
        }
        .resume()
    }

    // MARK: - Types

    struct Capabilities: Codable, Equatable {
        var push: Bool = false
        var events: Bool = true
        var liveActivity: Bool = false
        var eventKinds: [String] = []
    }

    struct NotificationPreferences: Codable, Equatable {

        var takeoff: Bool
        var landing: Bool
        var online: Bool
        var offline: Bool

        /// Whether a watched pilot's takeoff may raise a Live Activity without
        /// the app being opened.
        var liveActivity: Bool

        static let `default` = NotificationPreferences(
            takeoff: true,
            landing: true,
            online: true,
            // The noisiest and least interesting of the four: a friend
            // disconnecting is not news, and on a bad server it happens a lot.
            offline: false,
            liveActivity: true
        )

        var wireFormat: [String: Bool] {
            [
                "takeoff": takeoff,
                "landing": landing,
                "online": online,
                "offline": offline,
                "liveActivity": liveActivity
            ]
        }

        /// True when nothing at all is switched on — the UI says so rather
        /// than leaving the user with a friends list that can't speak.
        var isSilent: Bool { !takeoff && !landing && !online && !offline }
    }
}
