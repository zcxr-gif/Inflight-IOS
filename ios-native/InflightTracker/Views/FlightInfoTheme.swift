import SwiftUI

/// Which way round the app is drawn.
///
/// `system` is the default and the only one that changes on its own — the two
/// explicit choices are for people who want the app light in a dark house, or
/// dark in a bright one, regardless of what iOS is doing.
enum AppAppearanceMode: String, CaseIterable, Identifiable {

    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Follows iOS — light by day if your phone does."
        case .light: return "Light everywhere, whatever iOS is set to."
        case .dark: return "Dark everywhere, whatever iOS is set to."
        }
    }
}

/// Runtime appearance switches for the app.
///
/// Every surface in the window — and every piece of chrome over the map — is
/// drawn through `FlightInfoTheme`, so flipping `isGlassEnabled` or `mode`
/// restyles the whole app without any view knowing which look is active. The
/// choices are persisted, and published so a toggle anywhere restyles a sheet
/// that is already open.
final class FlightInfoAppearance: ObservableObject {

    static let shared = FlightInfoAppearance()

    private static let glassKey = "flightInfoGlassEnabled"
    private static let peakStyleKey = "flightInfoPeakStyle"
    private static let modeKey = "appAppearanceMode"
    private static let mapStyleKey = "mapStyleMode"

