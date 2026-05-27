import ActivityKit
import SwiftUI
import WidgetKit

// =============================================================================
// MARK: - Shared tokens
// =============================================================================

@available(iOS 16.1, *)
private enum InflightLA {
    static let accent      = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let accentSoft  = Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.22)
    static let success     = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let warn        = Color(red: 1.0, green: 0.349, blue: 0.349)
    static let text        = Color.white
    static let textSecond  = Color.white.opacity(0.72)
    static let textTert    = Color.white.opacity(0.45)
    static let stroke      = Color.white.opacity(0.12)
    static let trackBg     = Color.white.opacity(0.16)

    static let callsignFont = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let icaoFont     = Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
    static let timeFont     = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    static let statusFont   = Font.system(size: 12, weight: .semibold, design: .rounded)
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
    let total = context.attributes.totalDistanceNm
    let remaining = max(0, context.state.distanceToDestinationNm)
    if total > 1 {
        let done = max(0, total - remaining)
        return min(max(done / total, 0), 1)
    }
    let dep = context.attributes.scheduledDeparture
    let arr = context.attributes.scheduledArrival
    let span = arr.timeIntervalSince(dep)
    guard span > 0 else { return context.state.isLanded ? 1.0 : 0.0 }
    let elapsed = Date().timeIntervalSince(dep)
    return min(max(elapsed / span, 0), 1)
}

/// "On time" / "12m late" / "8m early" derived from actual vs scheduled time.
/// Tolerance of <1m is treated as on time.
@available(iOS 16.1, *)
private func statusFor(actual: Date?, scheduled: Date) -> (text: String, color: Color) {
    guard let actual = actual else {
        return ("On time", InflightLA.success)
    }
    let diffMin = Int(actual.timeIntervalSince(scheduled) / 60)
    if diffMin >= 1  { return ("\(diffMin)m late",  InflightLA.warn) }
    if diffMin <= -1 { return ("\(-diffMin)m early", InflightLA.success) }
    return ("On time", InflightLA.success)
}

// =============================================================================
// MARK: - Widget entry
// =============================================================================

@available(iOS 16.1, *)
struct InflightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.08, blue: 0.16).opacity(0.72))
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
                    RouteProgressView(context: context, compact: true)
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
                    Text(timerInterval: Date()...context.state.currentETA,
                         pauseTime: nil,
                         countsDown: true,
                         showsHours: false)
                        .font(InflightLA.counterFont)
                        .foregroundColor(InflightLA.accent)
                        .frame(maxWidth: 56)
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
            // Header: flight number on the left, brand logo on the right.
            HStack(alignment: .center) {
                Text(context.attributes.callsign)
                    .font(InflightLA.callsignFont)
                    .foregroundColor(InflightLA.text)
                Spacer()
                Image("InflightLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // ICAO + scheduled time, side by side. Mirrors the reference layout
            // "BCN 12:40 PM" / "2:20 PM LHR".
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DeparturePair(icao: context.attributes.departureIcao,
                              time: context.state.currentATD ?? context.attributes.scheduledDeparture)
                Spacer(minLength: 8)
                ArrivalPair(icao: context.attributes.arrivalIcao,
                            time: context.state.currentETA)
            }

            // Status line: "On time" / "8m early" / "12m late" under each end,
            // tinted green / red. Mirrors the screenshot's twin "On time" labels.
            HStack(alignment: .firstTextBaseline) {
                StatusLine(actual: context.state.currentATD,
                           scheduled: context.attributes.scheduledDeparture,
                           alignment: .leading)
                Spacer()
                StatusLine(actual: context.state.currentETA,
                           scheduled: context.attributes.scheduledArrival,
                           alignment: .trailing)
            }

            // Tall progress bar — the visual centerpiece.
            ProgressTrack(progress: flightProgress(context),
                          isLanded: context.state.isLanded)
                .padding(.top, 2)

            // Footer: "1h 15m left" on the right, optional landed badge or
            // distance hint on the left.
            HStack(alignment: .center) {
                if context.state.isLanded {
                    StatusBadge(text: "Landed at \(context.attributes.arrivalIcao)",
                                color: InflightLA.success)
                } else {
                    Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                        .font(InflightLA.footerFont)
                        .foregroundColor(InflightLA.textSecond)
                }
                Spacer()
                if !context.state.isLanded {
                    HStack(spacing: 4) {
                        Text(timerInterval: Date()...context.state.currentETA,
                             pauseTime: nil,
                             countsDown: true,
                             showsHours: false)
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.text)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 50, alignment: .trailing)
                        Text("left")
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// =============================================================================
// MARK: - ICAO + time pair (lock screen)
// =============================================================================

@available(iOS 16.1, *)
struct DeparturePair: View {
    let icao: String
    let time: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(icao)
                .font(InflightLA.icaoFont)
                .foregroundColor(InflightLA.text)
            Text(timeStringShort(time))
                .font(InflightLA.timeFont)
                .foregroundColor(InflightLA.text)
        }
    }
}

