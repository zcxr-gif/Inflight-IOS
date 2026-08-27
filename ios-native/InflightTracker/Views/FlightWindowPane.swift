import SwiftUI

/// The pane's measurements.
///
/// Outside the view, and not because the view is generic over its content —
/// though that alone would make `FlightWindowPane<EmptyView>.margin` the way to
/// ask, which is a silly thing to have to write. The real reason is that the
/// map's own chrome has to know them: the follow-and-frame hub sits in the
/// corner the column stands in, and the camera has to avoid framing a route
/// underneath it. One place to change a number that several views depend on.
enum FlightWindowPaneMetrics {

    /// The gap between the pane and the edges of the screen.
    ///
    /// The same figure the map's own chrome is inset by, so the window lines up
    /// with the search field above it and the controls beside it rather than
    /// sitting on a margin of its own.
    static let margin: CGFloat = 14

    /// How wide the column down the right-hand edge is.
    ///
    /// Capped as well as proportional. A share of the width alone gives a
    /// sensible column on an 11-inch iPad and an absurd one on a 13-inch in
    /// landscape — the window's content is a single column of cards, and past
    /// four hundred points it is not a window any more, it is a wall.
    static let trailingWidth: CGFloat = 400
    static let trailingShare: CGFloat = 0.42

    /// The centred pane's shape.
    ///
    /// Wider than the column, because it is not competing with the map for the
    /// same axis, and shorter than the screen: the point of leaving it low is
    /// that there is map above it.
    static let centredWidth: CGFloat = 460
    static let centredHeight: CGFloat = 620

    /// How much of the bottom of the screen a pane in this placement is
    /// standing on, margins included — for the camera, and for the chrome that
    /// has to sit above it.
    ///
    /// The column covers no part of the bottom of the map at all. It covers the
    /// side, which is a different inset and the next question down.
    ///
    /// Read as the figure the pane asks for rather than the one it got: on a
    /// screen too short for the whole centred window this over-reports by the
    /// difference. Generous is the side of this to be wrong on — the cost is a
    /// route framed a little higher than it needed to be, where under-reporting
    /// puts it behind the window.
    static func bottomInset(for placement: FlightWindowPlacement) -> CGFloat {
        switch placement {
        case .centred: return centredHeight + margin * 2
        case .trailing: return 0
        }
    }

    /// And the same for the trailing edge.
    static func trailingInset(for placement: FlightWindowPlacement) -> CGFloat {
        switch placement {
        case .centred: return 0
        case .trailing: return trailingWidth + margin * 2
        }
    }
}

/// The flight window as a pane on the map, rather than a sheet over it.
///
/// A phone presents the window as a sheet, and everything about that is right
/// there: it comes up from the bottom edge, it has a peak state so the map is
/// still worth looking at behind it, and the system's own gesture resizes it.
/// None of that survives the move to a tablet. A sheet on a regular-width
/// screen is presented as a form sheet — a card floating in the middle of the
/// display, its size and position the system's business rather than ours,
/// sitting squarely over the part of the map you just tapped. There is no API
/// to move it, so on a screen with room to make a choice the window stops being
/// a sheet at all and becomes a pane the app lays out itself.
///
/// What that buys, beyond position: the map underneath stays completely live —
/// no presentation, so nothing to dim and nothing to dismiss around — and the
/// window is the whole window rather than a peak you have to drag open. There
/// is space for it, which is the entire reason a tablet is different.
struct FlightWindowPane<Content: View>: View {

    let theme: FlightInfoTheme
    let placement: FlightWindowPlacement
    let onClose: () -> Void

    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            // Sized against what is left after the margins rather than against
            // the whole screen, so the clamps below are clamps on the space the
            // pane can actually have. On a narrow split of an iPad both figures
            // fall back to the available room and the pane simply fills it.
            let available = CGSize(
                width: max(geometry.size.width - FlightWindowPaneMetrics.margin * 2, 0),
                height: max(geometry.size.height - FlightWindowPaneMetrics.margin * 2, 0)
            )

            // Flexible, so the padding below shrinks what the overlay is
            // aligned within instead of pushing the pane off the screen.
            //
            // Deaf to touches, and the order matters: the map is a live view
            // underneath rather than a backdrop, so everything outside the
            // pane's own rectangle has to reach it — and a `Color`, clear or
            // not, is a filled shape that would otherwise swallow the lot. The
            // overlay is hung on the result, after that has been applied, so it
            // keeps its own touches. Written the other way round — the whole
            // stack silenced and the pane trying to opt back in — it would not
            // work at all: nothing inside a subtree that has been switched off
            // can switch itself back on.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: alignment) {
                    window
                        .frame(width: width(in: available), height: height(in: available))
                }
                .padding(FlightWindowPaneMetrics.margin)
        }
    }

    /// The pane itself: the window's content on the same glass the sheet uses,
    /// clipped to the same radius, with the one control a pane needs.
    ///
    /// A sheet is closed by pulling it down, and a pane has nothing to pull it
    /// against — so the way out is a button. It is the only piece of chrome
    /// either placement has that the sheet does not.
    ///
    /// The ground is the same `sheetBackground` the sheet hangs behind itself,
    /// and it is better off here: the note on that property is about a
    /// presentation being unable to sample what is behind it, and a pane is in
    /// the same render tree as the map it is lying on. The glass has something
    /// real to lens.
    private var window: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { theme.sheetBackground }
            .flightInfoGlassGround(theme)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.stroke, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) { closeButton }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .environment(\.colorScheme, theme.colorScheme)
    }

    /// The same radius the sheet is given, so the window is recognisably the
    /// same object on both devices.
    private var cornerRadius: CGFloat { theme.radiusLarge + 6 }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 30, height: 30)
                .background { Circle().fill(theme.elevatedFill) }
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel("Close the flight window")
    }

    /// Low, not middle. A window in the dead centre of a tablet covers the
    /// aircraft that opened it, which is the one thing on the map you are
    /// certain to be looking at.
    private var alignment: Alignment {
        switch placement {
        case .centred: return .bottom
        case .trailing: return .trailing
        }
    }

    private func width(in available: CGSize) -> CGFloat {
        switch placement {
        case .centred:
            return min(FlightWindowPaneMetrics.centredWidth, available.width)

        case .trailing:
            let share = max(available.width * FlightWindowPaneMetrics.trailingShare, 0)
            return min(FlightWindowPaneMetrics.trailingWidth, share)
        }
    }

    private func height(in available: CGSize) -> CGFloat {
        switch placement {
        case .centred: return min(FlightWindowPaneMetrics.centredHeight, available.height)
        case .trailing: return available.height
        }
    }
}

/// How the flight window is on screen.
///
/// Not a setting and not a placement — that is `FlightWindowPlacement`, which is
/// a choice somebody makes. This is the mechanism underneath it: a sheet the
/// system presents, or a pane the app lays out. A phone has no choice to make
/// and is always the first; a screen wide enough to offer the choice is always
/// the second, whichever of the two placements it lands on.
enum FlightWindowPresentation {
    case sheet
    case pane
}
