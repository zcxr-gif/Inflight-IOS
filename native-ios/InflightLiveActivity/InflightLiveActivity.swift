import ActivityKit
import SwiftUI
import WidgetKit

// =============================================================================
// MARK: - Shared tokens
// =============================================================================

@available(iOS 16.1, *)
private enum InflightLA {
    // Neutral dark-gray surface, close to systemGray6 in dark mode.
    static let surface     = Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.94)

    static let accent      = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let accentDeep  = Color(red: 0.20, green: 0.42, blue: 0.95)

    static let success     = Color(red: 0.20, green: 0.84, blue: 0.40)
    static let warn        = Color(red: 1.0, green: 0.39, blue: 0.39)

    static let text        = Color.white
    static let textSecond  = Color.white.opacity(0.72)
    static let textTert    = Color.white.opacity(0.40)
    static let stroke      = Color.white.opacity(0.08)
    static let trackBg     = Color.white.opacity(0.18)

    static let wordmarkFont = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let callsignFont = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let icaoFont     = Font.system(size: 26, weight: .heavy,    design: .rounded)
    static let timeFont     = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    static let estLabelFont = Font.system(size: 11, weight: .regular,  design: .rounded)
    static let estTimeFont  = Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()
    static let footerFont   = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
    static let counterFont  = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
}

// =============================================================================
// MARK: - Helpers
// =============================================================================

@available(iOS 16.1, *)
private func timeStringShort(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
}

@available(iOS 16.1, *)
private func flightProgress(_ context: ActivityViewContext<InflightActivityAttributes>) -> Double {
    let st = context.state
    if st.isLanded { return 1.0 }
    let total = st.totalDistanceNm
    let remaining = max(0, st.distanceToDestinationNm)
    // Distance-based progress is what "how close is the plane" really means,
    // so prefer it. Guard against a bogus total (<= remaining) which would
    // otherwise peg the plane at the origin forever.
    if total > 1 && total >= remaining {
        let done = max(0, total - remaining)
        return min(max(done / total, 0), 1)
    }
    // Fallback: time-based progress across the active flight window. Anchored
    // on the actual takeoff when known (else the scheduled departure) and
    // running toward the live ETA, so the fill advances in step with the
    // countdown even while we wait on a fresh distance push.
    let start = st.currentATD ?? st.scheduledDeparture
    let end = st.currentETA
    let span = end.timeIntervalSince(start)
    guard span > 0 else { return 0 }
    let elapsed = Date().timeIntervalSince(start)
    return min(max(elapsed / span, 0), 1)
}

/// Show the hours component on the countdown only when at least an hour is
/// left -- otherwise the timer reads cleanly as minutes:seconds.
@available(iOS 16.1, *)
private func etaShowsHours(_ eta: Date) -> Bool {
    eta.timeIntervalSinceNow >= 3600
}

// =============================================================================
// MARK: - Widget entry
// =============================================================================

@available(iOS 16.1, *)
struct InflightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(InflightLA.surface)
                .activitySystemActionForegroundColor(InflightLA.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(InflightLA.accent)
                        Text(context.attributes.callsign)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(InflightLA.text)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DynamicETAReadout(context: context)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    DynamicIslandRoute(context: context)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM remaining")
                            .font(InflightLA.counterFont)
                            .foregroundColor(InflightLA.textSecond)
                        Spacer()
                        if context.state.isLanded {
                            StatusBadge(text: "Landed", color: InflightLA.success)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(InflightLA.accent)
            } compactTrailing: {
                if context.state.isLanded {
                    Text("Landed")
                        .font(InflightLA.counterFont)
                        .foregroundColor(InflightLA.success)
                        .frame(maxWidth: 60)
                } else {
                    ETECountdown(eta: context.state.currentETA)
                        .frame(maxWidth: 64)
                }
            } minimal: {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(InflightLA.accent)
            }
            .keylineTint(InflightLA.accent)
        }
    }
}

// =============================================================================
// MARK: - Lock screen
// =============================================================================

