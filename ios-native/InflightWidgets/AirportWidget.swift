import SwiftUI
import WidgetKit

/// A field on the home screen: who is controlling it, what is on the way in,
/// and what is sitting on it.
///
/// The field is chosen in the app — the airport panel's "Pin to home screen" —
/// rather than configured on the tile, for the same reason the flight tile
/// works that way: the thing you want on your home screen is the thing you were
/// just looking at, and a configuration sheet asking you to type an ICAO you
/// have already typed once is a worse way to get there.
struct AirportWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InflightAirportWidget", provider: AirportProvider()) { entry in
            AirportWidgetView(entry: entry)
        }
        .configurationDisplayName("Airport")
        .description("Traffic, ATC and weather at the field you pinned.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct AirportEntry: TimelineEntry {
    let date: Date
    let airport: WidgetAirport?
    let capturedAt: Date
}

struct AirportProvider: TimelineProvider {

    func placeholder(in context: Context) -> AirportEntry {
        preview()
    }

    func getSnapshot(in context: Context, completion: @escaping (AirportEntry) -> Void) {
        completion(context.isPreview ? preview() : load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirportEntry>) -> Void) {
        let now = Date()
        // Only one entry, unlike the flight tiles. Those can project an
        // aircraft's position forward and stay honest; a field's traffic counts
        // cannot be extrapolated at all — an arrival either landed or didn't —
        // so drawing the same numbers under later timestamps would be inventing
        // data. The tile reports its age instead and asks to be refreshed.
        completion(Timeline(entries: [load(at: now)], policy: .after(now.addingTimeInterval(20 * 60))))
    }

    private func load(at date: Date) -> AirportEntry {
        let snapshot = SharedStore.loadSnapshot()
        return AirportEntry(date: date, airport: snapshot.airport, capturedAt: snapshot.updatedAt)
    }

    private func preview() -> AirportEntry {
        AirportEntry(
            date: Date(),
            airport: WidgetSnapshot.preview.airport,
            capturedAt: Date()
        )
    }
}

struct AirportWidgetView: View {

    let entry: AirportEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessory
            } else {
                home
            }
        }
        // The whole tile is one target: a field is a single destination, and
        // the rows on it are aircraft, which get their own links below.
        .widgetURL(entry.airport.flatMap { InflightLink.airport(icao: $0.icao).url })
    }

    // MARK: - Home screen

    @ViewBuilder
    private var home: some View {
        content
            .containerBackground(for: .widget) {
                // A field has no aircraft of its own to be photographed, so the
                // backdrop is the drawn sky at ground level rather than a photo
                // that would belong to whichever aircraft happened to be first.
                PlaneBackdrop(
                    photoKey: "",
                    style: family == .systemSmall ? .dense : .framed,
                    altitudeFt: 0
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if let airport = entry.airport {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
                header(airport)

                if family == .systemSmall {
                    counts(airport, compact: true)
                } else {
                    counts(airport, compact: false)

                    if !airport.arrivals.isEmpty {
                        Divider().overlay(WidgetPalette.track)
                        arrivals(airport)
                    }
                }

                Spacer(minLength: 0)

                if let stale = WidgetFormat.staleness(since: entry.capturedAt, now: entry.date) {
                    Text(stale)
                        .font(WidgetType.caption(9))
                        .foregroundStyle(WidgetPalette.dim)
                }
            }
        } else {
            unpinned
        }
    }

    private func header(_ airport: WidgetAirport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(airport.icao)
                .font(WidgetType.icao(family == .systemSmall ? 22 : 26))
                .foregroundStyle(WidgetPalette.text)

            if !airport.flag.isEmpty {
                Text(airport.flag)
                    .font(.system(size: family == .systemSmall ? 13 : 15))
            }

            Spacer(minLength: 4)

            // Controlled fields are the interesting ones, so the positions are
            // spelled out where there is room and marked with a dot where there
            // isn't. An uncontrolled field says nothing at all rather than
            // carrying a row that reads "no ATC" at almost every airport in the
            // world.
            if airport.isControlled {
                if family == .systemSmall {
                    Circle()
                        .fill(WidgetPalette.success)
                        .frame(width: 7, height: 7)
                } else {
                    Text(airport.atcPositions.joined(separator: " · "))
                        .font(WidgetType.label(10))
                        .foregroundStyle(WidgetPalette.success)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    @ViewBuilder
    private func counts(_ airport: WidgetAirport, compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            count("IN", airport.inboundCount, compact: compact)
            count("OUT", airport.departedCount, compact: compact)
            count("APRON", airport.onGroundCount, compact: compact)

            if !compact, let conditions = airport.conditions {
                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 1) {
                    if let temperature = airport.temperature {
                        Text(temperature)
                            .font(WidgetType.readout(15))
                            .foregroundStyle(WidgetPalette.text)
                    }
                    Text(conditions)
                        .font(WidgetType.caption(9.5))
                        .foregroundStyle(WidgetPalette.dim)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
    }

    private func count(_ label: String, _ value: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(WidgetType.readout(compact ? 15 : 18))
                .foregroundStyle(WidgetPalette.text)
            Text(label)
                .font(WidgetType.caption(compact ? 8 : 9))
                .foregroundStyle(WidgetPalette.dim)
        }
    }

    /// Each arrival is its own link, so a tap on a row opens that aircraft
    /// rather than the field it happens to be heading for.
    private func arrivals(_ airport: WidgetAirport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(airport.arrivals.prefix(arrivalLimit)) { movement in
                Link(destination: InflightLink.flight(id: movement.id).url ?? fallbackURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.arrival")
                            .font(.system(size: 9.5))
                            .foregroundStyle(WidgetPalette.dim)

                        Text(movement.callsign)
                            .font(WidgetType.title(12))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(movement.detail)
                            .font(WidgetType.readout(11))
                            .foregroundStyle(WidgetPalette.secondary)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var arrivalLimit: Int {
        family == .systemLarge ? 6 : 2
    }

    private var unpinned: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(WidgetPalette.dim)

            Text("No field pinned")
                .font(WidgetType.title(14))
                .foregroundStyle(WidgetPalette.text)

            Text("Open an airport in Inflight and pin it to watch it from here.")
                .font(WidgetType.caption(10))
                .foregroundStyle(WidgetPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Lock screen

    @ViewBuilder
    private var accessory: some View {
        if let airport = entry.airport {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(airport.icao)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                    if airport.isControlled {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9))
                    }
                }

                Text("\(airport.inboundCount) in · \(airport.departedCount) out · \(airport.onGroundCount) apron")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            Text("No field pinned")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .containerBackground(for: .widget) { Color.clear }
        }
    }

    /// Only reachable if `URLComponents` failed to build a URL from a string we
    /// control, which it will not — `Link` simply requires something non-nil.
    private var fallbackURL: URL {
        URL(string: "\(InflightLink.scheme)://open") ?? URL(fileURLWithPath: "/")
    }
}
