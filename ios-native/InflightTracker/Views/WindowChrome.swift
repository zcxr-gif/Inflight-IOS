import SwiftUI

/// How a window is closed.
///
/// Every panel in the app used to close two ways, and neither of them was any
/// good. There was a cross in the corner — a button, sitting where a button on
/// a phone has no business being, and the only thing on the panel that had to
/// be aimed at. And there was the sheet's own pull-down, which worked when the
/// list underneath happened to be scrolled to the very top and did nothing at
/// all otherwise: the scroll view swallowed the drag, so a panel scrolled two
/// rows down could not be pulled shut. The way out of a window depended on
/// where the window happened to be scrolled to, which is why closing one felt
/// like it was fighting back.
///
/// So the window gets a real handle instead, and the handle is not part of what
/// scrolls. The grabber and the title are pinned above the content, and a pull
/// anywhere across them moves the whole window with the finger, one to one, all
/// the way off the bottom of the screen. Let go past the point of no return and
/// it goes; let go short of it and it springs back. A flick does it without the
/// travel, the way a flick closes anything else on the phone.
///
/// Everything below the header still scrolls, and the sheet's own drag still
/// works there when the list is at its top, so nothing that used to work
/// stopped working. What changed is that there is now always somewhere to grab.

// MARK: - The grabber

/// The pull bar at the top of a window.
///
/// Wider and taller than the system's indicator, because this one is not a
/// decoration saying "this sheet can move" — it is the control you actually
/// take hold of, and a five point pill with nothing around it is a target
/// nobody hits on the first go. The pill is the part you see; the part that
/// takes the touch is the whole band it sits in.
struct WindowGrabber: View {

    let theme: FlightInfoTheme

    /// Held under a finger: the bar swells and brightens, so the window says it
    /// has the drag before it has moved far enough to be obvious.
    var isHeld: Bool = false

    /// Drawn over the window's own content — a banner, a photograph — rather
    /// than on its ground. It needs something of its own behind it there, and
    /// it cannot take its colour from a theme when what is underneath it is
    /// somebody's holiday snap.
    var floating: Bool = false

    /// The band the pill sits in, which is what the finger is actually aiming
    /// at. Comfortably past the 44 point rule once the header under it is
    /// counted as part of the same surface.
    static let bandHeight: CGFloat = 26

    var body: some View {
        Capsule()
            .fill(fill)
            .frame(width: isHeld ? 56 : 44, height: isHeld ? 6 : 5)
            .padding(floating ? 6 : 0)
            .background {
                if floating {
                    Capsule().fill(Color.black.opacity(0.24))
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.bandHeight)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHeld)
    }

    private var fill: Color {
        floating
            ? Color.white.opacity(isHeld ? 0.95 : 0.72)
            : theme.textSecondary.opacity(isHeld ? 0.95 : 0.42)
    }
}

// MARK: - The window

/// A sheet you close by pulling it down: a pinned header that is the handle,
/// and content that scrolls underneath it.
///
/// The window draws its own ground rather than letting the sheet draw one. That
/// is what lets it move: the sheet's own background stays where it is — behind
/// everything, invisible — while the window slides over it, so what you see
/// coming out from under the top edge is the map rather than a band of empty
/// sheet. It only works because these panels are opaque. The flight window is
/// glass, and glass has to be the sheet's own background or it has nothing to
/// sample; that window keeps the system's detents and is handled where it is
/// presented.
struct SheetWindow<Header: View, Content: View>: View {

    let theme: FlightInfoTheme

    /// Whether the handle floats over the content rather than sitting in a
    /// band above it.
    ///
    /// For a window that opens on a full-bleed picture — a pilot's banner —
    /// where a strip of plain ground above the photograph reads as the
    /// photograph having been pushed down the window. A floating handle has no
    /// header under it: the pill is the whole pull surface.
    var handleFloats: Bool = false

    /// Pinned above the content and part of the pull surface: a drag anywhere
    /// across it moves the window.
    @ViewBuilder let header: Header

    /// Everything below. Free to scroll; nothing here is a drag target.
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    /// How far the finger has carried the window, downwards positive.
    @State private var offset: CGFloat = 0

