import ActivityKit
import SwiftUI
import WidgetKit

// =============================================================================
// MARK: - Shared tokens
// Mirrors the iOS-native palette + typography used across the rest of the
// Inflight UI (see MobileLandingChromeUI + MobileDashboardUI redesign).
// Centralized here so a tweak to the accent only happens in one place.
// =============================================================================

@available(iOS 16.1, *)
private enum InflightLA {
    static let accent      = Color(red: 0.039, green: 0.518, blue: 1.0)   // iOS systemBlue
    static let accentSoft  = Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.22)
    static let success     = Color(red: 0.188, green: 0.820, blue: 0.345) // systemGreen
    static let text        = Color.white
    static let textSecond  = Color.white.opacity(0.72)
    static let textTert    = Color.white.opacity(0.45)
    static let stroke      = Color.white.opacity(0.12)
    static let trackBg     = Color.white.opacity(0.16)

    static let titleFont   = Font.system(size: 13, weight: .semibold, design: .default)
    static let icaoFont    = Font.system(size: 28, weight: .bold,  design: .rounded)
    static let timeFont    = Font.system(size: 13, weight: .medium, design: .rounded)
    static let etaFont     = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let badgeFont   = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let counterFont = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
}

// =============================================================================
// MARK: - Helpers
// =============================================================================

@available(iOS 16.1, *)
private func timeStringHHmm(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
}

@available(iOS 16.1, *)
private func flightProgress(_ context: ActivityViewContext<InflightActivityAttributes>) -> Double {
    // Prefer distance-based progress -- the most accurate signal we have.
    let total = context.attributes.totalDistanceNm
    let remaining = max(0, context.state.distanceToDestinationNm)
    if total > 1 {
        let done = max(0, total - remaining)
        return min(max(done / total, 0), 1)
    }
    // Fall back to time-based progress if the total wasn't captured at start.
    let dep = context.attributes.scheduledDeparture
    let arr = context.attributes.scheduledArrival
    let span = arr.timeIntervalSince(dep)
    guard span > 0 else { return context.state.isLanded ? 1.0 : 0.0 }
    let elapsed = Date().timeIntervalSince(dep)
    return min(max(elapsed / span, 0), 1)
}

// =============================================================================
// MARK: - Widget entry
// =============================================================================

@available(iOS 16.1, *)
struct InflightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LockScreenView(context: context)
                // Subtle navy gradient instead of a flat black tint, so the
                // widget reads as a single iOS-native pane rather than a box
                // sitting on the wallpaper.
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
                            .font(InflightLA.timeFont)
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
            // Header: callsign + brand
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(InflightLA.accent)
                    Text(context.attributes.callsign)
                        .font(InflightLA.titleFont)
                        .foregroundColor(InflightLA.text)
                    if !context.attributes.airlineName.isEmpty {
                        Text("·")
                            .font(InflightLA.titleFont)
                            .foregroundColor(InflightLA.textTert)
                        Text(context.attributes.airlineName)
                            .font(InflightLA.titleFont)
                            .foregroundColor(InflightLA.textSecond)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    Image("AppIcon")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text("inflight")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(InflightLA.textTert)
                }
            }

            // ICAO row + progress bar
            RouteProgressView(context: context, compact: false)

            // Scheduled times under each side of the bar
            HStack(alignment: .firstTextBaseline) {
                TimeWithLate(actual: context.state.currentATD,
                             scheduled: context.attributes.scheduledDeparture,
                             alignment: .leading)
                Spacer()
                TimeWithLate(actual: context.state.currentETA,
                             scheduled: context.attributes.scheduledArrival,
                             alignment: .trailing)
            }

            // Bottom row: countdown + remaining distance
            HStack(alignment: .center, spacing: 10) {
                if context.state.isLanded {
                    StatusBadge(text: "Landed at \(context.attributes.arrivalIcao)",
                                color: InflightLA.success)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(InflightLA.accent)
                        Text(timerInterval: Date()...context.state.currentETA,
                             pauseTime: nil,
                             countsDown: true,
                             showsHours: false)
                            .font(InflightLA.etaFont.monospacedDigit())
                            .foregroundColor(InflightLA.accent)
                        Text("remaining")
                            .font(InflightLA.timeFont)
                            .foregroundColor(InflightLA.textSecond)
                    }
                }
                Spacer()
                Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                    .font(InflightLA.badgeFont.monospacedDigit())
                    .foregroundColor(InflightLA.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(InflightLA.accentSoft, in: Capsule())
                    .overlay(Capsule().stroke(InflightLA.stroke, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// =============================================================================
// MARK: - Route + progress (shared lock-screen and DI center)
// =============================================================================

@available(iOS 16.1, *)
struct RouteProgressView: View {
    let context: ActivityViewContext<InflightActivityAttributes>
    /// `true` when rendering inside the Dynamic Island center region, where
    /// vertical space is tighter and we want to drop the ICAO font slightly.
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

/// A 3pt rounded track with a glowing plane glyph riding along it. Designed
/// to feel like the Flighty / Apple Wallet boarding-pass progress indicator.
@available(iOS 16.1, *)
struct ProgressTrack: View {
    let progress: Double
    let isLanded: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(InflightLA.trackBg)
                    .frame(height: 3)

                // Filled portion
                Capsule()
                    .fill(LinearGradient(colors: [InflightLA.accent.opacity(0.85),
                                                   InflightLA.accent],
                                          startPoint: .leading,
                                          endPoint: .trailing))
                    .frame(width: max(8, w * p), height: 3)

                // Plane glyph
                Image(systemName: isLanded ? "checkmark.circle.fill" : "airplane")
                    .font(.system(size: isLanded ? 16 : 14, weight: .semibold))
                    .foregroundColor(isLanded ? InflightLA.success : InflightLA.text)
                    .shadow(color: InflightLA.accent.opacity(0.45), radius: 4, x: 0, y: 0)
                    .offset(x: max(0, min(w - 14, w * p - 7)))
            }
            .frame(height: 18)
        }
        .frame(height: 18)
    }
}

// =============================================================================
// MARK: - Time-with-late stack (used under each ICAO)
// =============================================================================

@available(iOS 16.1, *)
struct TimeWithLate: View {
    let actual: Date?
    let scheduled: Date
    let alignment: HorizontalAlignment

    var body: some View {
        let diffMin = actual.map { Int($0.timeIntervalSince(scheduled) / 60) }
        let isLate  = (diffMin ?? 0) >=  1
        let isEarly = (diffMin ?? 0) <= -1
        let badgeText: String? = {
            guard let m = diffMin else { return nil }
            if m >= 1  { return "\(m)m late" }
            if m <= -1 { return "\(-m)m early" }
            return nil
        }()
        let badgeColor: Color = isLate ? .red : (isEarly ? InflightLA.success : InflightLA.textTert)

        VStack(alignment: alignment, spacing: 2) {
            Text(timeStringHHmm(actual ?? scheduled))
                .font(InflightLA.timeFont)
                .foregroundColor(InflightLA.text)
            HStack(spacing: 4) {
                if actual != nil && (isLate || isEarly) {
                    Text(timeStringHHmm(scheduled))
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(InflightLA.textTert)
                        .strikethrough(true, color: InflightLA.textTert)
                }
                if let badgeText = badgeText {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(badgeColor)
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Status badge + small Dynamic Island ETA chip
// =============================================================================

@available(iOS 16.1, *)
struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(InflightLA.badgeFont)
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
                    .font(InflightLA.timeFont)
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
