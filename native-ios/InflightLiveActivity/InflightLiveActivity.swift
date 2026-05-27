import ActivityKit
import SwiftUI
import WidgetKit

// =============================================================================
// MARK: - Shared tokens
// =============================================================================

@available(iOS 16.1, *)
private enum InflightLA {
    // Dark-gray surface tint, close to systemGray6 in dark mode. Reads as a
    // neutral pane on top of any wallpaper instead of biasing blue.
    static let surface     = Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.92)

    // Brand blue, slightly cooler than systemBlue so it pops against gray.
    static let accent      = Color(red: 0.30, green: 0.55, blue: 1.0)
    static let accentDeep  = Color(red: 0.20, green: 0.40, blue: 0.95)
    static let accentSoft  = Color(red: 0.30, green: 0.55, blue: 1.0).opacity(0.20)

    static let success     = Color(red: 0.20, green: 0.84, blue: 0.40)
    static let warn        = Color(red: 1.0, green: 0.39, blue: 0.39)

    static let text        = Color.white
    static let textSecond  = Color.white.opacity(0.75)
    static let textTert    = Color.white.opacity(0.45)
    static let stroke      = Color.white.opacity(0.08)
    static let trackBg     = Color.white.opacity(0.12)

    static let callsignFont = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let icaoFont     = Font.system(size: 28, weight: .heavy,  design: .rounded)
    static let timeFont     = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let statusFont   = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let footerFont   = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()
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
/// <1m drift is treated as on time.
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
        VStack(alignment: .leading, spacing: 12) {
            // Header: flight number on the left, brand logo on the right.
            HStack(alignment: .center) {
                Text(context.attributes.callsign)
                    .font(InflightLA.callsignFont)
                    .foregroundColor(InflightLA.text)
                Spacer()
                Image("InflightLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // ICAO + time pairs, one per side.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(context.attributes.departureIcao)
                            .font(InflightLA.icaoFont)
                            .foregroundColor(InflightLA.text)
                        Text(timeStringShort(context.state.currentATD ?? context.attributes.scheduledDeparture))
                            .font(InflightLA.timeFont)
                            .foregroundColor(InflightLA.text)
                    }
                    StatusLine(actual: context.state.currentATD,
                               scheduled: context.attributes.scheduledDeparture)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timeStringShort(context.state.currentETA))
                            .font(InflightLA.timeFont)
                            .foregroundColor(InflightLA.text)
                        Text(context.attributes.arrivalIcao)
                            .font(InflightLA.icaoFont)
                            .foregroundColor(InflightLA.text)
                    }
                    StatusLine(actual: context.state.currentETA,
                               scheduled: context.attributes.scheduledArrival)
                }
            }

            // Centerpiece: tall, rounded progress bar.
            ProgressTrack(progress: flightProgress(context),
                          isLanded: context.state.isLanded)
                .padding(.top, 2)

            // Footer: NM remaining on the left, "Xh Ym left" on the right.
            HStack(alignment: .center) {
                if context.state.isLanded {
                    StatusBadge(text: "Landed at \(context.attributes.arrivalIcao)",
                                color: InflightLA.success)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(InflightLA.textTert)
                        Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
                Spacer()
                if !context.state.isLanded {
                    HStack(spacing: 5) {
                        Text(timerInterval: Date()...context.state.currentETA,
                             pauseTime: nil,
                             countsDown: true,
                             showsHours: false)
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.text)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 56, alignment: .trailing)
                        Text("left")
                            .font(InflightLA.footerFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

// =============================================================================
// MARK: - Status line ("On time" / "12m late" / "8m early")
// =============================================================================

@available(iOS 16.1, *)
struct StatusLine: View {
    let actual: Date?
    let scheduled: Date

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
                          isLanded: context.state.isLanded,
                          compact: compact)
        }
    }
}

/// Thick rounded pill with the plane glyph riding along it. Designed to read
/// as the lock-screen centerpiece — close to the Flighty / Apple Wallet
/// boarding-pass progress aesthetic.
@available(iOS 16.1, *)
struct ProgressTrack: View {
    let progress: Double
    let isLanded: Bool
    var compact: Bool = false

    var body: some View {
        let height: CGFloat = compact ? 10 : 18
        let glyphSize: CGFloat = compact ? 13 : 20

        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(progress, 0), 1)
            let filled = max(height, w * p)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(InflightLA.trackBg)
                    .overlay(
                        Capsule().stroke(InflightLA.stroke, lineWidth: 0.5)
                    )
                    .frame(height: height)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [InflightLA.accent, InflightLA.accentDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: filled, height: height)
                    .shadow(color: InflightLA.accent.opacity(0.45),
                            radius: 6, x: 0, y: 0)

                // Plane glyph sits centered on the leading edge of the fill.
                Image(systemName: isLanded ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundColor(isLanded ? InflightLA.success : .white)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .offset(x: max(0, min(w - glyphSize, w * p - glyphSize / 2)))
            }
            .frame(height: max(height, glyphSize))
        }
        .frame(height: max((compact ? 10 : 18), (compact ? 13 : 20)))
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
