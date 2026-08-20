import Combine
import UIKit
import UserNotifications

/// Notification permission, the APNs token, and what happens when one is
/// tapped.
///
/// The device token is the app's whole identity with the backend — there is no
/// sign-in — so getting it registered is the first thing that happens once
/// permission is granted, and everything that depends on it (the friends
/// subscription, the Live Activity push-to-start token) is kicked off from the
/// same callback rather than racing it.
///
/// A plain `ObservableObject` rather than a `@MainActor` one, matching the
/// other stores in the app: a global-actor-isolated singleton can't be read
/// from a SwiftUI view's property initialiser, which is exactly where every
/// one of these gets read. Main-thread discipline is kept by hand instead —
/// every published mutation goes through `onMain`.
final class PushService: NSObject, ObservableObject {

    static let shared = PushService()

    /// Hex APNs token, or nil until the system hands one over. Persisted so a
    /// launch that hasn't heard from APNs yet can still sync the friends list
    /// against the token it had last time — tokens are stable in practice, and
    /// a stale one is pruned by the backend the first time APNs rejects it.
    @Published private(set) var deviceToken: String?

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Set when a notification is tapped, so the map can go and find that
    /// pilot. Cleared by whoever acts on it.
    @Published var pendingPilot: String?

    private static let tokenKey = "push.deviceToken"

    private let defaults: UserDefaults

    private override init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        super.init()
        deviceToken = defaults.string(forKey: Self.tokenKey)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Permission

    func start() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.onMain {
                guard let self = self else { return }
                self.authorization = settings.authorizationStatus
                // Already granted on a previous launch: re-register, because
                // the token can change and only registering produces it.
                if settings.authorizationStatus == .authorized {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    /// Asks, if we haven't already. `completion` reports whether notifications
    /// can now be delivered — including the case where the user said no some
    /// time ago and the only way forward is Settings.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                if let error = error {
                    print("[push] Authorization failed: \(error.localizedDescription)")
                }
                self?.onMain {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    completion?(granted)
                }
            }
    }

    var canNotify: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    // MARK: - Token

    func handleRegistration(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex != deviceToken else { return }

        onMain { [weak self] in
            guard let self = self else { return }
            self.deviceToken = hex
            self.defaults.set(hex, forKey: Self.tokenKey)

            // Everything downstream of having a token, in the order it
            // matters: the subscription is what makes notifications arrive at
            // all, and the push-to-start token is what lets a takeoff raise a
            // banner.
            FriendsStore.shared.syncToBackend()
            LiveActivityController.shared.registerPushToStartToken()
            self.syncAccountRegistration()
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        // Not fatal and not worth surfacing: this is routinely a simulator, or
        // a device with no network yet. The next launch tries again.
        print("[push] APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - The account this device belongs to

    /// Ties this device's APNs token to the signed-in account.
    ///
    /// Every notification the app has sent until now is about somebody you are
    /// *watching*, and needs no account: the backend addresses those by the
    /// APNs token that registered the watch, which is the whole identity the
    /// tracker has ever had.
    ///
    /// A notice about your **own** flight cannot work that way. The one the
    /// server can send — that Connect has stopped reading your sim, which by
    /// definition happens while this app is suspended behind Infinite Flight
    /// and cannot notice it itself — is addressed to the pilot, and the server
    /// knows which pilot by the account their live status is keyed on. So the
    /// account has to be able to find a device, and this is that link.
    ///
    /// Idempotent, and silent about everything: it needs both halves, and
    /// signed out with no token is the ordinary state of a fresh install
    /// rather than a failure. Re-sent on launch, on a new token and on sign-in,
    /// which between them repair a registration that failed while offline.
    func syncAccountRegistration() {
        guard let token = deviceToken, let url = AppConfig.pushDevicesURL else { return }

        Task {
            guard let accessToken = await AccountStore.shared.currentAccessToken() else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["deviceToken": token, "platform": "ios"]
            )

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    print("[push] Account registration rejected: HTTP \(http.statusCode)")
                }
            } catch {
                // Nothing to retry here on purpose: the next launch re-sends it.
                print("[push] Account registration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Unties it again, on the way out of an account.
    ///
    /// Takes the token it should forget rather than reading it, because sign-out
    /// is exactly the moment the account it belonged to is being torn down —
    /// and leaving the row behind would mean the next person to sign in on this
    /// device receives the previous pilot's flight notices.
    func clearAccountRegistration(accessToken: String) {
        guard let token = deviceToken,
              let url = AppConfig.pushDeviceURL(deviceToken: token) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}

// MARK: - Local notifications

extension PushService {

    /// Posts a notification from the app itself, with no server involved.
    ///
    /// The remote path exists for things only the backend knows — a friend
    /// taking off while the app is closed. This is for the opposite case:
    /// something this device worked out on its own and the pilot is waiting to
    /// hear, like a Connect session finally attaching after the sim was
    /// started. No token, no round trip, and it works with the app in any
    /// state.
    ///
    /// Silently does nothing when notifications have not been allowed. A
    /// connection succeeding is not a reason to raise a permission prompt.
    func post(title: String, body: String, identifier: String) {
        guard canNotify else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // A stable identifier per kind of event, so a reconnect replaces the
        // previous notice rather than stacking a pile of them in Notification
        // Centre.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil          // nil delivers immediately.
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[push] Local notification failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Delivery

extension PushService: UNUserNotificationCenterDelegate {

    /// Show the banner even with the app open. A friend taking off while you
    /// are looking at the map is exactly when you want to be told — the map is
    /// showing the whole server, not them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let username = response.notification.request.content.userInfo["username"] as? String
        onMain { [weak self] in
            if let username = username, !username.isEmpty {
                self?.pendingPilot = username
            }
            completionHandler()
        }
    }
}

/// APNs callbacks only reach a `UIApplicationDelegate`, so the SwiftUI app
/// keeps one for that alone.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushService.shared.start()
        FriendsStore.shared.refreshCapabilities()
        // Re-sends the whole list on every launch, which is what repairs a
        // subscription that failed to save while the phone was offline.
        FriendsStore.shared.syncToBackend()
        // Repairs a registration that failed while the phone was offline, and
        // covers the launch where APNs hands back the token it already had and
        // `handleRegistration` short-circuits.
        PushService.shared.syncAccountRegistration()
        LiveActivityController.shared.resumeTracking()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushService.shared.handleRegistration(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushService.shared.handleRegistrationFailure(error)
    }
}
