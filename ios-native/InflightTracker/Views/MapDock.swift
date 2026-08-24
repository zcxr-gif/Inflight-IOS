import SwiftUI

/// The furniture along the bottom of the map: one card, with a handle on it.
///
/// It used to be two things pretending to be one — a pill with a grabber in it,
/// sitting on top of a bar with its own glass — and it read as exactly that:
/// two pieces of chrome that happened to be touching, with the word between
/// them getting clipped where they met. This is a single card instead. The
/// handle is part of it, the bar sits inside it on its own slightly raised
/// surface, and the stats open *within* it rather than as a second card
/// floating above.
///
/// So there is one shape on the bottom of the screen, it grows when you pull
/// it, and the thing you pull is on the thing that grows.
struct MapDock: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme

    /// Positions currently open, badged on ATC.
    let atcCount: Int

    /// How many of the filter groups are narrowed.
    let activeFilters: Int

    /// Watched pilots currently in the air.
    let friendsAloft: Int

    /// Whether the stats are resting open. Held by the map so the chrome in the
    /// two bottom corners can move up out of their way.
    @Binding var isStatsUp: Bool

    let onPanel: (MapPanelKind) -> Void

    /// The whole stats screen, from the "all the numbers" row.
    let onOpenStats: () -> Void

    /// How far the finger has carried the dock open, upwards positive. Reset
    /// the instant the drag ends — with the spring below, so a dock let go of
    /// halfway settles rather than snapping.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.86)))
    private var pull: CGFloat = 0

    /// How much of the map's bottom edge the dock covers, closed, including the
    /// gap underneath it. The map keeps this much clear when it frames
    /// something, the same way it keeps clear of the flight window.
    ///
    /// The handle, the bar, the card's own padding and the gap: 6 + 15 + 8 + 61
    /// + 8, and 6 more between the card and the safe area. Rounded up rather
    /// than measured, because everything that reads it — the camera's inset,
    /// Apple's legal link, the two bottom corners — wants an answer before any
    /// of this has drawn.
    static let reservedHeight: CGFloat = 106

    /// The strip immediately above the dock, kept empty for Apple's "Legal"
    /// link.
    ///
    /// MapKit draws the link in the bottom-left corner of whatever the map's
    /// layout margins leave it, and Apple's terms require it to stay visible
    /// and tappable — so the map lifts it to just above the dock, and the
    /// chrome in the two bottom corners starts above this lane rather than on
    /// top of it.
    static let legalLane: CGFloat = 20

    /// How far everything else has to move while the stats are up: the panel,
    /// and the gap between it and the bar.
    static let statsLift: CGFloat = StatsPanel.height + 8

    /// How far a drag has to be heading before it counts. Below this it is a
    /// tap, and a tap does the same thing anyway.
    private static let pullThreshold: CGFloat = 24

    /// How much of the stats is showing right now: where they are resting, plus
    /// whatever the finger has added, never past the panel's own height.
    private var revealed: CGFloat {
        min(max((isStatsUp ? StatsPanel.height : 0) + pull, 0), StatsPanel.height)
    }

    var body: some View {
        VStack(spacing: 8) {
            handle

            if revealed > 0 {
                StatsPanel(theme: theme, onOpenFull: onOpenStats)
                    .environmentObject(feed)
                    // Bottom-aligned inside a frame that grows: the numbers
                    // rise out of the bar rather than being squashed against
                    // it.
                    .frame(height: revealed, alignment: .bottom)
                    .clipped()
                    // Faded on the way, so an inch of panel hanging out of the
                    // dock reads as one opening rather than one that gave up.
                    .opacity(Double(min(revealed / (StatsPanel.height * 0.6), 1)))
                    // Nothing in it is worth pressing until it has settled — a
                    // button under a moving finger is a mis-tap waiting to be
                    // blamed on the app.
                    .allowsHitTesting(revealed >= StatsPanel.height)
            }

            MapToolbar(
                theme: theme,
                atcCount: atcCount,
                activeFilters: activeFilters,
                friendsAloft: friendsAloft,
                action: onPanel
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        // On the whole dock rather than the handle alone: once the stats are
        // up, pushing them back down from anywhere on the card is the gesture
        // people try.
        //
        // Simultaneous, because the handle is a button and a button claims the
        // touch it is under. A pull past the button's own cancel distance stops
        // it firing, so the two never both act on one gesture: a tap toggles, a
        // pull drags, and a nudge too small for either does nothing but toggle.
        .simultaneousGesture(pullGesture)
    }

    /// The grabber, the way every pull-up on the phone marks itself. Wide
    /// enough to be obviously draggable, and with a good deal more tappable
    /// area around it than it looks like it has.
    private var handle: some View {
        Button {
            isStatsUp.toggle()
        } label: {
            Capsule()
                .fill(theme.textSecondary.opacity(isStatsUp ? 0.9 : 0.5))
                .frame(width: 42, height: 5)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStatsUp ? "Hide the stats" : "Show the stats")
        .accessibilityHint("Pull up for the numbers on this server")
        .accessibilityAddTraits(isStatsUp ? .isSelected : [])
    }

    /// The pull itself. `predictedEndTranslation` rather than the raw distance,
    /// so a short flick opens the dock the way a flick opens a sheet — the
    /// finger does not have to travel the whole height of the thing it is
    /// moving.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($pull) { value, state, _ in
                state = -value.translation.height
            }
            .onEnded { value in
                let travel = -value.predictedEndTranslation.height
                if travel > Self.pullThreshold { isStatsUp = true }
                if travel < -Self.pullThreshold { isStatsUp = false }
            }
    }
}
