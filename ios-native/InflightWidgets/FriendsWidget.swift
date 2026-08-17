import SwiftUI
import WidgetKit

/// Who is flying right now, on a photo of the aircraft at the top of the list.
///
/// The question this answers is the one the friends panel exists for — "is
/// anyone up?" — without unlocking anything. The photo belongs to the leading
/// friend rather than being generic, so the tile changes character with
/// whoever is flying.
struct FriendsWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InflightFriendsWidget", provider: FriendsProvider()) { entry in
            FriendsWidgetView(entry: entry)
        }
        .configurationDisplayName("Friends")
        .description("Which of the pilots you watch are in the air.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular])
    }
}

struct FriendsEntry: TimelineEntry {
    let date: Date
    let friends: [WidgetFlight]
    let friendCount: Int
    let capturedAt: Date
}

struct FriendsProvider: TimelineProvider {

    func placeholder(in context: Context) -> FriendsEntry {
        preview()
    }

    func getSnapshot(in context: Context, completion: @escaping (FriendsEntry) -> Void) {
        completion(context.isPreview ? preview() : load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FriendsEntry>) -> Void) {
        let now = Date()
        // Same reasoning as the flight tile: hand the system a run of
        // projected positions rather than asking to be woken repeatedly.
        let entries = stride(from: 0, through: 60 * 60, by: 15 * 60).map { load(at: now.addingTimeInterval($0)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(45 * 60))))
    }

    private func load(at date: Date) -> FriendsEntry {
        let snapshot = SharedStore.loadSnapshot()
        return FriendsEntry(
            date: date,
            friends: snapshot.friends.map { $0.advanced(to: date) },
            friendCount: snapshot.friendCount,
            capturedAt: snapshot.updatedAt
        )
    }

    private func preview() -> FriendsEntry {
        // `WidgetSnapshot.preview` always carries a flight, but a force
        // unwrap in a widget process is a crash on a home screen — the empty
        // list is a perfectly good gallery preview if it ever came to it.
        let sample = WidgetSnapshot.preview.pinned.map { [$0] } ?? []
        return FriendsEntry(date: Date(), friends: sample, friendCount: 8, capturedAt: Date())
    }
}

struct FriendsWidgetView: View {

    let entry: FriendsEntry

    @Environment(\.widgetFamily) private var family

