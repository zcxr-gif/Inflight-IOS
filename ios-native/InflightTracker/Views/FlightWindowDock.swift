import SwiftUI

/// The shape of anything that stands on the bottom edge of the screen: rounded
/// along the top, square along the bottom.
///
/// Square because the bottom is not the window's edge to round. It runs off the
/// foot of the display, and the display's own corners do the rounding — so the
/// window sits down into both of them instead of hovering above them as a card
/// with four corners of its own.
enum BottomEdge {

    /// The radius along the top. The dock and the flight window share it, so
    /// the one that replaces the other is recognisably the same object.
    static let cornerRadius: CGFloat = 30

    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
    }
}

/// The dock's measurements. Outside the view because the view is generic over
/// its content, and a generic type cannot hold stored statics.
enum FlightWindowDockMetrics {

    /// Room left above the full window, under the status bar.
    static let topGap: CGFloat = 8

    /// How far a pull has to be heading before it moves the window to another
    /// stop. Judged on where the flick would land, so a short flick does it.
    static let stepTravel: CGFloat = 60

    /// How far past the peek a pull has to go to close the window. Longer than
    /// a step, so the window is never a nudge away from being gone.
    static let closeTravel: CGFloat = 90

    /// How far the window gives above the full stop, however hard it is pulled.
    static let overshootLimit: CGFloat = 24
}

/// The flight window on a phone: standing on the bottom edge, side to side,
/// rather than presented as a sheet.
///
/// It used to be a sheet, and on iOS 26 a sheet at any height short of the full
/// screen is inset — it floats, with a gap down both sides and under its foot,
/// and only joins the edges of the display once it is pulled all the way open.
/// There is no switch for that. So the window is laid out here instead, the way
/// the pane is on a tablet, and it is flush with the bottom and both sides at
/// its peek as well as at full height.
///
/// Two stops, the same two the sheet had: the peek, which is whatever height
/// the window measured itself at, and the full window under the status bar.
/// The content is handed the height it is being drawn at on every frame of a
/// pull, so the cross-fade between the peek and the open window rides the
/// finger exactly as it did on the sheet.
struct FlightWindowDock<Content: View>: View {

    let theme: FlightInfoTheme

    /// What the peek measured, not counting the band along the bottom of the
    /// screen the home indicator sits in — the window adds that underneath, so
    /// the peek's content clears it.
    let peakHeight: CGFloat

    @Binding var isExpanded: Bool

    let onClose: () -> Void

    @ViewBuilder let content: Content

    /// How far the finger has carried the window, downwards positive. Let go
    /// with the same spring the window settles on, so a window dropped half way
    /// eases to its stop rather than snapping.
    @GestureState(resetTransaction: Transaction(animation: Motion.chrome))
    private var pull: CGFloat = 0

    @GestureState private var isHeld = false

    var body: some View {
        GeometryReader { geometry in
            // The reader runs down to the foot of the screen, so what it
            // reports as the bottom of its safe area is the band the home
            // indicator sits in.
            let bottomBand = geometry.safeAreaInsets.bottom
            let full = max(geometry.size.height - FlightWindowDockMetrics.topGap, 0)
            let resting = isExpanded ? full : min(peakHeight + bottomBand, full)
            let height = drawnHeight(resting: resting, full: full)

            // Deaf to touches everywhere but the window itself: the map is live
            // underneath and has to keep getting its pans and taps.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .bottom) {
                    window(height: height)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// Where the window is, with the finger taken into account. Down is free
    /// all the way to nothing; up stops at the full window, with a little give.
    private func drawnHeight(resting: CGFloat, full: CGFloat) -> CGFloat {
        let raw = resting - pull
        guard raw > full else { return max(raw, 0) }
        let past = raw - full
        // Asymptotic rather than clamped, so the stop is felt rather than hit.
        return full + past * FlightWindowDockMetrics.overshootLimit / (past + 60)
    }

    private func window(height: CGFloat) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .background { theme.sheetBackground }
            .clipShape(BottomEdge.shape)
            .overlay {
                BottomEdge.shape
                    .stroke(theme.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) { grabber }
            .shadow(color: .black.opacity(0.22), radius: 18, y: -2)
            // The whole window is the thing to pull at its peek, which does not
            // scroll. Open, the window is a scroll view, and a pull anywhere on
            // it would be a fight with the list — so there it is the grabber
            // along the top, which carries the same gesture.
            .simultaneousGesture(pullGesture, including: isExpanded ? GestureMask.subviews : GestureMask.all)
            .motion(Motion.chrome, value: isExpanded)
            .motion(Motion.chrome, value: peakHeight)
            .environment(\.colorScheme, theme.colorScheme)
    }

    /// The pill along the top. Pulling it moves the window a stop; a tap shuts
    /// it, which is the one way out that needs nothing discovered.
    private var grabber: some View {
        WindowGrabber(theme: theme, isHeld: isHeld)
            .frame(width: 132)
            .frame(maxWidth: .infinity)
            // Only while the window is open. At the peek the whole window
            // already carries this gesture, and two copies of it would both
            // act on one pull.
            .gesture(pullGesture, including: isExpanded ? GestureMask.all : GestureMask.none)
            .onTapGesture { onClose() }
            .accessibilityElement()
            .accessibilityLabel("Close the flight window")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
            .accessibilityAction(named: isExpanded ? "Show less" : "Open the full window") {
                isExpanded.toggle()
            }
    }

    /// Measured against the screen: the window grows and shrinks under the
    /// finger, and a translation read in a space that is itself moving fights
    /// itself.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isHeld) { _, state, _ in state = true }
            .updating($pull) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let travelled = value.translation.height
                let landing = value.predictedEndTranslation.height

                withAnimation(Motion.chrome) {
                    if isExpanded {
                        if landing > FlightWindowDockMetrics.stepTravel { isExpanded = false }
                    } else if landing < -FlightWindowDockMetrics.stepTravel {
                        isExpanded = true
                    } else if travelled > FlightWindowDockMetrics.closeTravel || landing > FlightWindowDockMetrics.closeTravel * 1.6 {
                        onClose()
                    }
                }
            }
    }
}
