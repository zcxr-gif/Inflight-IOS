import SwiftUI

/// The numbers, on the face the dock's handle pulls up.
///
/// Content only: no background, no chrome, no rounded corners of its own. It is
/// drawn inside the dock, on the dock's ground, the way a card in the flight
/// window is drawn on the window's — a panel with its own glass inside another
/// piece of glass reads as two things stacked rather than one thing opening.
///
/// Nothing is counted until it is asked for. The count is a walk over every
/// aircraft on the server, so it runs from the moment the panel starts coming
/// up and once per packet after that, and not at all while it is down.
struct StatsPanel: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme

    /// The whole panel, for the breakdown this is too small to carry.
    let onOpenFull: () -> Void

    @State private var pulse = ServerPulse.empty

    /// How tall this is. Fixed rather than measured, so the dock knows how far
    /// it will grow, and the map's other chrome knows how far to lift, before
    /// any of it has drawn.
    static let height: CGFloat = 188

    var body: some View {
        VStack(spacing: 8) {
            if pulse.total == 0 {
                Spacer(minLength: 0)

                Text(feed.status.isLive ? "Nothing to count yet" : feed.status.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Text("The first packet has not arrived. This fills in the moment it does.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)
            } else {
                header

                HStack(spacing: 8) {
                    figure("\(pulse.airborne)", of: Double(pulse.airborne), label: "IN THE AIR")
                    figure("\(pulse.onGround)", of: Double(pulse.onGround), label: "ON THE GROUND")
                    figure(
                        "\(pulse.controllers)",
                        of: Double(pulse.controllers),
                        label: "ON FREQUENCY"
                    )
                }

                HStack(spacing: 8) {
                    MiniStat(
                        label: "MEDIAN",
                        value: "\(Format.number(pulse.medianAltitudeFeet)) ft",
                        theme: theme,
                        figure: pulse.medianAltitudeFeet
                    )
                    MiniStat(
                        label: "AVERAGE SPEED",
                        value: "\(Format.number(pulse.averageGroundSpeedKnots)) kts",
                        theme: theme,
                        alignment: .center,
                        figure: pulse.averageGroundSpeedKnots
                    )
                    // A field's name with its traffic after it, so a word
                    // rather than a figure: the busiest field changing is the
                    // whole line changing.
                    MiniStat(
                        label: "BUSIEST",
                        value: busiest,
                        theme: theme,
                        alignment: .trailing
                    )
                }

                Spacer(minLength: 0)
            }

            Button(action: onOpenFull) {
                HStack(spacing: 6) {
                    Text("All the numbers")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All the numbers")
            .accessibilityHint("Opens the full stats")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .flightInfoLegible(theme)
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
    }

    /// What the three figures underneath are three figures *of*: how many
    /// aeroplanes, on which server, off a feed in what state. The panel used to
    /// open on three numbers with nothing saying what they were counted from,
    /// which is the one question a stat with no source always gets asked.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Format.number(Double(pulse.total)))
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .motionFigure(Double(pulse.total))

            Text("ON \(feed.server.uppercased())")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.7)

            Spacer(minLength: 4)

            Circle()
                .fill(feed.status.isLive ? theme.accent : theme.textDim)
                .frame(width: 5, height: 5)

            Text(feed.status.label.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .motionWords(feed.status.label)
        }
        .motion(Motion.content, value: feed.status.isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(pulse.total) aircraft on \(feed.server), feed \(feed.status.label.lowercased())"
        )
    }

    /// The busiest field, with the traffic that makes it the busiest. The code
    /// on its own was a name where a number belonged — the whole row beside it
    /// is figures, and "EGLL" says which field without saying how busy.
    private var busiest: String {
        guard let field = pulse.busiestDepartures.first else { return "—" }
        return "\(field.name) \(field.count)"
    }

    /// One of the three headline numbers, written the way the full panel writes
    /// them so the two read as the same thing.
    private func figure(_ value: String, of number: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)
                .motionFigure(number)

            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall, elevated: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label.lowercased())")
    }

    private func recount() {
        pulse = ServerPulse.from(flights: feed.flights, stations: feed.atcStations)
    }
}
