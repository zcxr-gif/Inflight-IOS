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
    static let danger      = Color(red: 1.000, green: 0.271, blue: 0.227) // systemRed
    static let warning     = Color(red: 1.000, green: 0.620, blue: 0.039) // systemOrange
    static let descend     = Color(red: 0.690, green: 0.557, blue: 1.000) // soft violet
    static let text        = Color.white
    static let textSecond  = Color.white.opacity(0.72)
    static let textTert    = Color.white.opacity(0.45)
    static let stroke      = Color.white.opacity(0.12)
    static let trackBg     = Color.white.opacity(0.18)
    static let chipBg      = Color.white.opacity(0.06)

    static let titleFont   = Font.system(size: 13, weight: .semibold, design: .default)
    static let icaoFont    = Font.system(size: 28, weight: .bold,  design: .rounded)
    static let icaoFontDI  = Font.system(size: 19, weight: .bold,  design: .rounded)
    static let timeFont    = Font.system(size: 13, weight: .medium, design: .rounded)
    static let etaFont     = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let badgeFont   = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let deltaFont   = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let phaseFont   = Font.system(size: 11, weight: .heavy,    design: .rounded)
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
// MARK: - Flight phase derivation
// All derived from existing state -- no new fields needed across the JS bridge.
// =============================================================================

@available(iOS 16.1, *)
enum FlightPhase {
    case preflight, climb, cruise, descent, approach, landed

    var label: String {
        switch self {
        case .preflight: return "Pre-flight"
        case .climb:     return "Climb"
        case .cruise:    return "Cruise"
        case .descent:   return "Descent"
        case .approach:  return "Final"
        case .landed:    return "Landed"
        }
    }
    var color: Color {
        switch self {
        case .preflight: return InflightLA.textSecond
        case .climb:     return InflightLA.warning
        case .cruise:    return InflightLA.accent
        case .descent:   return InflightLA.descend
        case .approach:  return InflightLA.descend
        case .landed:    return InflightLA.success
        }
    }
    var icon: String {
        switch self {
        case .preflight: return "clock.arrow.circlepath"
        case .climb:     return "airplane.departure"
        case .cruise:    return "airplane"
        case .descent:   return "airplane.arrival"
        case .approach:  return "mappin.and.ellipse"
        case .landed:    return "checkmark.circle.fill"
        }
    }
}

@available(iOS 16.1, *)
private func currentPhase(_ context: ActivityViewContext<InflightActivityAttributes>) -> FlightPhase {
    if context.state.isLanded { return .landed }
    if context.state.currentATD == nil { return .preflight }
    let p = flightProgress(context)
    switch p {
    case ..<0.10: return .climb
    case ..<0.80: return .cruise
    case ..<0.95: return .descent
    default:      return .approach
    }
}

@available(iOS 16.1, *)
private func progressPercent(_ context: ActivityViewContext<InflightActivityAttributes>) -> Int {
    let pct = (flightProgress(context) * 100).rounded()
    return min(100, max(0, Int(pct)))
}

// =============================================================================
// MARK: - Widget entry
// =============================================================================

