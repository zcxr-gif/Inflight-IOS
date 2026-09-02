import SwiftUI
import UIKit
import WidgetKit

/// A virtual airline on the home screen: its mark, how much of it is in the
/// air, and what those aeroplanes are doing.
///
/// The VA is chosen in the app — "Pin to home screen" on the VA's own panel —
/// rather than configured on the tile, for the same reason the flight and
/// airport tiles work that way: the thing you want on your home screen is the
/// thing you were just looking at, and a configuration sheet asking you to
/// pick a VA out of a directory you have already been reading is a worse way
/// to get there.
struct VaWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InflightVaWidget", provider: VaProvider()) { entry in
            VaWidgetView(entry: entry)
        }
        .configurationDisplayName("Virtual airline")
        .description("Who is flying for the VA you pinned, and where they are going.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct VaEntry: TimelineEntry {
    let date: Date
    let va: WidgetVa?
    let capturedAt: Date
}

struct VaProvider: TimelineProvider {

    func placeholder(in context: Context) -> VaEntry {
        preview()
    }

    func getSnapshot(in context: Context, completion: @escaping (VaEntry) -> Void) {
        completion(context.isPreview ? preview() : load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VaEntry>) -> Void) {
        let now = Date()
        // One entry, for the airport tile's reason: a count of who is airborne
        // cannot be projected forward. An aeroplane either landed or it didn't,
        // and redrawing the same number under a later timestamp would be
        // inventing data. The tile reports its own age instead.
        completion(Timeline(entries: [load(at: now)], policy: .after(now.addingTimeInterval(20 * 60))))
    }

    private func load(at date: Date) -> VaEntry {
        let snapshot = SharedStore.loadSnapshot()
        return VaEntry(date: date, va: snapshot.va, capturedAt: snapshot.updatedAt)
    }

    private func preview() -> VaEntry {
        VaEntry(date: Date(), va: WidgetSnapshot.preview.va, capturedAt: Date())
    }
}

struct VaWidgetView: View {

    let entry: VaEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessory
            } else {
                home
            }
        }
    }

    // MARK: - Home screen

    @ViewBuilder
    private var home: some View {
        content
            .containerBackground(for: .widget) {
                // Deliberately the drawn sky and never the VA's own logo
                // stretched behind the text. A logo is a mark — it is drawn at
                // the size it was made for, with its own edges — and blown up
                // as wallpaper it is a blurred rectangle that makes the tile
                // look broken rather than branded.
                PlaneBackdrop(
                    photoKey: "",
                    style: family == .systemSmall ? .dense : .framed,
                    altitudeFt: 35_000
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if let va = entry.va {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
                header(va)

                counts(va)

                if family != .systemSmall, !va.fleet.isEmpty {
                    Divider().overlay(WidgetPalette.track)
                    fleet(va)
                }

                Spacer(minLength: 0)

                footer(va)
            }
        } else {
            unpinned
        }
    }

    private func header(_ va: WidgetVa) -> some View {
        HStack(spacing: 8) {
            mark(va, side: family == .systemSmall ? 22 : 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(va.name)
                    .font(WidgetType.title(family == .systemSmall ? 13 : 15))
                    .foregroundStyle(WidgetPalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Says what kind of airline this is, every time, for the same
                // reason the flight window's partner line does: a VA named
                // after a real airline is otherwise read as that airline.
                Text(va.callsign.isEmpty ? "VIRTUAL AIRLINE" : "VA · \(va.callsign.uppercased())")
                    .font(WidgetType.caption(8.5))
                    .foregroundStyle(WidgetPalette.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 4)
        }
    }

    /// The VA's own logo, or its initials until the app has cached one.
    private func mark(_ va: WidgetVa, side: CGFloat) -> some View {
        Group {
            if va.hasLogo, let image = SharedStore.photo(for: va.photoKey) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.08)
            } else {
                Text(va.monogram)
                    .font(.system(size: side * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.text)
            }
        }
        .frame(width: side, height: side)
        .background {
            RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                .fill(Color.white.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                .strokeBorder(WidgetPalette.track, lineWidth: 0.8)
        }
    }

    private func counts(_ va: WidgetVa) -> some View {
        HStack(spacing: family == .systemSmall ? 10 : 16) {
            count("FLYING", va.airborneCount)
            count("ON STAND", max(va.totalCount - va.airborneCount, 0))

            if family != .systemSmall, !va.hubs.isEmpty {
                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(va.hubs.prefix(3).joined(separator: " · "))
                        .font(WidgetType.readout(11))
                        .foregroundStyle(WidgetPalette.text)
                        .lineLimit(1)
                    Text(va.hubs.count == 1 ? "HUB" : "HUBS")
                        .font(WidgetType.caption(8.5))
                        .foregroundStyle(WidgetPalette.dim)
                }
                .fixedSize()
            }
        }
    }

    private func count(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(WidgetType.readout(family == .systemSmall ? 15 : 18))
                .foregroundStyle(WidgetPalette.text)
            Text(label)
                .font(WidgetType.caption(family == .systemSmall ? 8 : 9))
                .foregroundStyle(WidgetPalette.dim)
        }
    }

    /// Each aeroplane is its own link, so a tap on a row opens that aircraft
    /// rather than the VA it belongs to — the same bargain the airport tile's
    /// arrivals make.
    private func fleet(_ va: WidgetVa) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(va.fleet.prefix(fleetLimit)) { movement in
                Link(destination: InflightLink.flight(id: movement.id).url ?? fallbackURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "airplane")
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

    private var fleetLimit: Int {
        family == .systemLarge ? 6 : 2
    }

    @ViewBuilder
    private func footer(_ va: WidgetVa) -> some View {
        if va.totalCount == 0 {
            Text("Nobody flying right now.")
                .font(WidgetType.caption(9.5))
                .foregroundStyle(WidgetPalette.dim)
        } else if let stale = WidgetFormat.staleness(since: entry.capturedAt, now: entry.date) {
            Text(stale)
                .font(WidgetType.caption(9))
                .foregroundStyle(WidgetPalette.dim)
        }
    }

    private var unpinned: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(WidgetPalette.dim)

            Text("No VA pinned")
                .font(WidgetType.title(14))
                .foregroundStyle(WidgetPalette.text)

            Text("Open a virtual airline in Inflight and pin it to watch its fleet from here.")
                .font(WidgetType.caption(10))
                .foregroundStyle(WidgetPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Lock screen

    @ViewBuilder
    private var accessory: some View {
        if let va = entry.va {
            VStack(alignment: .leading, spacing: 1) {
                Text(va.name)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("\(va.airborneCount) flying · \(max(va.totalCount - va.airborneCount, 0)) on stand")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            Text("No VA pinned")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .containerBackground(for: .widget) { Color.clear }
        }
    }

    /// Only reachable if `URLComponents` failed to build a URL from a string
    /// we control, which it does not.
    private var fallbackURL: URL {
        URL(string: "\(InflightLink.scheme)://open") ?? URL(fileURLWithPath: "/")
    }
}
