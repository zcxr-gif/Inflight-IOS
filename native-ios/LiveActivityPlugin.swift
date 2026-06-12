import Foundation
import Capacitor
import ActivityKit
import UserNotifications
import UIKit

@objc(LiveActivityPlugin)
public class LiveActivityPlugin: CAPPlugin, UNUserNotificationCenterDelegate {

    private var activeActivityIdByFlight: [String: String] = [:]
    private var didInstallForegroundDelegate = false
    private var cachedRemotePushToken: String?

    public override func load() {
        super.load()
        installForegroundDelegate()
        installRemotePushObservers()
        observePushToStartTokens()
    }

    /// Become the UNUserNotificationCenter delegate so local notifications
    /// surface as banners + sound even when the app is in the foreground.
    /// Without this iOS silently delivers them to Notification Center,
    /// which would defeat the purpose of "tell me when my friend goes
    /// airborne" if the user already has the app open.
    private func installForegroundDelegate() {
        guard !didInstallForegroundDelegate else { return }
        didInstallForegroundDelegate = true
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    // ─── Remote push (APNs) groundwork ─────────────────────────────────────
    //
    // The ACARS backend will eventually push watchlist notifications and
    // Live Activity updates while the app is closed. The Capacitor-generated
    // AppDelegate already re-posts the APNs callbacks as NotificationCenter
    // events, so we observe those rather than patching the (uncommitted)
    // AppDelegate. Tokens flow to JS via the "remotePushToken" event and
    // WatchlistService uploads them to the backend.
    //
    // Note: registration only succeeds once the build carries the
    // aps-environment entitlement (see inject_live_activity.rb,
    // INFLIGHT_ENABLE_PUSH). Until then didFailToRegister fires and we
    // surface it as the "remotePushRegistrationError" event.

    private func installRemotePushObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemotePushTokenRegistered(_:)),
            name: .capacitorDidRegisterForRemoteNotifications,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemotePushTokenError(_:)),
            name: .capacitorDidFailToRegisterForRemoteNotifications,
            object: nil
        )
    }

    @objc private func handleRemotePushTokenRegistered(_ notification: Notification) {
        guard let tokenData = notification.object as? Data else { return }
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        cachedRemotePushToken = hex
        notifyListeners("remotePushToken", data: ["token": hex])
    }

    @objc private func handleRemotePushTokenError(_ notification: Notification) {
        let message = (notification.object as? Error)?.localizedDescription ?? "unknown"
        notifyListeners("remotePushRegistrationError", data: ["error": message])
    }

    /// Ask iOS for an APNs device token. Silent (no user prompt) — the
    /// user-visible permission prompt is requestNotificationPermission;
    /// callers should ensure that's granted first. The token arrives
    /// asynchronously via the "remotePushToken" listener event.
    @objc func registerForRemotePush(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
               || settings.authorizationStatus == .provisional
               || settings.authorizationStatus == .ephemeral else {
                call.resolve([
                    "registered": false,
                    "reason": "not_authorized"
                ])
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
                var result: [String: Any] = ["registered": true]
                if let token = self.cachedRemotePushToken {
                    result["token"] = token
                }
                call.resolve(result)
            }
        }
    }

    @objc func getRemotePushToken(_ call: CAPPluginCall) {
        if let token = cachedRemotePushToken {
            call.resolve(["token": token])
        } else {
            call.resolve([:])
        }
    }

    /// Live Activities can be *started* remotely on iOS 17.2+ via a
    /// push-to-start token. Forward it to JS so the ACARS backend can one
    /// day open the lock-screen flight card without the app running.
    private func observePushToStartTokens() {
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<InflightActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    self.notifyListeners("liveActivityPushToStartToken", data: ["token": hex])
                }
            }
        }
    }

    /// Stream per-activity ActivityKit push tokens to JS. The backend needs
    /// one of these per Live Activity to push lock-screen updates over APNs
    /// while the app is closed.
    @available(iOS 16.1, *)
    private func observeActivityPushTokens(activity: Activity<InflightActivityAttributes>, flightId: String) {
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self.notifyListeners("liveActivityPushToken", data: [
                    "activityId": activity.id,
                    "flightId": flightId,
                    "token": hex
                ])
            }
        }
    }

    @objc func openSystemSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                call.reject("Settings URL unavailable")
                return
            }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:]) { success in
                    call.resolve(["opened": success])
                }
            } else {
                call.reject("Cannot open Settings")
            }
        }
    }

    @objc func getNotificationPermissionStatus(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let statusString: String
            let granted: Bool
            switch settings.authorizationStatus {
            case .authorized:
                statusString = "authorized"; granted = true
            case .provisional:
                statusString = "provisional"; granted = true
            case .ephemeral:
                statusString = "ephemeral"; granted = true
            case .denied:
                statusString = "denied"; granted = false
            case .notDetermined:
                statusString = "notDetermined"; granted = false
            @unknown default:
                statusString = "unknown"; granted = false
            }
            call.resolve([
                "status": statusString,
                "granted": granted
            ])
        }
    }

    @objc func requestNotificationPermission(_ call: CAPPluginCall) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized ||
               settings.authorizationStatus == .provisional ||
               settings.authorizationStatus == .ephemeral {
                call.resolve([
                    "granted": true,
                    "status": "authorized",
                    "prompted": false
                ])
                return
            }
            if settings.authorizationStatus == .denied {
                call.resolve([
                    "granted": false,
                    "status": "denied",
                    "prompted": false
                ])
                return
            }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    call.reject("Failed to request notification permission: \(error.localizedDescription)")
                    return
                }
                call.resolve([
                    "granted": granted,
                    "status": granted ? "authorized" : "denied",
                    "prompted": true
                ])
            }
        }
    }

    /// Fire an immediate local notification. Used by the watchlist
    /// trigger to surface "<pilot> is now airborne" as a real iOS banner
    /// instead of just an in-app toast that the user has to be looking
    /// at the screen to see.
    ///
    /// Args (all strings unless noted):
    ///   title           — required, big text at the top of the banner
    ///   body            — optional secondary line
    ///   identifier      — optional dedupe key (we generate one if missing).
    ///                     Reusing the same id while a notification is
    ///                     still pending updates it in place.
    ///   threadIdentifier— optional. iOS groups banners that share a
    ///                     thread id; we pass "watchlist" so multiple
    ///                     "airborne" alerts collapse instead of stacking.
    ///   sound           — optional bool, defaults to true
    ///   userInfo        — optional dictionary, surfaced back to JS when
    ///                     the user taps the banner (future hook).
    @objc func presentLocalNotification(_ call: CAPPluginCall) {
        guard let title = call.getString("title"), !title.isEmpty else {
            call.reject("Missing required field: title")
            return
        }
        let body            = call.getString("body") ?? ""
        let subtitle        = call.getString("subtitle") ?? ""
        let identifier      = call.getString("identifier") ?? UUID().uuidString
        let threadId        = call.getString("threadIdentifier") ?? "inflight-watchlist"
        let categoryId      = call.getString("categoryIdentifier") ?? ""
        let withSound       = call.getBool("sound") ?? true
        let userInfo        = call.getObject("userInfo") ?? [:]

        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !body.isEmpty { content.body = body }
        content.sound = withSound ? .default : nil
        content.threadIdentifier = threadId
        if !categoryId.isEmpty { content.categoryIdentifier = categoryId }
        content.userInfo = userInfo
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        // Pass nil trigger for "deliver immediately". Using
        // UNTimeIntervalNotificationTrigger with a 0.1s offset would also
        // work but adds latency. nil is the documented immediate path.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
               || settings.authorizationStatus == .provisional
               || settings.authorizationStatus == .ephemeral else {
                call.resolve([
                    "delivered": false,
                    "reason": "not_authorized",
                    "status": String(describing: settings.authorizationStatus)
                ])
                return
            }
            center.add(request) { error in
                if let error = error {
                    call.reject("Failed to schedule notification: \(error.localizedDescription)")
                    return
                }
                call.resolve([
                    "delivered": true,
                    "identifier": identifier
                ])
            }
        }
    }

    @objc func areActivitiesEnabled(_ call: CAPPluginCall) {
        if #available(iOS 16.1, *) {
            call.resolve([
                "supported": true,
                "enabled": ActivityAuthorizationInfo().areActivitiesEnabled
            ])
        } else {
            call.resolve(["supported": false, "enabled": false])
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        guard #available(iOS 16.1, *) else {
            call.reject("Live Activities require iOS 16.1 or later")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            call.reject("Live Activities are disabled by the user")
            return
        }

        guard let flightId = call.getString("flightId"),
              let callsign = call.getString("callsign"),
              let departureIcao = call.getString("departureIcao"),
              let arrivalIcao = call.getString("arrivalIcao") else {
            call.reject("Missing required field (flightId, callsign, departureIcao, arrivalIcao)")
            return
        }

        let airlineName = call.getString("airlineName") ?? ""
        let aircraftType = call.getString("aircraftType") ?? ""
        let liveryName = call.getString("liveryName") ?? ""
        let registration = call.getString("registration") ?? ""
        let schedDep = dateFromMs(call.getDouble("scheduledDepartureMs")) ?? Date()
        let schedArr = dateFromMs(call.getDouble("scheduledArrivalMs")) ?? Date().addingTimeInterval(3600)
        let currentETA = dateFromMs(call.getDouble("currentEtaMs")) ?? schedArr
        let currentATD = dateFromMs(call.getDouble("currentAtdMs"))
        let distNm = call.getDouble("distanceToDestinationNm") ?? 0
        // Total airport-to-airport distance for the progress bar. JS may
        // omit this on old callers -- fall back to the current remaining
        // distance so the bar starts at 0% progress (visually identical
        // to "just took off").
        let totalDistNm = call.getDouble("totalDistanceNm") ?? distNm
        let isLanded = call.getBool("isLanded") ?? false
        // Request an ActivityKit push token so the ACARS backend can update
        // the lock screen over APNs with the app closed. Opt-in: callers set
        // this only when the backend advertises push support, and we fall
        // back to a local-update-only activity if the OS refuses (e.g. the
        // build lacks the push entitlement).
        let wantsPushUpdates = call.getBool("wantsPushUpdates") ?? false

        if let existingId = activeActivityIdByFlight[flightId] {
            updateActivity(id: existingId,
                           distNm: distNm,
                           currentETA: currentETA,
                           currentATD: currentATD,
                           isLanded: isLanded)
            call.resolve(["activityId": existingId, "reused": true])
            return
        }

        let attributes = InflightActivityAttributes(
            callsign: callsign,
            airlineName: airlineName,
            aircraftType: aircraftType,
            liveryName: liveryName,
            registration: registration,
            departureIcao: departureIcao,
            arrivalIcao: arrivalIcao,
            scheduledDeparture: schedDep,
            scheduledArrival: schedArr,
            totalDistanceNm: max(totalDistNm, distNm)
        )

        let state = InflightActivityAttributes.ContentState(
            distanceToDestinationNm: distNm,
            currentETA: currentETA,
            currentATD: currentATD,
            isLanded: isLanded
        )

        func requestActivity(pushType: PushType?) throws -> Activity<InflightActivityAttributes> {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                return try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: pushType
                )
            } else {
                return try Activity.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: pushType
                )
            }
        }

        do {
            var activity: Activity<InflightActivityAttributes>
            var pushEnabled = false
            if wantsPushUpdates {
                do {
                    activity = try requestActivity(pushType: .token)
                    pushEnabled = true
                } catch {
                    // No push entitlement / OS refusal — a local-only
                    // activity is still better than none.
                    activity = try requestActivity(pushType: nil)
                }
            } else {
                activity = try requestActivity(pushType: nil)
            }
            if pushEnabled {
                observeActivityPushTokens(activity: activity, flightId: flightId)
            }
            activeActivityIdByFlight[flightId] = activity.id
            call.resolve(["activityId": activity.id, "reused": false, "pushEnabled": pushEnabled])
        } catch {
            call.reject("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        guard #available(iOS 16.1, *) else {
            call.reject("Live Activities require iOS 16.1 or later")
            return
        }
        guard let flightId = call.getString("flightId"),
              let activityId = activeActivityIdByFlight[flightId] else {
            call.reject("No Live Activity is running for this flight")
            return
        }

        // Preserve the previous activity state when the caller omits a
        // field. The old code defaulted a missing ETA to Date.now(),
        // which zeroed out the lock-screen countdown ("0 min
        // remaining") any time the JS bridge dropped a value -- the
        // root cause of the ETE / arrival time the user reported as
        // wrong. We now only overwrite a field when JS actually
        // provides one.
        // `.content` is iOS 16.2+, so fall back to `.contentState` on 16.1.
        let priorActivity = Activity<InflightActivityAttributes>.activities
            .first(where: { $0.id == activityId })
        let prior: InflightActivityAttributes.ContentState?
        if #available(iOS 16.2, *) {
            prior = priorActivity?.content.state
        } else {
            prior = priorActivity?.contentState
        }

        let distNm: Double
        if let d = call.getDouble("distanceToDestinationNm") {
            distNm = d
        } else {
            distNm = prior?.distanceToDestinationNm ?? 0
        }

        let currentETA: Date
        if let etaMs = call.getDouble("currentEtaMs"), let d = dateFromMs(etaMs) {
            currentETA = d
        } else if let p = prior?.currentETA {
            currentETA = p
        } else {
            // Last-ditch fallback so we still have *some* future date
            // to count down to. Never user-facing in practice because
            // `start` always seeds an ETA.
            currentETA = Date().addingTimeInterval(3600)
        }

        let currentATD: Date?
        if let atdMs = call.getDouble("currentAtdMs"), let d = dateFromMs(atdMs) {
            currentATD = d
        } else {
            currentATD = prior?.currentATD
        }

        let isLanded = call.getBool("isLanded") ?? prior?.isLanded ?? false

        updateActivity(id: activityId,
                       distNm: distNm,
                       currentETA: currentETA,
                       currentATD: currentATD,
                       isLanded: isLanded)
        call.resolve()
    }

    @objc func end(_ call: CAPPluginCall) {
        guard #available(iOS 16.1, *) else {
            call.resolve()
            return
        }
        guard let flightId = call.getString("flightId"),
              let activityId = activeActivityIdByFlight[flightId] else {
            call.resolve()
            return
        }

        let dismissImmediately = call.getBool("immediate") ?? false

        Task {
            for activity in Activity<InflightActivityAttributes>.activities where activity.id == activityId {
                if #available(iOS 16.2, *) {
                    let finalContent = ActivityContent(state: activity.content.state, staleDate: nil)
                    await activity.end(finalContent,
                                       dismissalPolicy: dismissImmediately ? .immediate : .default)
                } else {
                    await activity.end(dismissalPolicy: dismissImmediately ? .immediate : .default)
                }
            }
            self.activeActivityIdByFlight.removeValue(forKey: flightId)
            call.resolve()
        }
    }

    @available(iOS 16.1, *)
    private func updateActivity(id: String,
                                distNm: Double,
                                currentETA: Date,
                                currentATD: Date?,
                                isLanded: Bool) {
        Task {
            for activity in Activity<InflightActivityAttributes>.activities where activity.id == id {
                let newState = InflightActivityAttributes.ContentState(
                    distanceToDestinationNm: distNm,
                    currentETA: currentETA,
                    currentATD: currentATD,
                    isLanded: isLanded
                )
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: newState, staleDate: nil)
                    await activity.update(content)
                } else {
                    await activity.update(using: newState)
                }
            }
        }
    }

    private func dateFromMs(_ ms: Double?) -> Date? {
        guard let ms = ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }
}