@available(iOS 16.1, *)
struct InflightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LockScreenView(context: context)
                // Deep navy backdrop -- the aurora layer inside the view adds
                // the visible brand wash, so this tint just keeps the widget
                // from blending into a bright wallpaper.
                .activityBackgroundTint(Color(red: 0.03, green: 0.06, blue: 0.13).opacity(0.78))
                .activitySystemActionForegroundColor(InflightLA.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: currentPhase(context).icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(currentPhase(context).color)
                        Text(context.attributes.callsign)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(InflightLA.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DynamicETAReadout(context: context)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    DIRouteRow(context: context)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        PhaseChip(phase: currentPhase(context),
                                  progressPct: progressPercent(context),
                                  compact: true)
                        Spacer(minLength: 6)
                        Text("\(Int(max(0, context.state.distanceToDestinationNm))) NM")
                            .font(InflightLA.timeFont.monospacedDigit())
                            .foregroundColor(InflightLA.textSecond)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: currentPhase(context).icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(currentPhase(context).color)
            } compactTrailing: {
                if context.state.isLanded {
                    Text("Landed")
                        .font(InflightLA.counterFont)
                        .foregroundColor(InflightLA.success)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 64)
                } else {
                    Text(timerInterval: Date()...context.state.currentETA,
                         pauseTime: nil,
                         countsDown: true,
                         showsHours: false)
                        .font(InflightLA.counterFont)
                        .foregroundColor(InflightLA.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 58)
                }
            } minimal: {
                Image(systemName: currentPhase(context).icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(currentPhase(context).color)
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
        VStack(alignment: .leading, spacing: 11) {
            HeaderRow(context: context)
            RouteBlock(context: context)
            MetricsRow(context: context)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// =============================================================================
// MARK: - Header (callsign pill + airline + brand wordmark)
// =============================================================================

@available(iOS 16.1, *)
private struct HeaderRow: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            CallsignPill(callsign: context.attributes.callsign)

            if !context.attributes.airlineName.isEmpty {
                Text(context.attributes.airlineName)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(InflightLA.textSecond)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            BrandMark()
        }
    }
}

@available(iOS 16.1, *)
private struct CallsignPill: View {
    let callsign: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "airplane")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(InflightLA.accent)
            Text(callsign)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(InflightLA.text)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(InflightLA.accent.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(InflightLA.accent.opacity(0.4), lineWidth: 0.5))
        .fixedSize()
    }
}

@available(iOS 16.1, *)
private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(InflightLA.accent)
            Text("inflight")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(InflightLA.text)
                .tracking(0.3)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(InflightLA.chipBg, in: Capsule())
        .overlay(Capsule().stroke(InflightLA.stroke, lineWidth: 0.5))
        .fixedSize()
    }
}

// =============================================================================
// MARK: - Route block (ICAO+time pairs over progress bar)
// =============================================================================

@available(iOS 16.1, *)
private struct RouteBlock: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                EndpointColumn(icao: context.attributes.departureIcao,
                               actual: context.state.currentATD,
                               scheduled: context.attributes.scheduledDeparture,
                               alignment: .leading)
                Spacer(minLength: 8)
                EndpointColumn(icao: context.attributes.arrivalIcao,
                               actual: context.state.currentETA,
                               scheduled: context.attributes.scheduledArrival,
                               alignment: .trailing)
            }
            ProgressTrack(progress: flightProgress(context),
                          isLanded: context.state.isLanded)
        }
    }
}

/// One side of the route block. Groups the ICAO (big) above its time line so
/// the relationship between airport and ETA/ATD is immediately obvious. The
/// delay chip uses a colored pill rather than a strikethrough scheduled time
/// — same information, less visual noise.
@available(iOS 16.1, *)
private struct EndpointColumn: View {
    let icao: String
    let actual: Date?
    let scheduled: Date
    let alignment: HorizontalAlignment

