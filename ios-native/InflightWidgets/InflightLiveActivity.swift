import ActivityKit
import SwiftUI
import WidgetKit

/// The live banner: lock screen, Dynamic Island, and the thing a watched
/// pilot's takeoff raises on a phone nobody is holding.
///
/// Descended from the Capacitor build's widget, with two changes that matter.
/// The lock screen now draws on the aircraft's own photo rather than a flat
/// tint, because at 3am on a lock screen a real 777 is the difference between
/// a notification and a thing worth looking at. And the header says *whose*
/// flight it is when the backend started it — an activity that appears
/// unbidden has to explain itself, or it reads as the app doing something odd.
///
/// The progress logic is kept from the original because it solves a problem
/// that hasn't gone away: an activity can sit on a lock screen for hours
/// between pushes, so the aircraft is advanced on the clock as well as on the
/// last pushed distance, and whichever is further along wins. That keeps the
/// marker moving through a push gap, and guarantees it never appears to go
/// backwards when a fresh distance lands.
struct InflightLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InflightActivityAttributes.self) { context in
            LiveActivityLockScreen(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "airplane")
                                .font(.system(size: 13, weight: .semibold))
                            Text(context.attributes.callsign)
                                .font(WidgetType.title(15))
                                .flightInfoWidgetLine()
                        }
                        .foregroundStyle(WidgetPalette.text)

                        if !context.attributes.aircraftDescriptor.isEmpty {
                            Text(context.attributes.aircraftDescriptor)
                                .font(WidgetType.caption(11))
                                .foregroundStyle(WidgetPalette.secondary)
                                .flightInfoWidgetLine()
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ETAReadout(context: context, size: 13)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    RouteStrip(
                        departure: context.attributes.departureIcao,
                        arrival: context.attributes.arrivalIcao,
                        progress: LiveProgress.fraction(context),
                        isLanded: context.state.isLanded,
                        icaoSize: 19
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(WidgetFormat.number(LiveProgress.remainingNm(context))) NM remaining")
                            .font(WidgetType.readout(13))
                            .foregroundStyle(WidgetPalette.secondary)
                        Spacer()
                        if context.state.isLanded {
                            StatusBadge(text: "Landed", colour: WidgetPalette.success)
                        } else if context.state.altitudeFt > 0 {
                            Text("\(WidgetFormat.number(Double(context.state.altitudeFt))) ft")
                                .font(WidgetType.readout(13))
                                .foregroundStyle(WidgetPalette.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.text)
            } compactTrailing: {
                if context.state.isLanded {
                    Text("Landed")
                        .font(WidgetType.readout(13))
                        .foregroundStyle(WidgetPalette.success)
                        .frame(maxWidth: 60)
                } else if let countdown = LiveProgress.countdown(context) {
                    Text(timerInterval: countdown, pauseTime: nil, countsDown: true, showsHours: true)
                        .font(WidgetType.readout(13))
                        .foregroundStyle(WidgetPalette.text)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                } else {
                    Text("Due")
                        .font(WidgetType.readout(13))
                        .foregroundStyle(WidgetPalette.text)
                        .frame(maxWidth: 60)
                }
            } minimal: {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.text)
            }
            .keylineTint(.white)
        }
    }
}

// MARK: - Lock screen

struct LiveActivityLockScreen: View {

    let context: ActivityViewContext<InflightActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            RouteStrip(
                departure: context.attributes.departureIcao,
                arrival: context.attributes.arrivalIcao,
                progress: LiveProgress.fraction(context),
                isLanded: context.state.isLanded,
                icaoSize: 26
            )

            HStack(alignment: .top) {
                TimeBlock(
                    scheduled: context.attributes.scheduledDeparture,
                    actual: context.state.currentATD,
                    alignment: .leading
                )
                Spacer(minLength: 8)
                TimeBlock(
                    scheduled: context.attributes.scheduledArrival,
                    actual: context.state.currentETA,
                    alignment: .trailing
                )
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            PlaneBackdrop(
                photoKey: context.attributes.photoKey,
                style: .banner,
                altitudeFt: context.state.altitudeFt
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(context.attributes.callsign)
                        .font(WidgetType.title(14))
                        .foregroundStyle(WidgetPalette.text)
                        .flightInfoWidgetLine()

                    if !context.attributes.registration.isEmpty {
                        Text(context.attributes.registration)
                            .font(WidgetType.caption(11))
                            .foregroundStyle(WidgetPalette.dim)
                    }
                }

                // An activity the backend raised has to say whose flight it
                // is — it appeared without anybody asking for it.
                Text(subtitle)
                    .font(WidgetType.caption(11))
                    .foregroundStyle(WidgetPalette.secondary)
                    .flightInfoWidgetLine()
            }

            Spacer(minLength: 8)
            Wordmark(size: 11)
        }
    }

    private var subtitle: String {
        let pilot = context.attributes.pilotUsername.trimmingCharacters(in: .whitespaces)
        let aircraft = context.attributes.aircraftDescriptor
        if !pilot.isEmpty {
            return aircraft.isEmpty ? pilot : "\(pilot) · \(aircraft)"
        }
        return aircraft
    }

    private var footer: some View {
        HStack(alignment: .center) {
            if context.state.isLanded {
                StatusBadge(
                    text: "Landed at \(context.attributes.arrivalIcao)",
                    colour: WidgetPalette.success
                )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WidgetPalette.dim)
                    Text("\(WidgetFormat.number(LiveProgress.remainingNm(context))) NM")
                        .font(WidgetType.readout(13))
                        .foregroundStyle(WidgetPalette.secondary)

                    if context.state.groundSpeedKt > 0 {
                        Text("· \(context.state.groundSpeedKt) kts")
                            .font(WidgetType.readout(13))
                            .foregroundStyle(WidgetPalette.dim)
                    }
                }
            }

            Spacer(minLength: 8)
            ETAReadout(context: context, size: 13)
        }
    }
}