@available(iOS 16.1, *)
struct LockScreenView: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: callsign on the left, inflight wordmark on the right.
            HStack(alignment: .center) {
                Text(context.attributes.callsign)
                    .font(InflightLA.callsignFont)
                    .foregroundColor(InflightLA.text)
                Spacer()
                Text("inflight")
                    .font(InflightLA.wordmarkFont)
                    .foregroundColor(InflightLA.textTert)
                    .tracking(0.5)
            }

            // Route: BCN ─────✈─────▸ LHR
            HStack(alignment: .center, spacing: 10) {
                Text(context.attributes.departureIcao)
                    .font(InflightLA.icaoFont)
                    .foregroundColor(InflightLA.text)
                ArrowRoute(progress: flightProgress(context),
                           isLanded: context.state.isLanded)
                    .frame(maxWidth: .infinity)
                Text(context.attributes.arrivalIcao)
                    .font(InflightLA.icaoFont)
                    .foregroundColor(InflightLA.text)
            }

            // Times under each ICAO, with an "Estimated" line below if the
            // estimate / actual shifted from the schedule.
            HStack(alignment: .top) {
                TimeBlock(scheduled: context.state.scheduledDeparture,
                          actual: context.state.currentATD,
                          alignment: .leading)
                Spacer()
                TimeBlock(scheduled: context.state.scheduledArrival,
                          actual: context.state.currentETA,
                          alignment: .trailing)
            }

            // Footer: NM remaining on the left, "Xh Ym left" on the right.
            HStack(alignment: .center) {
                if context.state.isLanded {
                    StatusBadge(text: "Landed at \(context.attributes.arrivalIcao)",
                                color: InflightLA.success)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(InflightLA.textTert)
                        Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
                Spacer()
                if !context.state.isLanded {
                    HStack(spacing: 4) {
                        ETECountdown(eta: context.state.currentETA,
                                     font: InflightLA.footerFont,
                                     color: InflightLA.text)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 64, alignment: .trailing)
                        Text("left")
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// =============================================================================
// MARK: - Time block (scheduled + optional estimated)
// =============================================================================

@available(iOS 16.1, *)
struct TimeBlock: View {
    let scheduled: Date
    let actual: Date?
    let alignment: HorizontalAlignment

    var body: some View {
        // Only surface the "Estimated" row when it actually differs from the
        // schedule -- duplicating the same time on two lines is noise.
        let drift = actual.map { Int($0.timeIntervalSince(scheduled) / 60) } ?? 0
        let estimated = (actual != nil && abs(drift) >= 1) ? actual : nil
        let estimatedColor: Color = drift > 0 ? InflightLA.warn : InflightLA.success

        VStack(alignment: alignment, spacing: 2) {
            Text(timeStringShort(scheduled))
                .font(InflightLA.timeFont)
                .foregroundColor(InflightLA.text)
            if let est = estimated {
                HStack(spacing: 3) {
                    Text("Estimated")
                        .font(InflightLA.estLabelFont)
                        .foregroundColor(InflightLA.textTert)
                    Text(timeStringShort(est))
                        .font(InflightLA.estTimeFont)
                        .foregroundColor(estimatedColor)
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Arrow route (dashed connector with plane + arrowhead)
// =============================================================================

@available(iOS 16.1, *)
struct ArrowRoute: View {
    let progress: Double
    let isLanded: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let y = h / 2
            let p = min(max(progress, 0), 1)
            let leftPad: CGFloat = 2
            let rightPad: CGFloat = 12          // leaves room for the arrowhead
            let usable = max(0, w - leftPad - rightPad)
            let planeX = leftPad + usable * p
            let glyphSize: CGFloat = 14

            ZStack {
                // Background dashed line spanning the full route.
                Path { path in
                    path.move(to: CGPoint(x: leftPad, y: y))
                    path.addLine(to: CGPoint(x: leftPad + usable, y: y))
                }
                .stroke(InflightLA.trackBg,
                        style: StrokeStyle(lineWidth: 1.5,
                                           lineCap: .round,
                                           dash: [2.5, 3.5]))

                // Solid filled portion up to current progress.
                Path { path in
                    path.move(to: CGPoint(x: leftPad, y: y))
                    path.addLine(to: CGPoint(x: planeX, y: y))
                }
                .stroke(
                    LinearGradient(
                        colors: [InflightLA.accent, InflightLA.accentDeep],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )

                // Arrowhead on the right end of the route.
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(InflightLA.textTert)
                    .position(x: w - 6, y: y)

                // Plane (or check-mark when landed) riding the line.
                Image(systemName: isLanded ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundColor(isLanded ? InflightLA.success : .white)
                    .shadow(color: InflightLA.accent.opacity(0.45),
                            radius: 3, x: 0, y: 0)
                    .position(x: planeX, y: y)
            }
        }
        .frame(height: 20)
    }
}

// =============================================================================
// MARK: - Dynamic Island center (compact route view)
// =============================================================================

@available(iOS 16.1, *)
struct DynamicIslandRoute: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.departureIcao)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(InflightLA.text)
                Spacer()
                Text(context.attributes.arrivalIcao)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(InflightLA.text)
            }
            ArrowRoute(progress: flightProgress(context),
                       isLanded: context.state.isLanded)
        }
    }
}

// =============================================================================
// MARK: - Status badge + Dynamic Island ETA chip
// =============================================================================

/// A live ETE countdown rendered by the system clock, so it stays accurate
/// to the second without a push -- including while the phone is locked and
/// the app suspended. Shows hours + minutes for long legs, minutes + seconds
/// for the final hour.
@available(iOS 16.1, *)
struct ETECountdown: View {
    let eta: Date
    var font: Font = InflightLA.counterFont
    var color: Color = InflightLA.accent

    var body: some View {
        // `Text(timerInterval:)` requires a strictly-increasing range; clamp
        // the end past "now" so an already-elapsed ETA can't crash the view.
        let end = max(eta, Date().addingTimeInterval(1))
        Text(timerInterval: Date()...end,
             pauseTime: nil,
             countsDown: true,
             showsHours: etaShowsHours(eta))
            .font(font)
            .foregroundColor(color)
            .monospacedDigit()
    }
}

@available(iOS 16.1, *)
struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(InflightLA.counterFont)
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
    }
}

@available(iOS 16.1, *)
struct DynamicETAReadout: View {
    let context: ActivityViewContext<InflightActivityAttributes>
    var body: some View {
        if context.state.isLanded {
            StatusBadge(text: "Landed", color: InflightLA.success)
        } else {
            HStack(spacing: 4) {
                ETECountdown(eta: context.state.currentETA)
                Text("left")
                    .font(InflightLA.counterFont)
                    .foregroundColor(InflightLA.textSecond)
            }
        }
    }
}

// =============================================================================
// MARK: - Bundle entry
// =============================================================================

@available(iOS 16.1, *)
@main
struct InflightLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        InflightLiveActivity()
    }
}
