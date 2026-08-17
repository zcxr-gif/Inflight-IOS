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

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var canReplay: Bool { track.count >= FlightReplay.minimumPoints }

    var body: some View {
        HStack(spacing: 10) {
            timeTile
            replayTile
            shareTile
        }
        .onReceive(clock) { now = $0 }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .replay) }
    }

    // MARK: - Tiles

    /// Filled rather than outlined: of the three this is the one that is also a
    /// readout, so it carries the row the way the callsign carries the header.
    private var timeTile: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showsRemaining.toggle() }
        } label: {
            tile(
                symbol: showsRemaining ? "flag.pattern.checkered" : "airplane",
                title: showsRemaining ? remainingLabel : elapsedLabel,
                caption: showsRemaining ? "TO RUN" : "ELAPSED",
                filled: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsRemaining ? "Time to run" : "Time elapsed")
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

            if let caption = caption {
                Text(caption)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(filled ? theme.onAccent.opacity(0.6) : theme.textDim)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)

            if filled {
                shape.fill(theme.accent)
            } else {
                shape.fill(theme.surfaceFill)
                    .overlay { shape.strokeBorder(theme.stroke, lineWidth: 1) }
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Labels

    /// Time since the first sample we have. That is the flight's own start when
    /// the backend's history reaches back to departure, and the moment we
    /// started watching when it doesn't — so it is never presented as anything
    /// more precise than "elapsed".
    private var elapsedLabel: String {
        guard let first = track.compactMap(\.date).first else { return "—:—" }
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