    /// Only pilots actually in the air. Somebody sitting at a gate is on the
    /// server, not flying, and a tile that counts them reads as wrong the
    /// moment you open the app and see one aircraft moving.
    private var aloft: [WidgetFlight] {
        entry.friends.filter(\.isAirborne)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessory
                .containerBackground(for: .widget) { Color.clear }
        default:
            content
                .containerBackground(for: .widget) {
                    PlaneBackdrop(
                        photoKey: aloft.first?.photoKey ?? entry.friends.first?.photoKey ?? "",
                        style: family == .systemSmall ? .dense : .framed,
                        altitudeFt: aloft.first?.altitudeFt ?? 0
                    )
                }
        }
        // Anywhere that isn't one of the rows opens the list itself.
        .widgetURL(InflightLink.panel("friends").url)
    }

    // MARK: - Home screen

    @ViewBuilder
    private var content: some View {
        if entry.friendCount == 0 {
            emptyList
        } else if aloft.isEmpty {
            nobodyFlying
        } else {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
                header

                ForEach(aloft.prefix(rowLimit)) { friend in
                    // Per-row links rather than one target for the tile: the
                    // whole point of a list of friends is that you are after
                    // one of them.
                    Link(destination: InflightLink.flight(id: friend.id).url ?? FriendsWidgetView.fallbackURL) {
                        FriendTile(friend: friend, now: entry.date, compact: family == .systemSmall)
                    }
                }

                if aloft.count > rowLimit {
                    Text("+\(aloft.count - rowLimit) more")
                        .font(WidgetType.caption(family == .systemSmall ? 9 : 10))
                        .foregroundStyle(WidgetPalette.dim)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// How many friends each family draws.
    ///
    /// Raised across the board. The snapshot used to be truncated to eight
    /// before the tile ever saw it, so "+N more" was counting against a list
    /// that had already been cut — the numbers disagreed with the friends panel
    /// and there was no way to see the rest. The data ceiling is 24 now, and
    /// these are simply how many fit.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemLarge: return 9
        case .systemExtraLarge: return 14
        default: return 4
        }
    }

    /// Only reachable if a URL built from a string we control failed to build,
    /// which it will not — `Link` just needs something non-nil.
    static let fallbackURL = URL(string: "\(InflightLink.scheme)://open")
        ?? URL(fileURLWithPath: "/")

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(aloft.count) flying")
                .font(WidgetType.title(family == .systemSmall ? 14 : 17))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()

            if family != .systemSmall {
                Text("of \(entry.friendCount)")
                    .font(WidgetType.caption(11))
                    .foregroundStyle(WidgetPalette.dim)
            }

            Spacer(minLength: 4)

            if family == .systemLarge { Wordmark(size: 10) }
        }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 0)
            Image(systemName: "person.2")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(WidgetPalette.secondary)
            Text("No friends yet")
                .font(WidgetType.title(14))
                .foregroundStyle(WidgetPalette.text)
            Text("Add pilots in Inflight and they'll show up here when they fly.")
                .font(WidgetType.caption(10))
                .foregroundStyle(WidgetPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nobodyFlying: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("Nobody flying")
                .font(WidgetType.title(family == .systemSmall ? 14 : 17))
                .foregroundStyle(WidgetPalette.text)
            Text(entry.friendCount == 1
                 ? "Your one watched pilot is offline."
                 : "None of your \(entry.friendCount) watched pilots are up.")
                .font(WidgetType.caption(10.5))
                .foregroundStyle(WidgetPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let stale = WidgetFormat.staleness(since: entry.capturedAt, now: entry.date) {
                Text(stale)
                    .font(WidgetType.caption(9.5))
                    .foregroundStyle(WidgetPalette.dim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lock screen

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("\(aloft.count) of \(entry.friendCount) flying")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .flightInfoWidgetLine()
            }
            if let first = aloft.first {
                Text(first.username.isEmpty ? first.callsign : first.username)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .flightInfoWidgetLine()
                Text("\(first.departureIcao) → \(first.arrivalIcao)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .flightInfoWidgetLine()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One friend: who, where from and to, and how far along.
private struct FriendTile: View {

    let friend: WidgetFlight
    let now: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            HStack(spacing: 5) {
                Text(friend.username.isEmpty ? friend.callsign : friend.username)
                    .font(WidgetType.title(compact ? 11 : 12.5))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine()

                Spacer(minLength: 4)

                if let eta = friend.eta, eta > now {
                    Text(timerInterval: now...eta, pauseTime: nil, countsDown: true, showsHours: true)
                        .font(WidgetType.readout(compact ? 10 : 11))
                        .foregroundStyle(WidgetPalette.secondary)
                        .flightInfoWidgetLine()
                        .frame(maxWidth: compact ? 46 : 56, alignment: .trailing)
                } else {
                    Image(systemName: friend.phaseSymbol)
                        .font(.system(size: compact ? 9 : 10, weight: .bold))
                        .foregroundStyle(WidgetPalette.secondary)
                }
            }

            HStack(spacing: 5) {
                Text(friend.routeLabel)
                    .font(WidgetType.caption(compact ? 9 : 10))
                    .foregroundStyle(WidgetPalette.dim)
                    .flightInfoWidgetLine()

                if !compact, let progress = friend.progress {
                    // Fixed width, not flexible: a GeometryReader in an HStack
                    // has no intrinsic size and would take the room the route
                    // needs to stay readable.
                    ProgressBar(progress: progress)
                        .frame(width: 34, height: 2.5)
                }
            }
        }
    }
}

/// A hairline of route progress. Only on the roomier families — at small size
/// it is two pixels of noise under text that is already tight.
private struct ProgressBar: View {

    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.track)
                Capsule()
                    .fill(WidgetPalette.text)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
    }
}
