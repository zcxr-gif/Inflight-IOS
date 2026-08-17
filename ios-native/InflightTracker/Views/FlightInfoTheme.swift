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
    private static let peakStyleKey = "flightInfoPeakStyle"

    @Published var isGlassEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlassEnabled, forKey: Self.glassKey) }
    }

    @Published var peakStyle: FlightInfoPeakStyle {
        didSet { UserDefaults.standard.set(peakStyle.rawValue, forKey: Self.peakStyleKey) }
    }

    var theme: FlightInfoTheme { isGlassEnabled ? .glass : .solid }

    private init() {
        let defaults = UserDefaults.standard

        // No stored value means the user has never chosen, which is glass on.
        isGlassEnabled = defaults.object(forKey: Self.glassKey) as? Bool ?? true
        peakStyle = FlightInfoPeakStyle(rawValue: defaults.string(forKey: Self.peakStyleKey) ?? "")
            ?? .compact
    }
}

/// How much the info window shows before it is opened.
enum FlightInfoPeakStyle: String, CaseIterable, Identifiable {

    /// A bar: identity beside a thumbnail, then the route.
    case compact

    /// The full window's header — the photo at the size it will keep, with
    /// identity and route under it — so opening the window grows what is
    /// already there rather than replacing it.
    case rich

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .rich: return "Photo"
        }
    }

    var detail: String {
        switch self {
        case .compact: return "A bar with a thumbnail"
        case .rich: return "Opens on the aircraft photo"
        }
    }
}

/// Design tokens for the flight info window: a monochrome carbon palette whose
/// only accent is white, so the window never competes with the map underneath.
///
/// Adding a look means adding another `static let` here — nothing downstream
/// branches on which theme is in use.
struct FlightInfoTheme {

    /// Whether this theme is drawn on glass. Every surface in the window and
    /// every piece of chrome over the map branches on this one flag, so the two
    /// looks can't drift apart — glass off is flat carbon, everywhere, in one
    /// step.
    let isGlass: Bool

    /// Opaque sheet ground, used when glass is off and on iOS versions with no
    /// `presentationBackground`.
    let windowFill: Color

    /// Darkens the blur just enough to keep white text legible over snow,
    /// desert and daylight ocean. Deliberately light — heavier tints turn the
    /// window into a black slab.
    let scrim: Color

    /// Carried into the system glass on floating chrome. Lighter than `scrim`:
    /// glass does its own dimming, and a heavy tint kills the lensing that
    /// makes it look like glass in the first place.
    let chromeTint: Color

    /// Tints for glass inside the window. Lighter again than `chromeTint` —
    /// these sit on the window's own ground rather than on the map, so they
    /// only need to lift off it.
    let surfaceTint: Color
    let elevatedTint: Color

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

    /// Same again for what the pilot is doing. The window is monochrome by
    /// design — the state is carried by its glyph and its word, not by going
    /// amber — and a theme that wants to colour AWAY changes it here.
    func pilotStateAccent(for state: PilotState) -> Color {
        state.isNoteworthy ? accent : textSecondary
    }

    /// The sheet's own background.
    ///
    /// This has to be the *sheet's* background rather than a layer inside the
    /// content: anything that samples what is behind it only sees its own
    /// render tree, so a blur drawn inside a sheet whose background was cleared
    /// has nothing to sample and renders as a near-black slab.
    ///
    /// The ground is the system's glass rather than a material. A material
    /// frosts what is behind it — it takes the map and turns it into fog, which
    /// is what made the window read as a slab however far the tint came down.
    /// Glass lenses instead: the map stays legible through it, and the window
    /// behaves like the floating chrome around it, which has been glass all
    /// along.
    ///
    /// The carbon underneath is down to a trace — 3% — so the glass itself is
    /// doing essentially all of the work and the map reads clearly through the
    /// window. That leaves white text leaning on the system's own adaptive
    /// dimming rather than on a ground of our own, which is the deliberate
    /// trade: this is the number to raise if a caption ever gets lost over
    /// snow or a bright ocean.
    @ViewBuilder
    var sheetBackground: some View {
        if isGlass {
            Rectangle()
                .fill(windowFill.opacity(0.03))
                .glassEffect(.regular.tint(scrim), in: Rectangle())
        } else {
            Rectangle().fill(windowFill)
        }
    }

