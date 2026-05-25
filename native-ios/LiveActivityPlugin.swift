import Foundation
import Capacitor
import ActivityKit

@objc(LiveActivityPlugin)
public class LiveActivityPlugin: CAPPlugin {

    private var activeActivityIdByFlight: [String: String] = [:]

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
        let schedDep = dateFromMs(call.getDouble("scheduledDepartureMs")) ?? Date()
        let schedArr = dateFromMs(call.getDouble("scheduledArrivalMs")) ?? Date().addingTimeInterval(3600)
        let currentETA = dateFromMs(call.getDouble("currentEtaMs")) ?? schedArr
        let currentATD = dateFromMs(call.getDouble("currentAtdMs"))
        let distNm = call.getDouble("distanceToDestinationNm") ?? 0
        let isLanded = call.getBool("isLanded") ?? false

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
            departureIcao: departureIcao,
            arrivalIcao: arrivalIcao,
            scheduledDeparture: schedDep,
            scheduledArrival: schedArr
        )

        let state = InflightActivityAttributes.ContentState(
            distanceToDestinationNm: distNm,
            currentETA: currentETA,
            currentATD: currentATD,
            isLanded: isLanded
        )

        do {
            let activity: Activity<InflightActivityAttributes>
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } else {
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: nil
                )
            }
            activeActivityIdByFlight[flightId] = activity.id
            call.resolve(["activityId": activity.id, "reused": false])
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

        let distNm = call.getDouble("distanceToDestinationNm") ?? 0
        let currentETA = dateFromMs(call.getDouble("currentEtaMs")) ?? Date()
        let currentATD = dateFromMs(call.getDouble("currentAtdMs"))
        let isLanded = call.getBool("isLanded") ?? false

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
