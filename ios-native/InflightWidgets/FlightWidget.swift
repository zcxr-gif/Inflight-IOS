import SwiftUI
import WidgetKit

/// One flight on the home screen, drawn on its own aircraft.
///
/// The flight is whichever one was pinned from its window in the app; with
/// nothing pinned it falls back to the friend furthest along their route,
/// which means the tile is useful before anyone has discovered pinning.
struct FlightWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InflightFlightWidget", provider: FlightProvider()) { entry in
            FlightWidgetView(entry: entry)
        }
        .configurationDisplayName("Flight")
        .description("A flight you've pinned, on a photo of the aircraft flying it.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline
        ])
    }
}

struct FlightEntry: TimelineEntry {
    let date: Date
    let flight: WidgetFlight?
    /// True once the reading has been carried forward rather than read fresh,
    /// so the view can say so.
    let isExtrapolated: Bool
}

struct FlightProvider: TimelineProvider {

    func placeholder(in context: Context) -> FlightEntry {
        FlightEntry(date: Date(), flight: WidgetSnapshot.preview.pinned, isExtrapolated: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (FlightEntry) -> Void) {
        // The gallery preview gets the sample flight rather than an empty
        // tile: a blank rectangle in the widget picker doesn't get chosen.
        let flight = context.isPreview ? WidgetSnapshot.preview.pinned : subject()
        completion(FlightEntry(date: Date(), flight: flight, isExtrapolated: false))
    }

    /// A run of entries carrying the aircraft forward on its own speed.
    ///
    /// Cheaper and steadier than asking to be woken often: WidgetKit budgets
    /// refreshes per day, so a tile that wants to stay alive for an hour is
    /// better off being handed an hour of pre-computed positions than asking
    /// for twelve reloads it may not get.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FlightEntry>) -> Void) {
        guard let flight = subject() else {
            let entry = FlightEntry(date: Date(), flight: nil, isExtrapolated: false)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
            return
        }

        let now = Date()
        let step: TimeInterval = 10 * 60
        let entries: [FlightEntry] = stride(from: 0, through: 60 * 60, by: step).map { offset in
            let at = now.addingTimeInterval(offset)
            return FlightEntry(
                date: at,
                flight: flight.advanced(to: at),
                // Everything past the first entry is a projection, and so is
                // the first one when the app hasn't run in a while.
                isExtrapolated: offset > 0 || at.timeIntervalSince(flight.capturedAt) > 12 * 60
            )
        }

        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(45 * 60))))
    }

    /// The pinned flight, or the friend closest to arriving.
    private func subject() -> WidgetFlight? {
        let snapshot = SharedStore.loadSnapshot()
        if let pinned = snapshot.pinned { return pinned }
        return snapshot.friends.first { $0.isAirborne } ?? snapshot.friends.first
    }
}

struct FlightWidgetView: View {

    let entry: FlightEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            // One aircraft, one destination. A tile with nothing pinned falls
            // back to opening the app, which is what a tap on it should do.
            .widgetURL(entry.flight.map { InflightLink.flight(id: $0.id).url } ?? nil)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular, .accessoryInline:
            // Lock-screen accessories are rendered monochrome by the system,
            // so a photo would come back as grey mush. They get type only.
            AccessoryFlightView(entry: entry, family: family)
        default:
            HomeFlightView(entry: entry, family: family)
                .containerBackground(for: .widget) {
                    PlaneBackdrop(
                        photoKey: entry.flight?.photoKey ?? "",
                        style: family == .systemSmall ? .dense : .framed,
                        altitudeFt: entry.flight?.altitudeFt ?? 0
                    )
                }
        }
    }
}

// MARK: - Home screen

private struct HomeFlightView: View {

    let entry: FlightEntry
    let family: WidgetFamily

    var body: some View {
        if let flight = entry.flight {
            switch family {
            case .systemSmall: small(flight)
            case .systemLarge: large(flight)
            default: medium(flight)
            }
        } else {
            EmptyFlightView()
        }
    }

    // MARK: Small

    /// 155 points square, most of which the text has to have. The photo is
    /// atmosphere here rather than subject, which is what `.dense` is for.
    private func small(_ flight: WidgetFlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(flight.callsign)
                    .font(WidgetType.title(13))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine()
                Spacer(minLength: 4)
                Image(systemName: flight.phaseSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WidgetPalette.secondary)
            }

            Spacer(minLength: 6)

