import SwiftUI

/// The stats, on a handle you pull up over the toolbar.
///
/// They used to be one of the seven places the bar went, which bought a whole
/// destination — glyph, label, a seventh of the width — for a screen most
/// people open once. Now the bar carries a handle: pull it and the numbers
/// come up over the map, drop it and they go away, and the full breakdown is
/// one more tap from there for anybody who wants it.
///
/// The handle is a grabber rather than a chevron on a button, and the card
/// tracks the finger the whole way up rather than appearing once a gesture has
/// been judged to have finished. That is the difference between something you
/// pull and something you press: a half-open card is a state you can see, and
/// change your mind about, on the way.
///
/// Nothing is counted until it is asked for. The count is a walk over every
/// aircraft on the server, so it runs from the moment the card starts coming
/// up and once per packet after that, and not at all while it is down.
struct StatsTip: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme

    /// Whether the stats are resting open. Held by the map so the chrome in the
    /// corners can move up out of their way.
    @Binding var isUp: Bool

    /// The whole panel, for the breakdown this is too small to carry.
    let onOpenFull: () -> Void

    @State private var pulse = ServerPulse.empty

    /// How far the finger has carried the card, upwards positive. Reset the
    /// instant the drag ends — with the spring below, so a card let go of
    /// halfway settles rather than snapping.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.86)))
    private var pull: CGFloat = 0

    /// How tall the card is. Fixed rather than measured, so the map's other
    /// chrome knows how far to lift before the card has drawn.
    static let cardHeight: CGFloat = 188

    /// How far a drag has to be heading before it counts. Below this it is a
    /// tap, and a tap does the same thing anyway.
    private static let pullThreshold: CGFloat = 24

    /// How much of the card is showing right now: where it is resting, plus
    /// whatever the finger has added, never past the card's own height.
    private var revealed: CGFloat {
        min(max((isUp ? Self.cardHeight : 0) + pull, 0), Self.cardHeight)
    }

    var body: some View {
        VStack(spacing: 6) {
            if revealed > 0 {
                card
                    // Bottom-aligned inside a frame that grows: the card rises
                    // out of the handle rather than being squashed against it.
                    .frame(height: revealed, alignment: .bottom)
                    .clipped()
                    // Faded on the way, so an inch of card hanging off the bar
                    // reads as one opening rather than one that gave up.
                    .opacity(Double(min(revealed / (Self.cardHeight * 0.6), 1)))
                    // Nothing in it is worth pressing until it has settled — a
                    // button under a moving finger is a mis-tap waiting to be
                    // blamed on the app.
                    .allowsHitTesting(revealed >= Self.cardHeight)
            }

            handle
        }
        // On the whole strip rather than the handle alone: once the card is up,
        // pushing it back down from anywhere on it is the gesture people try.
        //
        // Simultaneous, because the handle is a button and a button claims the
        // touch it is under. A pull past the button's own cancel distance
        // stops it firing, so the two never both act on one gesture: a tap
        // toggles, a pull drags, and a nudge too small for either does nothing
        // but toggle.
        .simultaneousGesture(pullGesture)
    }

    // MARK: - The handle

    /// A grabber, the way every pull-up on the phone marks itself, with the
    /// word underneath so what is being pulled is not a guess.
    private var handle: some View {
        Button {
            isUp.toggle()
        } label: {
            VStack(spacing: 3) {
                Capsule()
                    .fill(theme.textSecondary.opacity(isUp ? 0.9 : 0.6))
                    .frame(width: 34, height: 4.5)

                Text("STATS")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .padding(.bottom, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .flightInfoChrome(theme, in: Capsule())
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityLabel(isUp ? "Hide the stats" : "Show the stats")
        .accessibilityHint("Pull up for the numbers on this server")
        .accessibilityAddTraits(isUp ? .isSelected : [])
    }

    /// The pull itself. `predictedEndTranslation` rather than the raw distance,
    /// so a short flick opens the card the way a flick opens a sheet — the
    /// finger does not have to travel the whole height of the thing it is
    /// moving.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($pull) { value, state, _ in
                state = -value.translation.height
            }
            .onEnded { value in
                let travel = -value.predictedEndTranslation.height
                if travel > Self.pullThreshold { isUp = true }
                if travel < -Self.pullThreshold { isUp = false }
            }
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
                header

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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(height: Self.cardHeight)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
    }

    /// What the three figures underneath are three figures *of*: how many
    /// aeroplanes, on which server, off a feed in what state. The card used to
    /// open on three numbers with nothing saying what they were counted from,
    /// which is the one question a stat with no source always gets asked.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Format.number(Double(pulse.total)))
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)

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
        }
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

    /// One of the three headline numbers, written the way the panel writes
    /// them so the handle and the panel read as the same thing.
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
