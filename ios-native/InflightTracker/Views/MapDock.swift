import SwiftUI

/// The furniture along the bottom of the map: one card, with a handle on it.
///
/// One shape on the bottom of the screen, which grows when you pull it, and the
/// thing you pull is on the thing that grows.
///
/// The handle has three stops rather than two, because the stats have two sizes
/// and the old handle only knew about the small one. Pull once and the figures
/// come up inside the dock — how many are flying, how many are on the ground,
/// who is on frequency. Pull again, from there, and the whole stats window
/// opens: the breakdown, the boards, everything the strip in the dock is too
/// short to carry. That is the second pull the dock used to ignore, leaving the
/// full panel reachable only by finding a small caption inside the small one.
///
/// The pull itself was rebuilt as well. It measures in screen coordinates
/// rather than in the dock's own, and the dock *moves while you are dragging
/// it* — it is the thing being opened. Measured locally, every point the card
/// grew was subtracted from the distance the finger had travelled, which fed
/// straight back into how far it grew: the handle stuck, jumped, and let go
/// halfway. And the handle is no longer a button with a drag laid over it, so
/// there is nothing left to argue with the gesture about who has the touch.
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

    /// The whole stats window — what the second pull asks for.
    let onOpenStats: () -> Void

    /// How far the finger has carried the dock open, upwards positive. Reset
    /// the instant the drag ends — with the spring below, so a dock let go of
    /// halfway settles rather than snapping.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.86)))
    private var pull: CGFloat = 0

    @GestureState private var isHeld = false

    // MARK: - Metrics

    /// The card's own radius, and how far inside it everything sits. Public
    /// because the bar reads them to work out its own radius: a bar whose
    /// curve is not the card's curve less the inset reads as a rectangle in a
    /// rounded box.
    static let cornerRadius: CGFloat = 26
    static let cardInset: CGFloat = 6

    private static let cardTop: CGFloat = 4
    private static let cardBottom: CGFloat = 6
    private static let rowGap: CGFloat = 6

    /// The band the grabber sits in.
    ///
    /// This was twenty-eight, on the theory that a bigger target is an easier
    /// one. It is, and it also put thirty-six points of empty card above a bar
    /// that is only forty-eight tall — the handle stopped reading as a marker
    /// on the dock and started reading as a second row of nothing. Twenty is
    /// still a third taller than the fifteen it started at, and the drag does
    /// not depend on hitting it anyway: the gesture is on the whole card, so
    /// this only has to be big enough to *tap*, and the tap has the card's own
    /// top padding under it as well.
    static let handleBand: CGFloat = 20

    /// The gap the map leaves between the card and the safe area.
    static let liftOffSafeArea: CGFloat = 4

    /// How much of the map's bottom edge the dock covers, closed, including the
    /// gap underneath it. The map keeps this much clear when it frames
    /// something, the same way it keeps clear of the flight window.
    ///
    /// Added up from the parts rather than rounded up from a guess, so it
    /// cannot drift the next time one of them changes.
    static let reservedHeight: CGFloat =
        cardTop + handleBand + rowGap + MapToolbar.height + cardBottom + liftOffSafeArea

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
    static let statsLift: CGFloat = StatsPanel.height + rowGap

    /// How far a drag has to be heading before it counts as a drag at all.
    /// Below this it is a tap, and a tap does the same thing anyway.
    private static let stageThreshold: CGFloat = 26

    /// How far past fully open the finger has to carry it to ask for the whole
    /// window. Short, because by then the dock has already stopped growing and
    /// the only thing left for the gesture to mean is "more".
    private static let fullThreshold: CGFloat = 46

    /// How far the card will lift at the top of the travel, however hard it is
    /// pulled.
    private static let overshootLimit: CGFloat = 34

    // MARK: - Where the pull has got to

    /// Where the stats are resting, before the finger is taken into account.
    private var restingHeight: CGFloat { isStatsUp ? StatsPanel.height : 0 }

    /// How much of the stats is showing right now: where they are resting, plus
    /// whatever the finger has added, never past the panel's own height.
    private var revealed: CGFloat {
        min(max(restingHeight + pull, 0), StatsPanel.height)
    }

    /// How far past fully open the finger has carried it — resisted, so the
    /// stop is something you can feel rather than a wall the drag runs into.
    private var overshoot: CGFloat {
        let raw = restingHeight + pull - StatsPanel.height
        guard raw > 0 else { return 0 }
        // Asymptotic rather than clamped: the card keeps giving a little for as
        // long as the finger keeps going, and never reaches the stop. A hard
        // limit reads as the gesture having been dropped.
        return raw * Self.overshootLimit / (raw + 60)
    }

    /// Whether letting go now would open the whole window.
    private var willOpenFull: Bool {
        restingHeight + pull > StatsPanel.height + Self.fullThreshold
    }

    var body: some View {
        VStack(spacing: Self.rowGap) {
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
                    .allowsHitTesting(revealed >= StatsPanel.height && pull == 0)
            }

            MapToolbar(
                theme: theme,
                atcCount: atcCount,
                activeFilters: activeFilters,
                friendsAloft: friendsAloft,
                action: onPanel
            )
        }
        .padding(.horizontal, Self.cardInset)
        .padding(.top, Self.cardTop)
        .padding(.bottom, Self.cardBottom)
        // The overshoot is the card itself lifting, not the stats growing —
        // they have run out of height by then. It is the give at the end of the
        // travel that says there is one more stop.
        .offset(y: -overshoot)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        // On the whole card rather than the handle alone: once the stats are
        // up, pushing them back down from anywhere on the dock is the gesture
        // people try. Simultaneous, so the bar's buttons still take their own
        // taps — a drag past a button's cancel distance stops it firing, so the
        // two never both act on one gesture.
        .simultaneousGesture(pullGesture)
    }

    /// The grabber, the way every pull-up on the phone marks itself, with the
    /// cue for the stop above it.
    private var handle: some View {
        ZStack {
            // The pill hands over to the cue as the travel runs out, in the
            // same band rather than beside it: two things in a twenty-eight
            // point strip is a strip with two things crammed into it.
            let cue = Double(min(overshoot / 14, 1))

            Capsule()
                .fill(theme.textSecondary.opacity(isHeld || isStatsUp ? 0.9 : 0.45))
                .frame(width: isHeld ? 56 : 44, height: isHeld ? 6 : 5)
                .opacity(1 - cue)
                .animation(FlightInfoMotion.control, value: isHeld)

            // Only once the finger is past the top of the travel: the dock has
            // stopped growing by then, so without this the last inch of the
            // pull reads as nothing happening rather than as the next stop
            // arriving.
            if overshoot > 0 {
                Text(willOpenFull ? "RELEASE FOR THE FULL STATS" : "KEEP PULLING FOR THE FULL STATS")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(willOpenFull ? theme.textSecondary : theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
                    .padding(.horizontal, 12)
                    .opacity(cue)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.handleBand)
        .contentShape(Rectangle())
        // A tap, not a button. A button claims the touch it is under and then
        // spends the rest of the gesture arguing with the drag about who has
        // it; this is the same two behaviours with nothing to arbitrate.
        .onTapGesture { toggle() }
        .accessibilityElement()
        .accessibilityLabel(isStatsUp ? "Hide the stats" : "Show the stats")
        .accessibilityHint("Pull up for the numbers on this server, and again for the full stats")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isStatsUp ? .isSelected : [])
        .accessibilityAction { toggle() }
        .accessibilityAction(named: "Open the full stats") { onOpenStats() }
    }

    /// The pull itself.
    ///
    /// Measured against the screen rather than against the dock. The dock grows
    /// under the finger as it opens, and a translation read in a coordinate
    /// space that is itself moving subtracts the growth from the travel — which
    /// is precisely the stick-and-jump the handle used to have.
    ///
    /// `predictedEndTranslation` decides where it lands, so a short flick opens
    /// the dock the way a flick opens a sheet: the finger does not have to
    /// travel the whole height of the thing it is moving.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isHeld) { _, state, _ in state = true }
            .updating($pull) { value, state, _ in
                state = -value.translation.height
            }
            .onEnded { value in
                let travelled = -value.translation.height
                let landing = -value.predictedEndTranslation.height

                if isStatsUp {
                    // Up from open is the second pull: the whole window.
                    if landing > Self.stageThreshold {
                        openFull()
                    } else if landing < -Self.stageThreshold {
                        settle(to: false)
                    }
                } else {
                    // One long pull, all the way through the small stats and
                    // out the other side, goes straight to the window. Judged
                    // on where the finger actually went rather than on where a
                    // flick was heading, so a quick flick still lands on the
                    // figures instead of overshooting into a sheet.
                    if travelled > StatsPanel.height + Self.fullThreshold {
                        openFull()
                    } else if landing > Self.stageThreshold {
                        settle(to: true)
                    }
                }
            }
    }

    private func toggle() {
        settle(to: !isStatsUp)
    }

    private func settle(to open: Bool) {
        withAnimation(FlightInfoMotion.panel) {
            isStatsUp = open
        }
    }

    private func openFull() {
        onOpenStats()
    }
}