// MARK: - Progress

/// Where the aircraft is along its route, and how far it has left.
///
/// Two independent estimates, and the further along wins:
///
///   * distance — `(total - remaining) / total`, exact the instant a push
///     lands.
///   * time — elapsed over the whole planned span, re-evaluated against the
///     clock every time the system re-renders.
///
/// Taking the maximum means the aircraft keeps advancing on the clock through
/// a push gap and snaps forward when a fresh distance arrives, and it can
/// never appear to move backwards. Because the time term is anchored to the
/// same ETA the countdown uses, the marker stays in step with the numbers
/// beside it.
enum LiveProgress {

    static func fraction(_ context: ActivityViewContext<InflightActivityAttributes>) -> Double? {
        if context.state.isLanded { return 1 }

        let total = context.attributes.totalDistanceNm
        // No resolvable route: no progress claim at all, rather than a bar
        // pinned at zero that reads as "hasn't departed".
        guard total > 1 else { return nil }

        let remaining = max(0, context.state.distanceToDestinationNm)
        let byDistance = min(max((total - remaining) / total, 0), 1)

        var byTime = 0.0
        let departure = context.state.currentATD ?? context.attributes.scheduledDeparture
        let span = context.state.currentETA.timeIntervalSince(departure)
        if span > 0 {
            byTime = min(max(Date().timeIntervalSince(departure) / span, 0), 1)
        }

        return min(max(max(byDistance, byTime), 0), 1)
    }

    /// Distance to run, for display. A recent push is trusted outright; once
    /// it is stale the figure is derived from time progress instead, so the
    /// readout keeps counting down rather than freezing on a number that is
    /// visibly wrong next to a moving aircraft. It never exceeds the last
    /// known distance — on a normal arrival the aircraft only gets closer.
    /// The range a countdown may run over, or nil when the arrival time has
    /// already gone by.
    ///
    /// `Text(timerInterval:)` traps on a range whose upper bound is below its
    /// lower bound, and an ETA in the past is not an edge case — it is what a
    /// flight that is running late, or one whose last push was an hour ago,
    /// looks like. Anything building a countdown goes through here.
    static func countdown(_ context: ActivityViewContext<InflightActivityAttributes>) -> ClosedRange<Date>? {
        let now = Date()
        let eta = context.state.currentETA
        guard eta > now else { return nil }
        return now...eta
    }

    static func remainingNm(_ context: ActivityViewContext<InflightActivityAttributes>) -> Double {
        if context.state.isLanded { return 0 }

        let pushed = max(0, context.state.distanceToDestinationNm)
        let total = context.attributes.totalDistanceNm
        let age = Date().timeIntervalSince(context.state.lastUpdated)
        if age < 120 || total <= 1 { return pushed.rounded() }

        let derived = total * (1 - (fraction(context) ?? 0))
        return min(pushed, max(0, derived)).rounded()
    }
}

// MARK: - Pieces

/// Scheduled time, with the estimate under it only when the two differ.
/// Printing the same time twice is noise.
struct TimeBlock: View {

    let scheduled: Date
    let actual: Date?
    let alignment: HorizontalAlignment

    var body: some View {
        let driftMinutes = actual.map { Int($0.timeIntervalSince(scheduled) / 60) } ?? 0
        let estimated = (actual != nil && abs(driftMinutes) >= 1) ? actual : nil

        VStack(alignment: alignment, spacing: 2) {
            Text(WidgetFormat.clock(scheduled))
                .font(WidgetType.readout(15))
                .foregroundStyle(WidgetPalette.text)

            if let estimated = estimated {
                HStack(spacing: 3) {
                    Text("Estimated")
                        .font(WidgetType.caption(10))
                        .foregroundStyle(WidgetPalette.dim)
                    Text(WidgetFormat.clock(estimated))
                        .font(WidgetType.readout(10.5))
                        // Late is worth flagging; early or on time is not
                        // worth colouring at all.
                        .foregroundStyle(driftMinutes > 0 ? WidgetPalette.text : WidgetPalette.success)
                }
            }
        }
    }
}

struct StatusBadge: View {

    let text: String
    let colour: Color

    var body: some View {
        Text(text)
            .font(WidgetType.readout(12.5))
            .foregroundStyle(colour)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(colour.opacity(0.18), in: Capsule())
            .overlay { Capsule().strokeBorder(colour.opacity(0.38), lineWidth: 0.5) }
    }
}

struct ETAReadout: View {

    let context: ActivityViewContext<InflightActivityAttributes>
    var size: CGFloat = 13

    var body: some View {
        if context.state.isLanded {
            StatusBadge(text: "Landed", colour: WidgetPalette.success)
        } else if let countdown = LiveProgress.countdown(context) {
            HStack(spacing: 4) {
                Text(timerInterval: countdown, pauseTime: nil, countsDown: true, showsHours: true)
                    .font(WidgetType.readout(size))
                    .foregroundStyle(WidgetPalette.text)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: size * 4.9, alignment: .trailing)
                Text("left")
                    .font(WidgetType.caption(size * 0.85))
                    .foregroundStyle(WidgetPalette.secondary)
            }
        } else {
            // Past its estimate and not yet reported down. Saying "arriving"
            // is honest; a countdown that has run out and sits at 0:00 reads
            // as a stuck widget.
            Text("Arriving")
                .font(WidgetType.readout(size))
                .foregroundStyle(WidgetPalette.text)
        }
    }
}