    /// Tuned to let the map through.
    ///
    /// Every tint here had been carrying too much carbon: glass does its own
    /// dimming, so a tint heavy enough to guarantee contrast on its own leaves
    /// a dark slab with none of the lensing that makes it read as glass. The
    /// scrim and the chrome tint are the two that were doing it — both are now
    /// a wash rather than a coat — and the strokes are brighter to give each
    /// surface the lit edge glass has.
    static let glass = FlightInfoTheme(
        isGlass: true,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        scrim: Color.black.opacity(0.06),
        chromeTint: Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.12),
        surfaceTint: Color.white.opacity(0.04),
        elevatedTint: Color.white.opacity(0.09),
        surfaceFill: Color.white.opacity(0.08),
        elevatedFill: Color.white.opacity(0.14),
        stroke: Color.white.opacity(0.16),
        strokeStrong: Color.white.opacity(0.26),
        textPrimary: Color(white: 0.98),
        textSecondary: Color(white: 0.70),
        textDim: Color(white: 0.48),
        accent: .white,
        onAccent: Color(red: 0.09, green: 0.09, blue: 0.11),
        trackFill: Color.white.opacity(0.16)
    )

    static let solid = FlightInfoTheme(
        isGlass: false,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
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

    /// Cards in the window are the same glass as the chrome floating over the
    /// map, so the two halves of the app look like one thing. Only the tint
    /// differs: these already sit on the window's ground, so they need much
    /// less of it.
    func body(content: Content) -> some View {
        if theme.isGlass {
            content.glassEffect(
                .regular.tint(elevated ? theme.elevatedTint : theme.surfaceTint),
                in: shape
            )
        } else {
            content
                .background { shape.fill(elevated ? theme.elevatedFill : theme.surfaceFill) }
                .overlay { shape.strokeBorder(elevated ? theme.strokeStrong : theme.stroke, lineWidth: 1) }
                .clipShape(shape)
        }
    }
}

/// Measurements the window and its sheet have to agree on.
enum FlightInfoLayout {

    /// Starting height for the peak state, used until the window has measured
    /// what its own content actually needs. The real detent follows that
    /// measurement, so the peak never opens with a band of empty sheet under
    /// it — content height varies with the photo's shape and the device's home
    /// indicator, and no single constant fits all of them.
    static let basePeakHeight: CGFloat = 300

    /// Bounds on that measurement, so a bad layout pass can't produce an
    /// unusable sheet.
    ///
    /// The floor is deliberately below anything the peak actually lays out to:
    /// it is a guard against a broken measurement, not a target. Set close to
    /// the real content height it becomes the height, and a short peak — a
    /// parked aircraft, with no route strip to draw — pads itself back out
    /// with the empty band it was measured to avoid.
    static let minimumPeakHeight: CGFloat = 180

    /// Generous enough for the photo peak, which is the full window's header
    /// plus its route card.
    static let maximumPeakHeight: CGFloat = 560

    /// Floor height for the six action tiles, so both rows of the grid match
    /// each other however their labels differ. A minimum rather than a fixed
    /// height: larger accessibility type has to be able to grow the grid, and
    /// because every tile shares this they grow in step.
    static let actionTileHeight: CGFloat = 74

    /// Gap between action tiles, across and down. One value so the grid reads
    /// as a grid rather than as two rows that happen to be near each other.
    static let actionTileSpacing: CGFloat = 10

    /// How far the identity block is pulled up into the photo above it, so it
    /// rides the seam where the two meet. Shared, so the peak and the full
    /// window put it in exactly the same place.
    static let heroSeamLift: CGFloat = 30

    /// Space under the peak state's last card, measured from the card to the
    /// bottom edge of the sheet. The window draws into the bottom safe area,
    /// so this is the whole gap — the home indicator floats inside it rather
    /// than claiming its own band underneath.
    static let peakBottomGap: CGFloat = 12

    /// How far above the peak height the phases have finished swapping. The
    /// cross-fade rides the drag rather than the detent, so it wants to be
    /// done early in the travel — by the time the sheet is a third of the way
    /// up, the full window should already be the thing you are looking at.
    static let phaseTravel: CGFloat = 220

    /// Travel that doesn't count as a drag at all.
    ///
    /// The sheet's measured height and its detent agree to within a point or
    /// two, not exactly — rounding, and the resize animation settling. Without
    /// a dead band at the foot of the travel that difference reads as the
    /// window being fractionally open, which washes the peak out and ghosts
    /// the full window's photo in behind it while the sheet is sitting still.
    static let phaseDeadZone: CGFloat = 8
}

extension View {

    /// Keeps the map live behind the peak state: the sheet stops being modal
    /// up through that detent, so panning and zooming still reach the map —
    /// and the system stops dimming everything behind the sheet, which is what
    /// put a dark wash over the map as soon as the window opened.
    ///
    /// The detent is passed in rather than assumed: it has to be the same
    /// value the sheet is actually using, or the system quietly ignores this.
    func flightInfoSheetInteraction(upThrough detent: PresentationDetent) -> some View {
        presentationBackgroundInteraction(.enabled(upThrough: detent))
    }

    /// Chrome that floats over the map — the weather chip, the controls hub,
    /// the map buttons.
    ///
    /// This is the system's own glass rather than a hand-rolled material, so
    /// the chrome lenses and reacts the way every other iOS 26 control does,
    /// with the window's carbon carried in as the tint so the two still read
    /// as one design. Glass-off falls back to the flat carbon surface.
    @ViewBuilder
    func flightInfoChrome(_ theme: FlightInfoTheme, in shape: some Shape) -> some View {
        if theme.isGlass {
            glassEffect(.regular.tint(theme.chromeTint), in: shape)
        } else {
            background { shape.fill(theme.windowFill) }
                .overlay { shape.stroke(theme.stroke, lineWidth: 1) }
                .clipShape(shape)
        }
    }
}

/// Carries the peak state's measured content height up to the sheet.
struct PeakContentHeightKey: PreferenceKey {

    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
