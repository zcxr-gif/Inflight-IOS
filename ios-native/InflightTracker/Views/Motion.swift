import SwiftUI

/// One vocabulary of movement, for the whole app.
///
/// Before this the durations were written wherever they were needed, and the
/// app moved in four or five different ways: `easeInOut(duration: 0.22)` on the
/// map's chrome, a spring on the window's grabber, an unqualified `withAnimation`
/// on a panel row, and nothing at all in most places — where "nothing" means the
/// system's default, which is a different curve again. Individually every one of
/// those is defensible. Together they are why opening a panel and opening a
/// window did not feel like the same app doing two things.
///
/// So: four curves, named for what is moving rather than for how long they take,
/// and one rule for choosing between them — the bigger the thing, the softer it
/// lands.
///
/// They are springs rather than eased durations, and that is the substantive
/// change rather than a stylistic one. An eased animation has a fixed length: a
/// second gesture arriving part-way through the first has to wait for it, so a
/// quick double-tap through the toolbar reads as a stutter. A spring is
/// retargetable — interrupt it and it carries its current velocity into the new
/// destination — which is what makes the same two taps read as one continuous
/// movement. Every one here is critically enough damped not to wobble; the
/// bounce that gives a spring away is the part nobody asked for.
enum Motion {

    /// A whole panel or window settling: the largest thing that moves.
    ///
    /// Slowest of the four, because the eye tracks a large object's edges and a
    /// big surface that arrives quickly reads as having been snapped into place
    /// rather than having moved.
    static let panel = Animation.spring(response: 0.42, dampingFraction: 0.88)

    /// A section or a row appearing, disappearing, or changing height.
    static let row = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// A switch, a chip, a button under a thumb. Quick, because it is answering
    /// a touch and anything slower than the finger reads as lag.
    static let control = Animation.spring(response: 0.24, dampingFraction: 0.82)

    /// Text or a number changing in place, and anything cross-fading.
    ///
    /// Barely a spring: nothing here has any distance to travel, so this is
    /// about the fade being smooth rather than about the movement.
    static let content = Animation.spring(response: 0.26, dampingFraction: 0.95)

    /// The map's own furniture — the dock, the toolbar, the bars that slide in
    /// over the top of it.
    static let chrome = Animation.spring(response: 0.36, dampingFraction: 0.88)

    /// How far apart consecutive sections start, when a panel deals its
    /// contents out rather than showing them all at once.
    ///
    /// Small on purpose. A stagger is meant to be felt rather than watched: at
    /// 40ms a panel of eight sections is fully in view in under a third of a
    /// second, and anything longer turns opening a settings screen into an
    /// animation somebody has to sit through every single time.
    static let stagger: Double = 0.04

    /// The maximum any one section will wait, whatever its index.
    ///
    /// Without a ceiling, a long panel's last section arrives noticeably after
    /// its first — and the panel that most needs to feel quick to open is the
    /// one with the most in it.
    static let maximumStagger: Double = 0.28

    static func entrance(index: Int) -> Animation {
        row.delay(min(Double(index) * stagger, maximumStagger))
    }
}

// MARK: - Arriving

/// A section that fades and lifts into place rather than being there already.
///
/// Only ever on first appearance. A panel whose sections re-animated every time
/// a switch inside one of them was flipped would be a panel that flinches when
/// you use it.
private struct PanelEntrance: ViewModifier {

    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasArrived = false

    func body(content: Content) -> some View {
        content
            .opacity(hasArrived ? 1 : 0)
            // Small. The movement is there to give the fade a direction, not to
            // be a movement — twelve points is under a row's height, so nothing
            // ever appears to come in from off the card.
            .offset(y: hasArrived ? 0 : 12)
            .onAppear {
                guard !hasArrived else { return }
                // Somebody who has asked the system for less movement gets the
                // content, immediately, with no animation at all — rather than
                // the same animation played more politely.
                if reduceMotion {
                    hasArrived = true
                } else {
                    withAnimation(Motion.entrance(index: index)) { hasArrived = true }
                }
            }
    }
}

extension View {

    /// Deals this view into a panel, `index` places down the list.
    func panelEntrance(_ index: Int) -> some View {
        modifier(PanelEntrance(index: index))
    }

    /// Animates a value change with the app's own curve, and honours Reduce
    /// Motion — which a bare `.animation(_:value:)` does not.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionValue(animation: animation, value: value))
    }
}

private struct MotionValue<V: Equatable>: ViewModifier {

    let animation: Animation
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Pressing

/// The give under a thumb.
///
/// SwiftUI's `.plain` button style has none — which is right for a row in a
/// list, and wrong for a tile or a chip, where the tap is the whole point and
/// nothing else on screen acknowledges it. The scale is deliberately slight:
/// enough to be felt through a finger that is covering the thing it is pressing,
/// which is the only way this is ever seen.
struct PressableButtonStyle: ButtonStyle {

    var scale: CGFloat = 0.96
    var dims: Bool = true

    /// The body is a real `View` rather than the label with modifiers hung off
    /// it, and that is not tidiness.
    ///
    /// A `ButtonStyle` is not a `View`, so `@Environment` declared on one is
    /// never populated — it silently reads the property wrapper's default and
    /// keeps doing so forever. Reduce Motion would have been permanently off
    /// for everybody who had switched it on, which is the one audience it
    /// exists for. Read from inside something SwiftUI actually installs in the
    /// hierarchy, it works.
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration, scale: scale, dims: dims)
    }

    private struct Pressed: View {

        let configuration: PressableButtonStyle.Configuration
        let scale: CGFloat
        let dims: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
                .opacity(dims && configuration.isPressed ? 0.82 : 1)
                .animation(reduceMotion ? nil : Motion.control, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {

    /// A button that gives slightly under a thumb.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    static func pressable(scale: CGFloat) -> PressableButtonStyle {
        PressableButtonStyle(scale: scale)
    }
}
