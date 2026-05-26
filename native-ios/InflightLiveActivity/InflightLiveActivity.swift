import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct InflightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                        Text(context.attributes.callsign)
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isLanded ? "Landed" : "")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    RouteRow(context: context)
                        .padding(.vertical, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatusPill(context: context)
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "airplane")
                    .foregroundColor(.white)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.currentETA,
                     pauseTime: nil,
                     countsDown: true,
                     showsHours: false)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.orange)
                    .frame(maxWidth: 50)
            } minimal: {
                Image(systemName: "airplane")
                    .foregroundColor(.white)
            }
            .keylineTint(Color.orange)
        }
    }
}

@available(iOS 16.1, *)
struct LockScreenView: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                    Text(context.attributes.callsign)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image("AppIcon")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("inflight")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.85))
                }
            }
            RouteRow(context: context)
            StatusPill(context: context)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

@available(iOS 16.1, *)
struct RouteRow: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.attributes.departureIcao)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                    Text(timeString(context.state.currentATD ?? context.attributes.scheduledDeparture))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                lateRow(actual: context.state.currentATD,
                        scheduled: context.attributes.scheduledDeparture,
                        showStrikethroughOnRight: false)
            }
            Spacer(minLength: 4)
            Image(systemName: "airplane")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.white)
                .padding(.top, 4)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(timeString(context.state.currentETA))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(context.attributes.arrivalIcao)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                }
                lateRow(actual: context.state.currentETA,
                        scheduled: context.attributes.scheduledArrival,
                        showStrikethroughOnRight: true)
            }
        }
    }

    @ViewBuilder
    private func lateRow(actual: Date?,
                         scheduled: Date,
                         showStrikethroughOnRight: Bool) -> some View {
        let diffMin = actual.map { Int(($0.timeIntervalSince(scheduled)) / 60) }
        let scheduledLabel = timeString(scheduled)
        let lateLabel: String? = {
            guard let m = diffMin else { return nil }
            if m >= 1 { return "\(m)m Late" }
            if m <= -1 { return "\(-m)m Early" }
            return nil
        }()
        let color: Color = {
            guard let m = diffMin else { return .gray }
            return m >= 1 ? .red : (m <= -1 ? .green : .gray)
        }()

        HStack(spacing: 4) {
            if showStrikethroughOnRight {
                Text(scheduledLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.55))
                    .strikethrough(true, color: Color(white: 0.55))
                if let lateLabel = lateLabel {
                    Text("·").foregroundColor(Color(white: 0.45))
                    Text(lateLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                }
            } else {
                if let lateLabel = lateLabel {
                    Text(lateLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                    Text("·").foregroundColor(Color(white: 0.45))
                }
                Text(scheduledLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.55))
                    .strikethrough(true, color: Color(white: 0.55))
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

@available(iOS 16.1, *)
struct StatusPill: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        HStack(spacing: 10) {
            if context.state.isLanded {
                Text("Landed at \(context.attributes.arrivalIcao)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text("Landing in ")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.orange) +
                Text(timerInterval: Date()...context.state.currentETA,
                     pauseTime: nil,
                     countsDown: true,
                     showsHours: false)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color.orange)
            }
            Spacer(minLength: 4)
            Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.9))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@available(iOS 16.1, *)
@main
struct InflightLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        InflightLiveActivity()
    }
}
