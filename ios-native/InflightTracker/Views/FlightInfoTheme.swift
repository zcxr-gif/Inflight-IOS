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

/// Design tokens for the flight info window: a monochrome carbon palette whose
/// only accent is white, so the window never competes with the map underneath.
///
/// Adding a look means adding another `static let` here — nothing downstream
/// branches on which theme is in use.
struct FlightInfoTheme {

    /// Blur used for the sheet's own background. `nil` is the opaque fallback,
    /// which is what glass-off resolves to.
    let material: Material?

    /// Opaque sheet ground, used when glass is off and on iOS versions with no
    /// `presentationBackground`.
    let windowFill: Color

    /// Darkens the blur just enough to keep white text legible over snow,
    /// desert and daylight ocean. Deliberately light — heavier tints turn the
    /// window into a black slab.
    let scrim: Color

    /// Cards inside the window: route, telemetry cells.
    let surfaceFill: Color

    /// One step brighter, for chips that sit on top of a photo or a card.
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

    let radiusSmall: CGFloat = 12
    let radiusMedium: CGFloat = 16
    let radiusLarge: CGFloat = 22

    /// Phase accent. Deliberately the neutral accent for both shipping themes —
    /// a theme that wants per-phase colour changes this one method.
    func phaseAccent(for phase: FlightPhase) -> Color { accent }

    /// The sheet's own background.
    ///
    /// This has to be the *sheet's* background rather than a layer inside the
    /// content: a material only blurs what sits behind it in the same render
    /// tree, so a material drawn inside a sheet whose background was cleared
    /// has nothing to sample and renders as a near-black slab.
    @ViewBuilder
    var sheetBackground: some View {
        if let material = material {
            Rectangle()
                .fill(material)
                .overlay { Rectangle().fill(scrim) }
        } else {
            Rectangle().fill(windowFill)
        }
    }

    static let glass = FlightInfoTheme(
        material: .ultraThinMaterial,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        scrim: Color.black.opacity(0.16),
        surfaceFill: Color.white.opacity(0.08),
        elevatedFill: Color.white.opacity(0.14),
        stroke: Color.white.opacity(0.10),
        strokeStrong: Color.white.opacity(0.16),
        textPrimary: Color(white: 0.98),
        textSecondary: Color(white: 0.70),
        textDim: Color(white: 0.48),
        accent: .white,
        onAccent: Color(red: 0.09, green: 0.09, blue: 0.11),
        trackFill: Color.white.opacity(0.16)
    )

    static let solid = FlightInfoTheme(
        material: nil,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        scrim: .clear,
        surfaceFill: Color(white: 0.15),
        elevatedFill: Color(white: 0.21),
        stroke: Color.white.opacity(0.08),
        strokeStrong: Color.white.opacity(0.13),
        textPrimary: Color(white: 0.98),
        textSecondary: Color(white: 0.70),
        textDim: Color(white: 0.48),
        accent: .white,
        onAccent: Color(red: 0.09, green: 0.09, blue: 0.11),
        trackFill: Color.white.opacity(0.14)
    )
}

extension View {

    /// Card background for the flight info window.
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

    func body(content: Content) -> some View {
        content
            .background {
                // The sheet already blurs the map; cards only need their tint
                // on top of it, which keeps the layer stack cheap.
                shape.fill(elevated ? theme.elevatedFill : theme.surfaceFill)
            }
            .overlay {
                shape.strokeBorder(elevated ? theme.strokeStrong : theme.stroke, lineWidth: 1)
            }
            .clipShape(shape)
    }
}

/// Fixed measurements the window and its sheet have to agree on.
enum FlightInfoLayout {

    /// Height of the peak state.
    static let peakHeight: CGFloat = 322

    /// How far above the peak height the phases have finished swapping. The
    /// cross-fade rides the drag rather than the detent, so it wants to be
    /// done early in the travel — by the time the sheet is a third of the way
    /// up, the full window should already be the thing you are looking at.
    static let phaseTravel: CGFloat = 220
}

extension PresentationDetent {

    /// The peak state: the compact bar the info window opens in.
    static let flightInfoPeak = PresentationDetent.height(FlightInfoLayout.peakHeight)
}

extension View {

    /// Keeps the map live behind the peak state: the sheet stops being modal
    /// up through that detent, so panning and zooming still reach the map —
    /// and the system stops dimming everything behind the sheet, which is what
    /// put a dark wash over the map as soon as the window opened.
    @ViewBuilder
    func flightInfoSheetInteraction() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackgroundInteraction(.enabled(upThrough: .flightInfoPeak))
        } else {
            self
        }
    }
}