@available(iOS 16.1, *)
struct ArrivalPair: View {
    let icao: String
    let time: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeStringShort(time))
                .font(InflightLA.timeFont)
                .foregroundColor(InflightLA.text)
            Text(icao)
                .font(InflightLA.icaoFont)
                .foregroundColor(InflightLA.text)
        }
    }
}

// =============================================================================
// MARK: - Status line ("On time" / "12m late" / "8m early")
// =============================================================================

@available(iOS 16.1, *)
struct StatusLine: View {
    let actual: Date?
    let scheduled: Date
    let alignment: HorizontalAlignment

    var body: some View {
        let s = statusFor(actual: actual, scheduled: scheduled)
        Text(s.text)
            .font(InflightLA.statusFont)
            .foregroundColor(s.color)
    }
}

// =============================================================================
// MARK: - Route + progress (Dynamic Island center)
// =============================================================================

@available(iOS 16.1, *)
struct RouteProgressView: View {
    let context: ActivityViewContext<InflightActivityAttributes>
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.departureIcao)
                    .font(compact
                          ? .system(size: 19, weight: .bold, design: .rounded)
                          : InflightLA.icaoFont)
                    .foregroundColor(InflightLA.text)
                Spacer()
                Text(context.attributes.arrivalIcao)
                    .font(compact
                          ? .system(size: 19, weight: .bold, design: .rounded)
                          : InflightLA.icaoFont)
                    .foregroundColor(InflightLA.text)
            }
            ProgressTrack(progress: flightProgress(context),
                          isLanded: context.state.isLanded)
        }
    }
}

/// Pill-style track with a glowing plane glyph riding along it. Taller and
/// chunkier than the prior 3pt track so it reads as the lock-screen centerpiece.
@available(iOS 16.1, *)
struct ProgressTrack: View {
    let progress: Double
    let isLanded: Bool

    private let trackHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(InflightLA.trackBg)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(LinearGradient(colors: [InflightLA.accent.opacity(0.85),
                                                   InflightLA.accent],
                                          startPoint: .leading,
                                          endPoint: .trailing))
                    .frame(width: max(trackHeight, w * p), height: trackHeight)

                Image(systemName: isLanded ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: isLanded ? 16 : 14, weight: .semibold))
                    .foregroundColor(isLanded ? InflightLA.success : InflightLA.text)
                    .shadow(color: InflightLA.accent.opacity(0.45), radius: 4, x: 0, y: 0)
                    .offset(x: max(0, min(w - 14, w * p - 7)))
            }
            .frame(height: max(trackHeight, 18))
        }
        .frame(height: max(trackHeight, 18))
    }
}

// =============================================================================
// MARK: - Status badge + Dynamic Island ETA chip
// =============================================================================

@available(iOS 16.1, *)
struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(InflightLA.statusFont)
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
                Text(timerInterval: Date()...context.state.currentETA,
                     pauseTime: nil,
                     countsDown: true,
                     showsHours: false)
                    .font(InflightLA.counterFont)
                    .foregroundColor(InflightLA.accent)
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