    @GestureState private var isHeld = false

    /// Far enough down that letting go closes it. A little under an inch:
    /// short enough that closing never feels like a haul, long enough that the
    /// window is obviously on its way out before it commits.
    private static let closeDistance: CGFloat = 96

    /// ...or a flick that was going this fast, whatever distance it covered.
    /// Measured as the travel the drag was *predicted* to add, which is how
    /// every other flick on the phone is judged.
    private static let closeFlick: CGFloat = 150

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 30,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 30,
            style: .continuous
        )
    }

    var body: some View {
        stack
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { shape.fill(theme.windowFill) }
            // The window is clipped to its own shape rather than left to the
            // sheet to clip it. It has to be: it moves, and a banner drawn to
            // the top edge of an unclipped window would carry on out of the top
            // of it and sit square-cornered over the map.
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.stroke, lineWidth: 1) }
            // The whole window runs to the bottom of the screen, ground and
            // clip together, so there is no transparent strip under it and no
            // seam where the two disagree. Panels carry their own clearance at
            // the foot of their content, which is what the home indicator
            // floats over.
            .ignoresSafeArea(edges: .bottom)
            .offset(y: offset)
            // The window paints its own ground, so the sheet must not paint one
            // of its own behind it — that is the band the window would
            // otherwise be sliding across.
            .presentationBackground(Color.clear)
            .presentationDragIndicator(.hidden)
            // One stop. With a medium detent underneath, a pull down from the
            // top lands there instead of closing, so shutting a panel took two
            // full gestures — and a panel is a thing you open, read and close.
            .presentationDetents([.large])
            // VoiceOver's two-finger scrub, which is what a user who cannot
            // make the gesture reaches for.
            .accessibilityAction(.escape) { dismiss() }
    }

    /// Over the content, or above it.
    @ViewBuilder
    private var stack: some View {
        if handleFloats {
            content.overlay(alignment: .top) { grip }
        } else {
            VStack(spacing: 0) {
                grip
                content
            }
        }
    }

    /// The handle: the grabber, the header under it, and the drag over both.
    private var grip: some View {
        VStack(spacing: 0) {
            WindowGrabber(theme: theme, isHeld: isHeld, floating: handleFloats)
                .accessibilityElement()
                .accessibilityLabel("Close")
                .accessibilityHint("Pull the window down to close it")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { dismiss() }

            header
        }
        .frame(maxWidth: .infinity)
        // The gap between the title and the accessory beside it is part of the
        // handle too — the whole band pulls, not just the pill.
        .contentShape(Rectangle())
        .gesture(pull)
    }

    private var pull: some Gesture {
        // Global, deliberately. The window moves while the drag is in progress,
        // and a translation measured in a coordinate space that is itself
        // sliding is a translation that feeds its own movement back into
        // itself — which is exactly the shake a window develops the moment it
        // starts to follow your finger.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($isHeld) { _, state, _ in state = true }
            .onChanged { value in
                offset = Self.resisted(value.translation.height)
            }
            .onEnded { value in
                let travel = value.translation.height
                let flick = value.predictedEndTranslation.height - travel

                if travel > Self.closeDistance || flick > Self.closeFlick {
                    // Left where it is: the sheet's own dismissal carries on
                    // from here, so the window keeps going the way it was
                    // already heading rather than snapping back first.
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        offset = 0
                    }
                }
            }
    }

    /// How far a window will lift if it is pulled the wrong way.
    private static let liftLimit: CGFloat = 40

    /// Down is one to one; up is resisted, so a window pulled upwards gives a
    /// little and then keeps giving less, rather than lifting off the top of
    /// the screen or stopping dead as though the gesture had been dropped.
    private static func resisted(_ travel: CGFloat) -> CGFloat {
        guard travel < 0 else { return travel }
        let up = -travel
        return -(up * liftLimit / (up + 90))
    }
}

extension SheetWindow where Header == EmptyView {

    /// A window whose content carries its own title — the grabber alone is the
    /// pinned handle.
    init(
        theme: FlightInfoTheme,
        handleFloats: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            theme: theme,
            handleFloats: handleFloats,
            header: { EmptyView() },
            content: content
        )
    }
}
