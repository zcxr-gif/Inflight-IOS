import SwiftUI

/// The stats, on a tab above the toolbar.
///
/// They used to be one of the seven places the bar went, which bought a whole
/// destination — glyph, label, a seventh of the width — for a screen most
/// people open once. Now the bar carries a tip you pull up: three numbers and a
/// line of detail come up over the map, and the full breakdown is one more tap
/// from there for anybody who wants it.
///
/// Nothing is counted until it is asked for. The count is a walk over every
/// aircraft on the server, so it runs when the tab is up and once per packet
/// after that, and not at all while it is down.
struct StatsTip: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme

    /// Whether the stats are showing. Held by the map so the chrome in the
    /// corners can move up out of their way.
    @Binding var isUp: Bool

    /// The whole panel, for the breakdown this is too small to carry.
    let onOpenFull: () -> Void

    @State private var pulse = ServerPulse.empty

    /// How tall the card is. Fixed rather than measured, so the map's other
    /// chrome knows how far to lift before the card has drawn.
    static let cardHeight: CGFloat = 156

    /// How far an upward drag has to travel before it counts. Below this it is
    /// a tap, and a tap does the same thing anyway.
    private static let pullThreshold: CGFloat = 12

    var body: some View {
        VStack(spacing: 6) {
            if isUp { card }
            tab
        }
    }

    // MARK: - The tab

    private var tab: some View {
        Button {
            isUp.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.textSecondary)

                Text("STATS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textSecondary)

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.textDim)
                    .rotationEffect(.degrees(isUp ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .flightInfoChrome(theme, in: Capsule())
        .environment(\.colorScheme, theme.colorScheme)
        // Pulled as well as pressed: it is a tab on the edge of a bar, and the
        // first thing a thumb tries with one of those is to drag it.
        .gesture(
            DragGesture(minimumDistance: Self.pullThreshold)
                .onEnded { value in
                    if value.translation.height < -Self.pullThreshold { isUp = true }
                    if value.translation.height > Self.pullThreshold { isUp = false }
                }
        )
        .accessibilityLabel(isUp ? "Hide the stats" : "Show the stats")
        .accessibilityAddTraits(isUp ? .isSelected : [])
    }

    // MARK: - What comes up

    private var card: some View {
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
                HStack(spacing: 8) {
                    figure("\(pulse.airborne)", label: "IN THE AIR")
                    figure("\(pulse.onGround)", label: "ON THE GROUND")
                    figure("\(pulse.controllers)", label: "ON FREQUENCY")
                }

                HStack(spacing: 8) {
                    MiniStat(
                        label: "MEDIAN",
                        value: "\(Format.number(pulse.medianAltitudeFeet)) ft",
                        theme: theme
                    )
                    MiniStat(
                        label: "AVERAGE SPEED",
                        value: "\(Format.number(pulse.averageGroundSpeedKnots)) kts",
                        theme: theme,
                        alignment: .center
                    )
                    MiniStat(
                        label: "BUSIEST",
                        value: pulse.busiestDepartures.first?.name ?? "—",
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(height: Self.cardHeight)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// One of the three headline numbers, written the way the panel writes
    /// them so the tab and the panel read as the same thing.
    private func figure(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label.lowercased())")
    }

    private func recount() {
        pulse = ServerPulse.from(flights: feed.flights, stations: feed.atcStations)
    }
}
