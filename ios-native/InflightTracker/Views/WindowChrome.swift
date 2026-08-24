import SwiftUI

/// How a window is closed, and what it is made of.
///
/// Closing a panel used to depend on where it happened to be scrolled to. The
/// header scrolled away with the content, so the only thing left to take hold
/// of was the list — and a list swallows a downward drag. The sheet's own
/// pull-to-dismiss worked when the list happened to be at its very top and did
/// nothing at all otherwise, which is why the cross in the corner ended up
/// being the real way out: a quarter-inch target in the one place on a phone a
/// thumb does not reach.
///
/// The fix is structural rather than a gesture of our own. The grabber and the
/// title are *pinned* — they are not inside the scroll view — so there is
/// always a band across the top of the window that is not a list. UIKit's own
/// sheet gesture takes it from there: the window follows the finger one to
/// one, rubber-bands at the top, closes on a flick, and springs back if you
/// change your mind, exactly the way every other sheet on the phone behaves.
/// Nothing here re-implements any of that, because a hand-rolled version of a
/// system gesture is a gesture that feels almost right.
///
/// And the window is glass. It is presented *as* the sheet's background rather
/// than drawn as a layer inside the content, and that distinction is the whole
/// game: glass samples what is behind it, and what is behind a layer inside a
/// sheet is the sheet — so glass drawn there has nothing to lens and comes out
/// as a flat slab. Hung on the sheet itself it has the map behind it, which is
/// what makes a panel read as a pane of glass laid over the world instead of a
/// grey card that happens to be on top of one.

// MARK: - The grabber

/// The pull bar at the top of a window.
///
/// A little wider and a good deal taller than the system's indicator, because
/// this one is doing a job: it marks the band that is not a list, which is the
/// band the sheet's gesture can be started from. The pill is the part you see;
/// the part that takes the touch is the whole strip it sits in, and the header
/// under it counts too.
struct WindowGrabber: View {

    let theme: FlightInfoTheme

    /// Held under a finger. Only the flight window sets this — it is the one
    /// place with a gesture of our own, because it has two stops and the system
    /// will not close it from the upper one.
    var isHeld: Bool = false

    /// Drawn over the window's own content — a banner, a photograph — rather
    /// than on its ground. It needs something of its own behind it there, and
    /// it cannot take its colour from a theme when what is underneath it is
    /// somebody's holiday snap.
    var floating: Bool = false

    /// The band the pill sits in, which is what the finger is actually aiming
    /// at.
    static let bandHeight: CGFloat = 26

    var body: some View {
        Capsule()
            .fill(fill)
            .frame(width: isHeld ? 52 : 40, height: isHeld ? 6 : 5)
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
            : theme.textSecondary.opacity(isHeld ? 0.95 : 0.45)
    }
}

// MARK: - The window

/// A window on glass: a pinned handle, and content that scrolls under it.
struct SheetWindow<Header: View, Content: View>: View {

    let theme: FlightInfoTheme

    /// Whether the handle floats over the content rather than sitting in a
    /// band above it.
    ///
    /// For a window that opens on a full-bleed picture — a pilot's banner —
    /// where a strip of ground above the photograph reads as the photograph
    /// having been pushed down the window. A floating handle has no header
    /// under it: the pill is the whole marker.
    var handleFloats: Bool = false

    /// Pinned above the content, and the reason the window can be pulled shut
    /// from anywhere in a list: this band is not part of what scrolls.
    @ViewBuilder let header: Header

    /// Everything below. Free to scroll.
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        stack
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The ground, hung on the sheet rather than drawn inside it. See
            // the note at the top of the file: this is the difference between
            // a pane of glass over the map and a grey card.
            .presentationBackground { theme.sheetBackground }
            .presentationCornerRadius(theme.radiusLarge + 8)
            // Our own pill, in the pinned band, instead of the system's
            // floating one — two indicators in the same place would be one too
            // many.
            .presentationDragIndicator(.hidden)
            // One stop. With a medium detent underneath, a pull down from the
            // top lands there instead of closing, so shutting a panel took two
            // full gestures — and a panel is a thing you open, read and close.
            .presentationDetents([.large])
            // And this is what lets the glass be glass.
            //
            // iOS lays a dimming view over everything behind a modal sheet, and
            // a pane of glass with a grey wash behind it has nothing left to
            // lens: it renders as the flat card the whole design was trying not
            // to be. Marking the sheet non-modal takes the wash away, so what
            // is behind the window is the map — which is the only thing that
            // makes a window read as glass rather than as a card that has been
            // told it is one. The flight window has always done this; it is why
            // that one looked like glass and the panels did not.
            .presentationBackgroundInteraction(.enabled(upThrough: .large))
            // VoiceOver's two-finger scrub, for anyone who cannot make the
            // gesture.
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

    /// The pinned band. No gesture of its own — that is the point. It is a
    /// piece of the window that does not scroll, which is all the sheet's own
    /// dismissal ever needed.
    private var grip: some View {
        VStack(spacing: 0) {
            WindowGrabber(theme: theme, floating: handleFloats)
                .accessibilityElement()
                .accessibilityLabel("Close")
                .accessibilityHint("Pull the window down to close it")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { dismiss() }

            header
        }
        .frame(maxWidth: .infinity)
        // So the gaps in the header — beside the title, around the accessory —
        // are draggable window rather than holes the gesture falls through.
        .contentShape(Rectangle())
    }
}

extension SheetWindow where Header == EmptyView {

    /// A window whose content carries its own title — the grabber alone is the
    /// pinned band.
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