    @Published var isGlassEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlassEnabled, forKey: Self.glassKey) }
    }

    @Published var peakStyle: FlightInfoPeakStyle {
        didSet { UserDefaults.standard.set(peakStyle.rawValue, forKey: Self.peakStyleKey) }
    }

    @Published var mode: AppAppearanceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// How the map itself is drawn. Lives here rather than under the filters:
    /// the filters are about *which traffic* is on the map, and this is about
    /// what the map looks like — the same question as light and dark.
    @Published var mapStyle: MapStyleMode {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: Self.mapStyleKey) }
    }

    /// What iOS itself is set to, reported in by the root view.
    ///
    /// Read rather than forced: the app never calls `preferredColorScheme`, so
    /// nothing overrides the window's own trait and this stays the *system's*
    /// answer even while the user has pinned the app light or dark. Forcing the
    /// window would make this read back whatever was forced, and switching to
    /// Auto would then stick on the old choice until the phone's own setting
    /// happened to change.
    @Published private(set) var systemScheme: ColorScheme = .dark

    var resolvedScheme: ColorScheme {
        switch mode {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    var theme: FlightInfoTheme {
        FlightInfoTheme.resolved(scheme: resolvedScheme, glass: isGlassEnabled)
    }

    /// What the map should actually draw.
    ///
    /// The choice is kept exactly as made even when it is a Pro style and Pro
    /// is not active — a lapsed subscription drops you back to the standard map
    /// without forgetting that you liked the globe, so it is there again the
    /// moment Pro is. Everything that draws the map reads this; the picker
    /// reads `mapStyle`, because it is showing you your choice.
    var resolvedMapStyle: MapStyleMode {
        mapStyle.isPro && !Entitlements.shared.isPro ? .muted : mapStyle
    }

    func adopt(systemScheme scheme: ColorScheme) {
        guard systemScheme != scheme else { return }
        systemScheme = scheme
    }

    private init() {
        let defaults = UserDefaults.standard

        // No stored value means the user has never chosen, which is glass on.
        isGlassEnabled = defaults.object(forKey: Self.glassKey) as? Bool ?? true
        peakStyle = FlightInfoPeakStyle(rawValue: defaults.string(forKey: Self.peakStyleKey) ?? "")
            ?? .compact
        // Dark was the only look the app had, so an install that predates this
        // setting keeps what it had rather than turning light overnight. New
        // installs follow iOS.
        mode = AppAppearanceMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "")
            ?? (defaults.object(forKey: Self.glassKey) == nil ? .system : .dark)
        // Muted is the map the app has always drawn, so nobody's map changes
        // under them on update — the globe is something you go and switch on.
        mapStyle = MapStyleMode(rawValue: defaults.string(forKey: Self.mapStyleKey) ?? "") ?? .muted
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

    /// Whether this theme is the light one.
    ///
    /// Nothing in the app is expected to branch on this to pick a colour — that
    /// is what every token below is for. It exists so the two things that live
    /// outside SwiftUI's colour system can be told which way round we are: the
    /// `colorScheme` stamped on system controls, and MapKit's own light/dark
    /// map style.
    let isLight: Bool

    /// Which way round system-drawn controls inside this theme should be. Every
    /// surface stamps this rather than hard-coding `.dark`, so switches,
    /// segmented pickers and the keyboard follow the app's own setting instead
    /// of iOS's.
    var colorScheme: ColorScheme { isLight ? .light : .dark }

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

    /// How much of `windowFill` is laid under the glass on the sheet's ground.
    ///
    /// Zero in the dark themes. It used to be a wash of carbon under the glass,
    /// there to keep white text legible over snow and daylight ocean, and it did
    /// that by making the window darker than the glass wanted to be — the map
    /// went muddy behind it and the whole thing read as a slab. Legibility is
    /// `textHalo`'s job now, which costs the map nothing.
    ///
    /// Light still needs a real ground. The system's glass *dims* what is behind
    /// it, which helps white text and hurts black, so black ink on it has to sit
    /// on something of its own.
    let groundOpacity: Double

    /// A soft halo drawn behind text on this theme, or clear for none.
    ///
    /// This is the honest way round: the window stays as clear as the glass can
    /// make it, and the few characters that need help get it *where they are*,
    /// instead of every pixel of the map behind the window paying for the
    /// contrast of a caption. Tight radius and no offset — it is a halo to lift
    /// glyphs off a busy background, not a drop shadow, and at this opacity it
    /// is invisible until the thing underneath is bright.
    let textHalo: Color

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
                .fill(windowFill.opacity(groundOpacity))
                .glassEffect(.regular.tint(scrim), in: Rectangle())
        } else {
            Rectangle().fill(windowFill)
        }
    }

    /// The four shipping looks, from the two switches that pick between them.
    ///
    /// Adding a look means adding a `static let` and a case here — nothing
    /// downstream branches on which theme is in use.
    static func resolved(scheme: ColorScheme, glass: Bool) -> FlightInfoTheme {
        switch (scheme, glass) {
        case (.light, true): return .lightGlass
        case (.light, false): return .lightSolid
        case (_, true): return .glass
        case (_, false): return .solid
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
        isLight: false,
        windowFill: Color(red: 0.09, green: 0.09, blue: 0.11),
        scrim: .clear,
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
        trackFill: Color.white.opacity(0.16),
        groundOpacity: 0,
        textHalo: Color.black.opacity(0.55)
    )

    static let solid = FlightInfoTheme(
        isGlass: false,
        isLight: false,
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
        trackFill: Color.white.opacity(0.14),
        groundOpacity: 1,
        textHalo: .clear
    )

    /// The dark themes inverted, not recoloured.
    ///
    /// Same monochrome discipline: paper rather than carbon, ink rather than
    /// white, and no accent hue introduced — so a light window competes with
    /// the map exactly as little as the dark one does, and every view that
    /// reads `accent` still gets a colour that white text can sit on top of.
    ///
    /// The one number that is not a straight inversion is the ground: black ink
    /// on glass needs a real surface under it, where white text could lean on
    /// the system's own dimming. Raise `groundOpacity` before any of the text
    /// tokens if a caption is ever lost over a dark coastline.
    static let lightGlass = FlightInfoTheme(
        isGlass: true,
        isLight: true,
        windowFill: Color(red: 0.96, green: 0.96, blue: 0.97),
        scrim: Color.white.opacity(0.10),
        chromeTint: Color.white.opacity(0.22),
        surfaceTint: Color.black.opacity(0.035),
        elevatedTint: Color.black.opacity(0.075),
        surfaceFill: Color.black.opacity(0.055),
        elevatedFill: Color.black.opacity(0.10),
        stroke: Color.black.opacity(0.10),
        strokeStrong: Color.black.opacity(0.18),
        textPrimary: Color(white: 0.08),
        textSecondary: Color(white: 0.32),
        textDim: Color(white: 0.52),
        accent: Color(white: 0.10),
        onAccent: Color(white: 0.98),
        trackFill: Color.black.opacity(0.14),
        groundOpacity: 0.55,
        textHalo: Color.white.opacity(0.5)
    )

    static let lightSolid = FlightInfoTheme(
        isGlass: false,
        isLight: true,
        windowFill: Color(red: 0.96, green: 0.96, blue: 0.97),
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
        surfaceFill: .white,
        elevatedFill: Color(white: 0.92),
        stroke: Color.black.opacity(0.09),
        strokeStrong: Color.black.opacity(0.15),
        textPrimary: Color(white: 0.08),
        textSecondary: Color(white: 0.32),
        textDim: Color(white: 0.52),
        accent: Color(white: 0.10),
        onAccent: Color(white: 0.98),
        trackFill: Color.black.opacity(0.12),
        groundOpacity: 1,
        textHalo: .clear
    )
}

extension View {

    /// Lifts text off whatever the glass is showing through it.
    ///
    /// Applied once, to the whole of a window's content, rather than to every
    /// `Text` in the app: SwiftUI's shadow is drawn from the alpha of what it
    /// wraps, so on a tree that is mostly glyphs and SF Symbols it haloes
    /// exactly the strokes that need it and does nothing to a filled card,
    /// which has no transparent edge to bleed from.
    ///
    /// A no-op on the flat themes and on light, where the ground is opaque and
    /// there is nothing showing through to compete with.
    @ViewBuilder
    func flightInfoLegible(_ theme: FlightInfoTheme) -> some View {
        if theme.isGlass, theme.textHalo != Color.clear {
            shadow(color: theme.textHalo, radius: 2.5)
        } else {
            self
        }
    }

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