            RouteStrip(
                departure: flight.departureIcao,
                arrival: flight.arrivalIcao,
                progress: flight.progress,
                isLanded: !flight.isAirborne && (flight.progress ?? 0) > 0.9,
                icaoSize: 17
            )

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 1) {
                countdown(flight, size: 14)
                Text(footnote(flight))
                    .font(WidgetType.caption(9))
                    .foregroundStyle(WidgetPalette.dim)
                    .flightInfoWidgetLine()
            }
        }
    }

    // MARK: Medium

    private func medium(_ flight: WidgetFlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(flight.callsign)
                        .font(WidgetType.title(15))
                        .foregroundStyle(WidgetPalette.text)
                        .flightInfoWidgetLine()
                    Text(descriptor(flight))
                        .font(WidgetType.caption(10))
                        .foregroundStyle(WidgetPalette.secondary)
                        .flightInfoWidgetLine()
                }
                Spacer(minLength: 6)
                PhaseChip(symbol: flight.phaseSymbol, text: flight.phaseLabel)
            }

            Spacer(minLength: 8)

            RouteStrip(
                departure: flight.departureIcao,
                arrival: flight.arrivalIcao,
                progress: flight.progress,
                isLanded: !flight.isAirborne && (flight.progress ?? 0) > 0.9,
                icaoSize: 26
            )

            Spacer(minLength: 8)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    countdown(flight, size: 15)
                    Text(footnote(flight))
                        .font(WidgetType.caption(9.5))
                        .foregroundStyle(WidgetPalette.dim)
                        .flightInfoWidgetLine()
                }
                Spacer(minLength: 8)
                Wordmark()
            }
        }
    }

    // MARK: Large

    /// The one size with room to let the photograph be a photograph, so the
    /// middle is left alone and everything is pushed to the two ends.
    private func large(_ flight: WidgetFlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.callsign)
                        .font(WidgetType.title(19))
                        .foregroundStyle(WidgetPalette.text)
                        .flightInfoWidgetLine()
                    Text(descriptor(flight))
                        .font(WidgetType.caption(12))
                        .foregroundStyle(WidgetPalette.secondary)
                        .flightInfoWidgetLine()
                }
                Spacer(minLength: 6)
                PhaseChip(symbol: flight.phaseSymbol, text: flight.phaseLabel, size: 11)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 14) {
                RouteStrip(
                    departure: flight.departureIcao,
                    arrival: flight.arrivalIcao,
                    progress: flight.progress,
                    isLanded: !flight.isAirborne && (flight.progress ?? 0) > 0.9,
                    icaoSize: 34
                )

                HStack(alignment: .bottom, spacing: 0) {
                    WidgetStat(
                        value: flight.totalNM > 1 ? "\(WidgetFormat.number(flight.remainingNM)) NM" : "—",
                        label: "TO RUN",
                        valueSize: 15
                    )
                    Spacer(minLength: 6)
                    WidgetStat(
                        value: "\(WidgetFormat.number(Double(flight.altitudeFt))) FT",
                        label: "ALTITUDE",
                        alignment: .center,
                        valueSize: 15
                    )
                    Spacer(minLength: 6)
                    WidgetStat(
                        value: "\(flight.groundSpeedKt) KTS",
                        label: "GROUND SPEED",
                        alignment: .trailing,
                        valueSize: 15
                    )
                }

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        countdown(flight, size: 19)
                        Text(footnote(flight))
                            .font(WidgetType.caption(11))
                            .foregroundStyle(WidgetPalette.dim)
                            .flightInfoWidgetLine()
                    }
                    Spacer(minLength: 8)
                    Wordmark(size: 11)
                }
            }
        }
    }

    // MARK: Pieces

    /// A live countdown rather than a rendered duration.
    ///
    /// `Text(timerInterval:)` is re-rendered by the system every minute
    /// without costing a timeline entry, which is the only way a tile ticks
    /// down without spending the refresh budget it needs for real updates.
    @ViewBuilder
    private func countdown(_ flight: WidgetFlight, size: CGFloat) -> some View {
        if let eta = flight.eta, eta > entry.date, flight.isAirborne {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timerInterval: entry.date...eta, pauseTime: nil, countsDown: true, showsHours: true)
                    .font(WidgetType.readout(size))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine()
                    .frame(maxWidth: size * 5, alignment: .leading)
                Text("left")
                    .font(WidgetType.caption(size * 0.62))
                    .foregroundStyle(WidgetPalette.secondary)
            }
        } else {
            Text(flight.isAirborne ? "Arriving" : flight.phaseLabel)
                .font(WidgetType.readout(size))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()
        }
    }

    private func descriptor(_ flight: WidgetFlight) -> String {
        var parts: [String] = []
        if !flight.aircraftType.isEmpty { parts.append(flight.aircraftType) }
        if !flight.liveryName.isEmpty,
           flight.liveryName.caseInsensitiveCompare(flight.aircraftType) != .orderedSame {
            parts.append(flight.liveryName)
        }
        if parts.isEmpty, !flight.username.isEmpty { parts.append(flight.username) }
        return parts.joined(separator: " · ")
    }

    /// Distance to run normally; how old the reading is once it has been
    /// projected far enough that saying nothing would be misleading.
    private func footnote(_ flight: WidgetFlight) -> String {
        if let stale = WidgetFormat.staleness(since: flight.capturedAt, now: entry.date) {
            return stale
        }
        guard flight.totalNM > 1 else { return flight.username }
        return "\(WidgetFormat.number(flight.remainingNM)) NM to run"
    }
}

/// Nothing pinned and no friends flying.
private struct EmptyFlightView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "airplane.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(WidgetPalette.secondary)
            Text("Nothing pinned")
                .font(WidgetType.title(14))
                .foregroundStyle(WidgetPalette.text)
            Text("Open a flight in Inflight and tap Pin to keep it here.")
                .font(WidgetType.caption(10))
                .foregroundStyle(WidgetPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lock screen

private struct AccessoryFlightView: View {

    let entry: FlightEntry
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            if let flight = entry.flight {
                Text("\(flight.callsign) \(flight.departureIcao)→\(flight.arrivalIcao)")
            } else {
                Text("Inflight")
            }

        default:
            if let flight = entry.flight {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "airplane")
                            .font(.system(size: 10, weight: .bold))
                        Text(flight.callsign)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .flightInfoWidgetLine()
                    }
                    Text("\(flight.departureIcao) → \(flight.arrivalIcao)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .flightInfoWidgetLine()
                    if let eta = flight.eta, eta > entry.date, flight.isAirborne {
                        Text(timerInterval: entry.date...eta, pauseTime: nil, countsDown: true, showsHours: true)
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    } else {
                        Text(flight.phaseLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .containerBackground(for: .widget) { Color.clear }
            } else {
                Text("Nothing pinned")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .containerBackground(for: .widget) { Color.clear }
            }
        }
    }
}
