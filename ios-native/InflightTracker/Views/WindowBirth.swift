import SwiftUI

/// Windows are born from the dock.
///
/// Every window that opens over the map — the flight window, a field's window,
/// the map's own window — grows out of the island the toolbar stands in, and
/// goes back into it when it closes. The island's glass is what moves: it
/// starts as the island, in the island's place and the island's shape, opens
/// out to the window's frame, and only then does the window's content come up
/// through it. Closing runs the same thing backwards, so the window folds back
/// into the bar it came out of rather than dropping off the screen — and at the
/// island it dissolves into the bar itself rather than landing on top of it.
///
/// Two pieces. `AnyTransition.bornFromDock` is the transition a window is
/// inserted and removed with: all it does is hand its progress down. The
/// window's own surface reads that progress through `bornFromDock(theme:...)`,
/// which knows the window's frame and so can draw the island inside it.
extension AnyTransition {

    static var bornFromDock: AnyTransition {
        .modifier(
            active: WindowBirthProgress(progress: 0),
            identity: WindowBirthProgress(progress: 1)
        )
    }
}

/// How far a window is through being born: 0 is the island, 1 the window.
private struct WindowBirthKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

/// Where the island stands, in global coordinates, for windows to grow from.
/// Zero until the map has measured itself, and a window with nothing to grow
/// from simply appears.
private struct DockIslandKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}

extension EnvironmentValues {
    var windowBirth: Double {
        get { self[WindowBirthKey.self] }
        set { self[WindowBirthKey.self] = newValue }
    }

    var dockIsland: CGRect {
        get { self[DockIslandKey.self] }
        set { self[DockIslandKey.self] = newValue }
    }
}

/// The transition's half: animated by SwiftUI from 0 to 1 on the way in and
/// back on the way out, and passed down to whatever surface is listening.
private struct WindowBirthProgress: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.windowBirth, progress)
    }
}

extension View {

    /// The window's own surface, born from the island. Applied to the view
    /// whose frame *is* the window — inside its shadow, so the shadow follows
    /// the glass as it grows — with the corners the window has once it is out.
    ///
    /// The shadow, when there is one, is cast from the same outline as it
    /// grows — see `ShapeShadow` for why it is drawn here rather than put on
    /// the window with `.shadow`.
    func bornFromDock(
        theme: FlightInfoTheme,
        topRadius: CGFloat,
        bottomRadius: CGFloat,
        shadow: WindowShadow? = nil
    ) -> some View {
        modifier(BornFromDock(theme: theme, topRadius: topRadius, bottomRadius: bottomRadius, shadow: shadow))
    }
}

private struct BornFromDock: ViewModifier {

    let theme: FlightInfoTheme
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let shadow: WindowShadow?

    @Environment(\.windowBirth) private var birth
    @Environment(\.dockIsland) private var island

    /// The window's own frame, in the same space as the island's.
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        let progress = CGFloat(min(max(birth, 0), 1))
        let start = island.isEmpty || frame.isEmpty
            ? nil
            : island.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let shaped = start == nil ? 1 : progress
        let outline = BirthShape(
            progress: shaped,
            start: start ?? .zero,
            topRadius: topRadius,
            bottomRadius: bottomRadius
        )

        return content
            // The island's glass over the window's content while it is still
            // the island, thinning to nothing as the window arrives.
            .overlay {
                theme.sheetBackground
                    .opacity(Self.veil(progress))
                    .allowsHitTesting(false)
            }
            .clipShape(outline)
            .background {
                if let shadow {
                    ShapeShadow(shape: outline, color: shadow.color, radius: shadow.radius, y: shadow.y)
                        .allowsHitTesting(false)
                }
            }
            // And the window itself handed over to the bar at the island end,
            // rather than standing on top of it. See `presence`.
            .opacity(Self.presence(shaped))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    /// How much of the window there is at all, glass and shadow together.
    ///
    /// Whole until the last stretch before the island, then gone by the time
    /// it gets there. The bar fades back in underneath as a window closes, and
    /// the glass used to arrive at the island opaque, in the window's own
    /// colour rather than the bar's, and sit on top of the bar until the very
    /// last frame — an empty dark slab where the toolbar should be, for a beat,
    /// and then the real bar popping in under it. Fading out over the same
    /// stretch the bar fades in, the window lands *as* the bar. Opening, it is
    /// the same dissolve the other way: the bar into the window's glass, which
    /// then grows.
    static func presence(_ progress: CGFloat) -> Double {
        let end: CGFloat = 0.35
        guard progress < end else { return 1 }
        let t = max(progress, 0) / end
        return Double(t * t * (3 - 2 * t))
    }

    /// The island's glass stays whole for the first third of the growth, so
    /// what moves reads as the bar opening out, and is gone a little before
    /// the window lands, so the content is there when it does.
    static func veil(_ progress: CGFloat) -> Double {
        let start: CGFloat = 0.3
        let end: CGFloat = 0.85
        if progress <= start { return 1 }
        if progress >= end { return 0 }
        return Double(1 - (progress - start) / (end - start))
    }
}

/// The window's outline on the way between the island and itself: the
/// island's rectangle and corners at 0, the window's own at 1.
private struct BirthShape: Shape {

    var progress: CGFloat
    var start: CGRect
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let p = progress
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }

        let frame = p >= 1 ? rect : CGRect(
            x: mix(start.minX, rect.minX),
            y: mix(start.minY, rect.minY),
            width: mix(start.width, rect.width),
            height: mix(start.height, rect.height)
        )
        let island = MapDock.cornerRadius
        let top = min(mix(island, topRadius), frame.height / 2, frame.width / 2)
        let bottom = min(mix(island, bottomRadius), frame.height / 2, frame.width / 2)

        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
        .path(in: frame)
    }
}
