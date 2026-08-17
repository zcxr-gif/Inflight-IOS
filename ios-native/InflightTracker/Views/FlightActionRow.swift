import Combine
import SwiftUI

/// The six things you do with a flight once you have found it, as one grid of
/// identical tiles under the identity block.
///
/// Two rows, three across, and the split between them is meaningful. The top
/// row acts on the flight *now* — how long it has been going, where it has
/// been, sending it to somebody. The bottom row outlives the window: watching
/// the pilot survives the flight entirely, and the banner and the home-screen
/// tile go on running with the app closed.
///
/// Every one of them is a `FlightInfoTile`, which is what makes them the same
/// size. They previously weren't: this row drew three tiles that rendered
/// their caption only when they had one, and the watch controls were three
/// capsules of a different shape in a separate view below.
struct FlightActionRow: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// The path we have for this aircraft. Its first dated sample is what makes
    /// the clock possible, and its length is what makes a replay worth
    /// offering — so both tiles are driven by it.
    let track: [TrackPoint]

    let onReplay: () -> Void

    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared
    @ObservedObject private var widgets = WidgetBridge.shared
    @ObservedObject private var push = PushService.shared

    /// The clock tile flips between how long it has been flying and how long
    /// is left. Both are useful, neither is worth its own tile.
    @State private var showsRemaining = false

    /// Ticked once a minute so the elapsed time keeps up without redrawing the
    /// window on every frame.
    @State private var now = Date()

    /// Set when Share is tapped, which is also when the message is composed.
    /// Nothing the feed does while the sheet is open can change it.
    @State private var share: FlightShare?

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var canReplay: Bool { track.count >= FlightReplay.minimumPoints }

    private var pilot: String? {
        guard let username = flight.username, !username.isEmpty else { return nil }
        return username
    }

    private var isWatching: Bool { pilot.map { friends.contains($0) } ?? false }

    private var isBannerRunning: Bool { liveActivity.isTracking(flightId: flight.id) }

    private var isPinned: Bool { widgets.isPinned(flight.id) }

    var body: some View {
        VStack(spacing: FlightInfoLayout.actionTileSpacing) {
            HStack(spacing: FlightInfoLayout.actionTileSpacing) {
                timeTile
                replayTile
                shareTile
            }

            HStack(spacing: FlightInfoLayout.actionTileSpacing) {
                watchTile
                bannerTile
                pinTile
            }
        }
        .onReceive(clock) { now = $0 }
        .sheet(item: $share) { pending in
            ShareSheet(share: pending) { share = nil }
        }
    }

    // MARK: - Now

    /// Filled rather than outlined: of the six this is the one that is also a
    /// readout, so it carries the grid the way the callsign carries the header.
    private var timeTile: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showsRemaining.toggle() }
        } label: {
            FlightInfoTile(
                symbol: showsRemaining ? "flag.pattern.checkered" : "airplane",
                title: showsRemaining ? remainingLabel : elapsedLabel,
                caption: showsRemaining ? "TO RUN" : "ELAPSED",
                isFilled: true,
                theme: theme
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsRemaining ? "Time to run" : "Time elapsed")
        .accessibilityHint("Switches between elapsed and remaining")
    }

    private var replayTile: some View {
        Button(action: onReplay) {
            FlightInfoTile(symbol: "clock.arrow.circlepath", title: "Replay", caption: "TRACK", theme: theme)
        }
        .buttonStyle(.plain)
        // Nothing to play back yet: the backend's history hasn't arrived, or
        // the aircraft has only just started reporting.
        .disabled(!canReplay)
        .opacity(canReplay ? 1 : 0.45)
        .accessibilityLabel("Replay this flight's track")
    }

    private var shareTile: some View {
        Button {
            share = FlightShare(subject: shareSubject, body: shareBody)
        } label: {
            FlightInfoTile(symbol: "square.and.arrow.up", title: "Share", caption: "FLIGHT", theme: theme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share this flight")
    }

    // MARK: - Later

    private var watchTile: some View {
        Button {
            guard let pilot = pilot else { return }
            if friends.contains(pilot) {
                friends.remove(pilot)
            } else {
                friends.add(pilot)
                // The first pilot somebody watches is the moment the
                // permission prompt has something concrete to be about, so it
                // is asked here rather than at launch.
                if push.authorization == .notDetermined { push.requestAuthorization() }
            }
        } label: {
            FlightInfoTile(
                symbol: isWatching ? "person.fill.checkmark" : "person.badge.plus",
                title: isWatching ? "Watching" : "Watch",
                caption: "PILOT",
                isFilled: isWatching,
                theme: theme
            )
        }
        .buttonStyle(.plain)
        // An aircraft with no pilot name attached — rare, but the feed does it
        // — has nobody to watch.
        .disabled(pilot == nil)
        .opacity(pilot == nil ? 0.45 : 1)
        .accessibilityLabel(isWatching ? "Stop watching \(pilot ?? "this pilot")" : "Watch \(pilot ?? "this pilot")")
    }

    private var bannerTile: some View {
        Button {
            if isBannerRunning {
                liveActivity.stop(flightId: flight.id)
            } else {
                liveActivity.start(for: flight)
            }
        } label: {
            FlightInfoTile(
                symbol: "livephoto",
                title: isBannerRunning ? "Showing" : "Banner",
                caption: "LIVE",
                isFilled: isBannerRunning,
                theme: theme
            )
        }
        .buttonStyle(.plain)
        .disabled(!liveActivity.isSupported)
        .opacity(liveActivity.isSupported ? 1 : 0.45)
        .accessibilityLabel(isBannerRunning ? "Stop the live banner" : "Show a live banner for this flight")
    }

    private var pinTile: some View {
        Button {
            widgets.pin(isPinned ? nil : flight.id)
        } label: {
            FlightInfoTile(
                symbol: isPinned ? "square.grid.2x2.fill" : "square.grid.2x2",
                title: isPinned ? "Pinned" : "Pin",
                caption: "WIDGET",
                isFilled: isPinned,
                theme: theme
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPinned ? "Unpin from the home screen widget" : "Pin to the home screen widget")
    }

    // MARK: - Labels

    /// Time since the first sample we have. That is the flight's own start when
    /// the backend's history reaches back to departure, and the moment we
    /// started watching when it doesn't — so it is never presented as anything
    /// more precise than "elapsed".
    private var elapsedLabel: String {
        guard let first = track.compactMap(\.date).min() else { return "—:—" }
        let interval = now.timeIntervalSince(first)
        guard interval > 60 else { return "00:00" }
        return Format.duration(interval)
    }

    private var remainingLabel: String {
        guard let progress = FlightProgress(flight: flight),
              let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—:—"
        }
        return Format.duration(ete)
    }

    // MARK: - Sharing

    /// The sheet's heading and an email's subject line.
    private var shareSubject: String {
        let route = [flight.departureIcao, flight.arrivalIcao].compactMap { $0 }
        guard route.count == 2 else { return flight.displayName }
        return "\(flight.displayName) · \(route[0]) → \(route[1])"
    }

    /// What actually gets sent. Plain text: it has to read as well pasted into
    /// a message as it does in the share sheet's preview.
    ///
    /// Ends with the time it was taken. Every number above it is a live
    /// reading, and a bare "37,000 ft" arriving in somebody's messages with no
    /// time attached is not a fact they can do anything with.
    private var shareBody: String {
        var lines: [String] = []

        let aircraft = [flight.aircraftName, flight.liveryName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        lines.append(aircraft.isEmpty ? flight.displayName : "\(flight.displayName) — \(aircraft)")

        if let pilot = pilot {
            lines.append("Flown by \(pilot) · \(flight.pilotState.detail.lowercased())")
        }

        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            let departure = flight.departureIcao ?? "———"
            let arrival = flight.arrivalIcao ?? "———"
            if let progress = progress {
                lines.append("\(departure) → \(arrival) · \(Format.number(progress.remainingNM)) NM to run")
            } else {
                lines.append("\(departure) → \(arrival)")
            }

        case .grounded(let airport, let isTaxiing):
            let place = airport?.icao ?? "an unknown field"
            lines.append(isTaxiing ? "Taxiing at \(place)" : "Parked at \(place)")

        case .unplanned(_, let nearest):
            lines.append(nearest.map { "Passing \($0.icao)" } ?? "Airborne, no destination filed")
        }

        lines.append("\(Format.number(flight.altitudeFeet)) ft · \(Format.number(flight.groundSpeedKnots)) kts")

        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        lines.append("As of \(stamp) · tracked with Inflight")

        return lines.joined(separator: "\n")
    }
}
