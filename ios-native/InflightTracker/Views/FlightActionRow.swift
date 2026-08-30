import Combine
import SwiftUI

/// The three tiles under the identity block: how long it has been going, a
/// replay of where it has been, and a way to send it to someone.
///
/// They sit together because they are the three things you do with a flight
/// once you have found it, and they read as one control rather than three
/// buttons scattered through the window.
struct FlightActionRow: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// The path we have for this aircraft. Its first dated sample is what makes
    /// the clock possible, and its length is what makes a replay worth
    /// offering — so both tiles are driven by it.
    let track: [TrackPoint]

    let onReplay: () -> Void

    @ObservedObject private var entitlements = Entitlements.shared

    /// The clock tile flips between how long it has been flying and how long
    /// is left. Both are useful, neither is worth its own tile.
    @State private var showsRemaining = false

    /// Raised by the replay tile when the account doesn't have Pro. Presented
    /// from here rather than reported upward, so the paywall arrives on the
    /// tile that was tapped and the window underneath is exactly as it was
    /// when it is dismissed.
    @State private var isShowingPaywall = false

    /// Ticked once a minute so the elapsed time keeps up without redrawing the
    /// window on every frame.
    @State private var now = Date()

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var canReplay: Bool { track.count >= FlightReplay.minimumPoints }

    var body: some View {
        // `.fixedSize(vertical:)` so the row takes its ideal height — the
        // tallest tile — and every tile then fills it. Without it the three
        // sized themselves independently and a tile with no caption came out
        // shorter than its neighbours, which is visible as three boxes of two
        // different heights sitting in a row.
        HStack(spacing: 10) {
            timeTile
            replayTile
            shareTile
        }
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .replay) }
    }

    // MARK: - Tiles

    /// Filled rather than outlined: of the three this is the one that is also a
    /// readout, so it carries the row the way the callsign carries the header.
    private var timeTile: some View {
        Button {
            withAnimation(Motion.content) { showsRemaining.toggle() }
        } label: {
            tile(
                symbol: showsRemaining ? "flag.pattern.checkered" : clock.symbol,
                title: showsRemaining ? remainingLabel : clock.value(now: now),
                caption: showsRemaining ? "TO RUN" : clock.caption,
                filled: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsRemaining ? "Time to run" : clock.accessibilityLabel)
        .accessibilityHint("Switches between elapsed and remaining")
    }

    /// Pro. Locked rather than hidden: the tile still says what it is, and
    /// tapping it explains itself — a feature you cannot see is a feature
    /// nobody knows they are missing.
    ///
    /// The lock is checked *after* the track: a flight with nothing to replay
    /// yet has nothing to sell either, and dangling the paywall off a tile that
    /// would be disabled anyway would be the shabbiest version of this.
    private var replayTile: some View {
        Button {
            if entitlements.has(.replay) {
                onReplay()
            } else {
                isShowingPaywall = true
            }
        } label: {
            tile(
                symbol: entitlements.has(.replay) ? "clock.arrow.circlepath" : "lock",
                title: "Replay",
                caption: entitlements.has(.replay) ? nil : "PRO",
                filled: false
            )
        }
        .buttonStyle(.plain)
        // Nothing to play back yet: the backend's history hasn't arrived, or
        // the aircraft has only just started reporting.
        .disabled(!canReplay)
        .opacity(canReplay ? 1 : 0.45)
    }

    private var shareTile: some View {
        ShareLink(item: summary) {
            tile(symbol: "square.and.arrow.up", title: "Share", caption: nil, filled: false)
        }
        .buttonStyle(.plain)
    }

    private func tile(symbol: String, title: String, caption: String?, filled: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? theme.onAccent : theme.textPrimary)
                .frame(height: 18)

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? theme.onAccent : theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            // Rendered even when empty. Reserving the line keeps the symbol
            // and the title on the same baseline across all three tiles;
            // dropping it moved Share's contents up relative to its
            // neighbours' by exactly the height of a caption.
            Text(caption ?? " ")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(filled ? theme.onAccent.opacity(0.6) : theme.textDim)
                .opacity(caption == nil ? 0 : 1)
                .accessibilityHidden(caption == nil)
        }
        .padding(.vertical, 11)
        // Height as well as width: the row is as tall as its tallest tile and
        // each one grows into that, so all three backgrounds are one size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A filled action is a solid accent and stays one — that is what makes
        // it the primary of the row. Everything else is glass.
        .background {
            if filled {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .fill(theme.accent)
            }
        }
        .flightInfoSurface(theme, radius: theme.radiusSmall, interactive: true)
        .contentShape(Rectangle())
    }

    // MARK: - The clock

    /// What the first tile is counting, and why.
    ///
    /// It used to count one thing and call it ELAPSED: the time since the first
    /// sample we hold. On a flight the backend's history covers that is the
    /// departure and the label is nearly right; on one the app happened to find
    /// at cruise it is the moment somebody opened the app, which is a number
    /// about the observer rather than about the aeroplane. And on an aircraft
    /// that has already landed and taxied for twenty minutes it kept counting,
    /// which is the case that reads as simply broken.
    ///
    /// So the tile says which of three questions it is answering, and the
    /// caption is part of the readout rather than a fixed word above it.
    private enum Clock {

        /// Time since the wheels left, read off the path. The answer somebody
        /// asking "how long has this been flying" actually wants.
        case airborne(since: Date)

        /// Time since it touched down — for an aeroplane on the ground, which
        /// has no airborne leg to measure.
        case onGround(since: Date)

        /// Time since we first saw it. The honest fallback: the aircraft is
        /// flying and the path holds no ground sample, so nothing here knows
        /// when it left.
        case watching(since: Date)

        /// Nothing to count at all.
        case unknown

        var symbol: String {
            switch self {
            case .airborne, .watching: return "airplane"
            case .onGround:            return "airplane.arrival"
            case .unknown:             return "clock"
            }
        }

        var caption: String {
            switch self {
            case .airborne:  return "AIRBORNE"
            case .onGround:  return "ON GROUND"
            case .watching:  return "ELAPSED"
            case .unknown:   return "ELAPSED"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .airborne:  return "Time since take-off"
            case .onGround:  return "Time on the ground"
            case .watching:  return "Time elapsed"
            case .unknown:   return "Time elapsed"
            }
        }

        private var start: Date? {
            switch self {
            case .airborne(let since), .onGround(let since), .watching(let since):
                return since
            case .unknown:
                return nil
            }
        }

        func value(now: Date) -> String {
            guard let start = start else { return "—:—" }
            let interval = now.timeIntervalSince(start)
            // Under a minute rounds to 00:00 through `Format.duration` anyway;
            // the guard is here to refuse a negative one, which a clock that
            // disagrees with the server's can produce.
            guard interval >= 0 else { return "—:—" }
            return interval < 60 ? "00:00" : Format.duration(interval)
        }
    }

    /// Which of the three this flight is, decided by where the aeroplane is
    /// now and how far back the path reaches.
    ///
    /// The live phase decides airborne or not, rather than the last sample in
    /// the track: the track is thinned by distance, so its newest point can be
    /// several miles and a couple of minutes old, and an aeroplane that has
    /// just touched down would still be reported as flying by it.
    private var clock: Clock {
        if FlightPhase.from(flight) == .ground {
            if let landed = TrackPoint.lastLanding(in: track) {
                return .onGround(since: landed)
            }
        } else if let takeoff = TrackPoint.lastTakeoff(in: track) {
            return .airborne(since: takeoff)
        }

        // Neither question can be answered from the path — an aeroplane parked
        // since before we were watching, or one found already at cruise. Back
        // to the number the tile has always shown, under the label that says
        // what it actually is.
        guard let seen = start else { return .unknown }
        return .watching(since: seen)
    }

    // MARK: - Labels

    /// The first sample we have. That is the flight's own start when the
    /// backend's history reaches back to departure, and the moment we started
    /// watching when it doesn't — which is why the tile above says ELAPSED
    /// rather than AIRBORNE when it falls back to this.
    ///
    /// Reading the track alone was not enough, and the failure was quiet: the
    /// trail is thinned by DISTANCE, so an aircraft that has not moved two
    /// miles holds exactly one sample and one that has filled its buffer has
    /// had its oldest sample halved away. Neither case has an early point to
    /// find, and both showed "—:—" on a parked or long-haul flight — the two
    /// cases where somebody most wants a clock. `firstSeen` is kept for exactly
    /// this and survives both.
    private var start: Date? {
        track.compactMap(\.date).min()
            ?? FlightTrailStore.shared.firstSeen(for: flight.id)
    }

    private var remainingLabel: String {
        guard let progress = FlightProgress(flight: flight),
              let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—:—"
        }
        return Format.duration(ete)
    }

    /// What gets sent. Plain text: it has to read as well pasted into a message
    /// as it does in a share sheet's preview.
    private var summary: String {
        var lines: [String] = []

        let aircraft = [flight.aircraftName, flight.liveryName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        lines.append(aircraft.isEmpty ? flight.displayName : "\(flight.displayName) — \(aircraft)")

        if let pilot = flight.username {
            lines.append("Flown by \(pilot) · \(flight.pilotState.detail.lowercased())")
        }

        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            let departure = flight.departureIcao ?? "———"
            let arrival = flight.arrivalIcao ?? "———"
            if let progress = progress {
                lines.append(
                    "\(departure) → \(arrival) · \(Format.number(progress.remainingNM)) NM to run"
                )
            } else {
                lines.append("\(departure) → \(arrival)")
            }

        case .grounded(let airport, let isTaxiing):
            let place = airport?.icao ?? "an unknown field"
            lines.append(isTaxiing ? "Taxiing at \(place)" : "Parked at \(place)")

        case .unplanned(_, let nearest):
            lines.append(nearest.map { "Passing \($0.icao)" } ?? "Airborne, no destination filed")
        }

        lines.append(
            "\(Format.number(flight.altitudeFeet)) ft · \(Format.number(flight.groundSpeedKnots)) kts"
        )

        return lines.joined(separator: "\n")
    }
}