    var body: some View {
        let diffMin: Int? = actual.map { Int(($0.timeIntervalSince(scheduled) / 60).rounded()) }
        let badgeText: String? = {
            guard let m = diffMin, m != 0 else { return nil }
            return m > 0 ? "+\(m)m" : "\(m)m"
        }()
        let badgeColor: Color = {
            guard let m = diffMin else { return InflightLA.textTert }
            if m >=  1 { return InflightLA.danger }
            if m <= -1 { return InflightLA.success }
            return InflightLA.textTert
        }()

        VStack(alignment: alignment, spacing: 3) {
            Text(icao)
                .font(InflightLA.icaoFont)
                .foregroundColor(InflightLA.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                Text(timeStringHHmm(actual ?? scheduled))
                    .font(InflightLA.timeFont.monospacedDigit())
                    .foregroundColor(InflightLA.textSecond)
                if let badgeText = badgeText {
                    Text(badgeText)
                        .font(InflightLA.deltaFont.monospacedDigit())
                        .foregroundColor(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(badgeColor.opacity(0.18), in: Capsule())
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// =============================================================================
// MARK: - Metrics row (phase + ETA + distance)
// =============================================================================

@available(iOS 16.1, *)
private struct MetricsRow: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            PhaseChip(phase: currentPhase(context),
                      progressPct: progressPercent(context),
                      compact: false)

            Spacer(minLength: 6)

            if context.state.isLanded {
                StatusBadge(text: "Landed at \(context.attributes.arrivalIcao)",
                            color: InflightLA.success)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(InflightLA.textSecond)
                    Text(timerInterval: Date()...context.state.currentETA,
                         pauseTime: nil,
                         countsDown: true,
                         showsHours: false)
                        .font(InflightLA.timeFont.monospacedDigit())
                        .foregroundColor(InflightLA.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("left")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(InflightLA.textSecond)
                }
                .layoutPriority(1)

                DistancePill(nm: context.state.distanceToDestinationNm)
            }
        }
    }
}

@available(iOS 16.1, *)
struct PhaseChip: View {
    let phase: FlightPhase
    let progressPct: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: phase.icon)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .foregroundColor(phase.color)
            Text(phase.label.uppercased())
                .font(InflightLA.phaseFont)
                .foregroundColor(phase.color)
                .tracking(0.4)
                .lineLimit(1)
            if !compact && phase != .landed && phase != .preflight {
                Text("\(progressPct)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(InflightLA.text)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(phase.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(phase.color.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

@available(iOS 16.1, *)
private struct DistancePill: View {
    let nm: Double
    var body: some View {
        Text("\(Int(max(0, nm))) NM")
            .font(InflightLA.badgeFont.monospacedDigit())
            .foregroundColor(InflightLA.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(InflightLA.accentSoft, in: Capsule())
            .overlay(Capsule().stroke(InflightLA.stroke, lineWidth: 0.5))
            .fixedSize()
    }
}

// =============================================================================
// MARK: - Dynamic Island route row (compact)
// =============================================================================

@available(iOS 16.1, *)
private struct DIRouteRow: View {
    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.departureIcao)
                    .font(InflightLA.icaoFontDI)
                    .foregroundColor(InflightLA.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(context.attributes.arrivalIcao)
                    .font(InflightLA.icaoFontDI)
                    .foregroundColor(InflightLA.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ProgressTrack(progress: flightProgress(context),
                          isLanded: context.state.isLanded)
        }
    }
}

// =============================================================================
// MARK: - Progress track with plane glyph and dashed future trail
// =============================================================================

/// A 4pt rounded track with a plane glyph riding along it. Filled portion uses
/// a gradient + soft glow so the route reads as "this much done, this much
/// to go" without any extra text labels.
@available(iOS 16.1, *)
struct ProgressTrack: View {
    let progress: Double
    let isLanded: Bool

    private let trackHeight: CGFloat = 4
    private let glyphBox: CGFloat = 20
    private let viewHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(progress, 0), 1)
            let filled = max(glyphBox / 2, w * p)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(InflightLA.trackBg)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(LinearGradient(
                        colors: [InflightLA.accent.opacity(0.7), InflightLA.accent],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: filled, height: trackHeight)

                glyph
                    .frame(width: glyphBox, height: glyphBox)
                    .offset(x: max(0, min(w - glyphBox, w * p - glyphBox / 2)))
            }
            .frame(height: viewHeight, alignment: .center)
        }
        .frame(height: viewHeight)
    }

    @ViewBuilder
    private var glyph: some View {
        if isLanded {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(InflightLA.success)
        } else {
            Image(systemName: "airplane")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(InflightLA.text)
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
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
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
                    .lineLimit(1)
                    .fixedSize()
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
