import SwiftUI

/// Runtime appearance switches for the flight info window.
///
/// Every surface in the window is drawn through `FlightInfoTheme`, so flipping
/// `isGlassEnabled` restyles the whole sheet without any view knowing which
/// look is active — that is the switch the glass look hangs off. The choice is
/// persisted, and published so a toggle anywhere in the app restyles a sheet
/// that is already open.
final class FlightInfoAppearance: ObservableObject {

    static let shared = FlightInfoAppearance()

    private static let glassKey = "flightInfoGlassEnabled"

    @Published var isGlassEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlassEnabled, forKey: Self.glassKey) }
    }

    var theme: FlightInfoTheme { isGlassEnabled ? .glass : .solid }

    private init() {
        // No stored value means the user has never chosen, which is glass on.
        isGlassEnabled = UserDefaults.standard.object(forKey: Self.glassKey) as? Bool ?? true
    }
}

/// Design tokens for the flight info window.
///
/// Carried over from the web tracker's "Carbon & Titanium" theme: a monochrome
/// dark palette whose only accent is white. Flight phase is spelled out rather
/// than colour-coded, so the window never competes with the map underneath.
///
/// Adding a look means adding another `static let` here — nothing downstream
/// branches on which theme is in use.
struct FlightInfoTheme {

    /// Blur behind the window and its surfaces. `nil` is the opaque fallback,
    /// which is what glass-off resolves to.
    let material: Material?

    /// Painted over `material` (or on its own when opaque) as the sheet ground.
    let windowFill: Color

    /// Cards inside the window: route, progress, telemetry cells.
    let surfaceFill: Color

    /// One step brighter, for cards that sit on top of another surface.
    let elevatedFill: Color

    let stroke: Color
    let strokeStrong: Color

    let textPrimary: Color
    let textSecondary: Color
    let textDim: Color

    /// The single accent: progress fill, plane glyphs, phase dot.
    let accent: Color

    /// Drawn on top of `accent` — the glyph inside the route's plane badge.
    let onAccent: Color

    /// Unfilled part of a progress track.
    let trackFill: Color

    let radiusSmall: CGFloat = 10
    let radiusMedium: CGFloat = 14
    let radiusLarge: CGFloat = 20

    /// Phase accent. Deliberately the neutral accent for both shipping themes —
    /// a theme that wants per-phase colour changes this one method.
    func phaseAccent(for phase: FlightPhase) -> Color { accent }

    /// Sheet ground: the blur, plus the carbon tint that keeps text legible
    /// over bright terrain.
    @ViewBuilder
    var windowBackground: some View {
        if let material = material {
            Rectangle()
                .fill(windowFill)
                .background(material)
        } else {
            Rectangle().fill(windowFill)
        }
    }

    static let glass = FlightInfoTheme(
        material: .ultraThinMaterial,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.55),
        surfaceFill: Color.white.opacity(0.07),
        elevatedFill: Color.white.opacity(0.11),
        stroke: Color.white.opacity(0.10),
        strokeStrong: Color.white.opacity(0.16),
        textPrimary: Color(white: 0.98),
        textSecondary: Color(white: 0.66),
        textDim: Color(white: 0.42),
        accent: .white,
        onAccent: Color(red: 0.09, green: 0.09, blue: 0.11),
        trackFill: Color.white.opacity(0.14)
    )

    static let solid = FlightInfoTheme(
        material: nil,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        surfaceFill: Color(white: 0.16),
        elevatedFill: Color(white: 0.20),
        stroke: Color.white.opacity(0.08),
        strokeStrong: Color.white.opacity(0.13),
        textPrimary: Color(white: 0.98),
        textSecondary: Color(white: 0.66),
        textDim: Color(white: 0.42),
        accent: .white,
        onAccent: Color(red: 0.09, green: 0.09, blue: 0.11),
        trackFill: Color.white.opacity(0.12)
    )
}

extension View {

    /// Card background for the flight info window: the theme's blur where glass
    /// is on, a flat fill where it isn't, hairline stroke either way.
    func flightInfoSurface(
        _ theme: FlightInfoTheme,
        radius: CGFloat,
        elevated: Bool = false
    ) -> some View {
        modifier(FlightInfoSurfaceModifier(theme: theme, radius: radius, elevated: elevated))
    }
}

struct FlightInfoSurfaceModifier: ViewModifier {

    let theme: FlightInfoTheme
    let radius: CGFloat
    let elevated: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var fill: Color {
        elevated ? theme.elevatedFill : theme.surfaceFill
    }

    func body(content: Content) -> some View {
        content
            .background {
                // The window already blurs the map; surfaces only need their
                // tint on top of it, which keeps the stack cheap to composite.
                shape.fill(fill)
            }
            .overlay {
                shape.strokeBorder(elevated ? theme.strokeStrong : theme.stroke, lineWidth: 1)
            }
            .clipShape(shape)
    }
}

extension PresentationDetent {

    /// The peak state: the compact bar the info window opens in, sized so the
    /// identity row and the route card are fully on screen and nothing else is.
    static let flightInfoPeak = PresentationDetent.height(300)
}
