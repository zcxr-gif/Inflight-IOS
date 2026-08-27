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

/// What the app is coloured in, under whichever way round it is drawn.
///
/// A separate question from light and dark, the way the map's shape is separate
/// from its palette: `AppAppearanceMode` decides which end of the scale the
/// window sits at, and this decides what the scale is made of.
enum AppPalette: String, CaseIterable, Identifiable {

    /// Black and white, and a blue for the few things that have to be picked
    /// out of it. The default.
    ///
    /// Carbon was already close to this — the whole design has been monochrome
    /// from the start — but close to black is not black, and the difference
    /// shows up everywhere at once: a window whose ground is a dark grey reads
    /// as a *card* over the map, where one that goes to black reads as a hole
    /// cut in it. The ink goes the same way, to white rather than to
    /// ninety-eight per cent of it.
    ///
    /// What that costs is the one thing carbon had that pure monochrome does
    /// not: somewhere for a highlight to live. With every surface and every
    /// glyph on the same grey axis, the only way to say "this one" was to make
    /// it brighter, which on a scale that already ends at white is no room at
    /// all. So there is a blue, and only a blue, in only the places that were
    /// already reaching for `accent` — the fill on a progress track, the badge
    /// on a route, a primary button, a pilot state worth noticing. Everything
    /// that states a fact rather than making a claim stays black and white.
    ///
    /// The map is untouched by this. The altitude ramp on a flown path is data
    /// rather than decoration, the amber on a selected sprite has to read over
    /// ocean and forest alike, and neither of them is the app's palette to
    /// spend.
    case mono

    /// The app as it was: carbon rather than black, and white as the accent.
    ///
    /// Kept because it is a real look and some people will prefer it, not as a
    /// compatibility shim — nothing behaves differently under it.
    case carbon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: return "Mono"
        case .carbon: return "Carbon"
        }
    }

    var detail: String {
        switch self {
        case .mono: return "Black and white, with blue where something has to stand out."
        case .carbon: return "The older look: carbon rather than black, and white for the accent."
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
    private static let windowPlacementKey = "flightWindowPlacement"
    private static let modeKey = "appAppearanceMode"
    private static let paletteKey = "appPalette"
    /// The old single map style, read once so an install that predates the
    /// split lands on the same map it had.
    private static let legacyMapStyleKey = "mapStyleMode"
    private static let mapProjectionKey = "map.projection"
    private static let mapPaletteKey = "map.palette"
    private static let mapDetailKey = "map.detailed"
    private static let mapTerrainKey = "map.terrain"

    @Published var isGlassEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlassEnabled, forKey: Self.glassKey) }
    }

    @Published var peakStyle: FlightInfoPeakStyle {
        didSet { UserDefaults.standard.set(peakStyle.rawValue, forKey: Self.peakStyleKey) }
    }

    /// Where the flight window sits when there is a screen wide enough to put
    /// it somewhere — which today means an iPad, and any iPad-sized split of
    /// one. Stored on every device: the setting is only *offered* where it
    /// applies, but a phone that is restored onto a tablet should arrive with
    /// the choice it was given.
    @Published var flightWindowPlacement: FlightWindowPlacement {
        didSet {
            UserDefaults.standard.set(flightWindowPlacement.rawValue, forKey: Self.windowPlacementKey)
        }
    }

    @Published var mode: AppAppearanceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// What the app is coloured in. See `AppPalette`.
    ///
    /// Everybody gets the new default, including installs that predate it —
    /// which is a change people will see on update, and deliberately so: this
    /// is what the app looks like now, and the old one is a switch away rather
    /// than a thing you have to have noticed to keep.
    @Published var palette: AppPalette {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteKey) }
    }

    /// How the map itself is drawn. Lives here rather than under the filters:
    /// the filters are about *which traffic* is on the map, and this is about
    /// what the map looks like — the same question as light and dark.
    ///
    /// Separate settings rather than one style, because they are separate
    /// questions: what shape the world is, what it is drawn in, how much of it
    /// is drawn, and whether there is height under it. A satellite flat map and
    /// a detailed light one are both things you can ask for.
    ///
    /// The one pairing that is not free is the globe's palette: the planet is
    /// imagery, always. What is stored here is untouched by that — see
    /// `MapLook.palette` for why, and for what comes back when you land.
    @Published var mapProjection: MapProjection {
        didSet { UserDefaults.standard.set(mapProjection.rawValue, forKey: Self.mapProjectionKey) }
    }

    @Published var mapPalette: MapPalette {
        didSet { UserDefaults.standard.set(mapPalette.rawValue, forKey: Self.mapPaletteKey) }
    }

    @Published var isMapDetailed: Bool {
        didSet { UserDefaults.standard.set(isMapDetailed, forKey: Self.mapDetailKey) }
    }

    /// Real elevation under the map, and a camera that can lean over it.
    ///
    /// Off by default, and that is a decision about what the app is rather than
    /// about what looks best in a screenshot: this is a traffic map, the height
    /// that matters on it is the aeroplane's, and a mountain range standing up
    /// out of the paper is one more thing between you and a sprite. It is there
    /// for the people who want it.
    @Published var isMapTerrain: Bool {
        didSet { UserDefaults.standard.set(isMapTerrain, forKey: Self.mapTerrainKey) }
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
        FlightInfoTheme.resolved(palette: palette, scheme: resolvedScheme, glass: isGlassEnabled)
    }

    /// What the map should actually draw.
    ///
    /// The choice is kept exactly as made even when part of it is Pro and Pro
    /// is not active — a lapsed subscription drops you back to the flat
    /// cartographic map without forgetting that you liked the globe, so it is
    /// there again the moment Pro is. Each axis falls back on its own: losing
    /// Pro takes the imagery away but leaves a black map black.
    ///
    /// Note this hands the *stored* palette through even on the globe, where it
    /// is not what gets drawn. That is deliberate and the reason
    /// `MapLook.resolvedPalette` exists: the look carries the choice, and
    /// answers separately for what is on screen.
    var resolvedMapStyle: MapLook {
        let isPro = Entitlements.shared.isPro
        return MapLook(
            projection: mapProjection.isPro && !isPro ? .flat : mapProjection,
            palette: mapPalette.isPro && !isPro ? .auto : mapPalette,
            isTerrain: isMapTerrain,
            isDetailed: isMapDetailed
        )
    }

    /// Which appearance the map itself draws in — the palette's, or the app's
    /// own when the palette follows along.
    var resolvedMapScheme: ColorScheme {
        resolvedMapStyle.resolvedPalette.scheme ?? resolvedScheme
    }

    func adopt(systemScheme scheme: ColorScheme) {
        guard systemScheme != scheme else { return }
        systemScheme = scheme
    }

    private init() {
        let defaults = UserDefaults.standard

        // No stored value means the user has never chosen, which is glass on.
        isGlassEnabled = defaults.object(forKey: Self.glassKey) as? Bool ?? true
        // The fallback also catches a retired style: the board was a third
        // option once, and anybody still holding it lands back on the bar
        // rather than on a case that no longer exists.
        peakStyle = FlightInfoPeakStyle(rawValue: defaults.string(forKey: Self.peakStyleKey) ?? "")
            ?? .compact
        flightWindowPlacement = FlightWindowPlacement(
            rawValue: defaults.string(forKey: Self.windowPlacementKey) ?? ""
        ) ?? .centred
        // Dark was the only look the app had, so an install that predates this
        // setting keeps what it had rather than turning light overnight. New
        // installs follow iOS.
        mode = AppAppearanceMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "")
            ?? (defaults.object(forKey: Self.glassKey) == nil ? .system : .dark)
        // No read-across from anything: carbon was not a choice anybody made,
        // it was the only thing there was, so there is nothing stored that
        // means "I picked it". An install that predates this lands on mono like
        // a new one.
        palette = AppPalette(rawValue: defaults.string(forKey: Self.paletteKey) ?? "") ?? .mono
        // The map the app has always drawn, so nobody's map changes under them
        // on update. An install from before the style was split has one stored
        // style rather than three settings, and it is read across to whichever
        // pair of them means the same thing; anybody who has chosen since has
        // the three, and the legacy value is ignored.
        let legacy = MapLook.from(legacy: defaults.string(forKey: Self.legacyMapStyleKey) ?? "")

        mapProjection = MapProjection(rawValue: defaults.string(forKey: Self.mapProjectionKey) ?? "")
            ?? legacy?.projection
            ?? .flat
        mapPalette = MapPalette(rawValue: defaults.string(forKey: Self.mapPaletteKey) ?? "")
            ?? legacy?.palette
            ?? .auto
        isMapDetailed = defaults.object(forKey: Self.mapDetailKey) as? Bool
            ?? legacy?.isDetailed
            ?? false
        // No legacy value to read across: the single stored style never had a
        // terrain switch in it, and the globe — which is the one look that
        // always had elevation — gets it from its projection rather than from
        // here.
        isMapTerrain = defaults.object(forKey: Self.mapTerrainKey) as? Bool ?? false
    }
}

/// Where the flight window sits on a screen with room to put it somewhere.
///
/// A phone has one answer — the window comes up from the bottom edge and the
/// map is what is left above it — and there is nothing to choose. A tablet has
/// most of a desk spare beside the aeroplane you are watching, and which part
/// of the map you want to keep is a matter of what you are doing: following one
/// aircraft down an approach wants the field in front of it, where reading a
/// flight plan wants the width.
///
/// Only offered where it means something. The picker is on the iPad's settings
/// and nowhere else, and the phone ignores this entirely.
enum FlightWindowPlacement: String, CaseIterable, Identifiable {

    /// Low and centred: the window sits near the bottom edge, the way it does
    /// on a phone, with the map above and to both sides of it.
    ///
    /// Named for where it is across the screen rather than up it, because the
    /// across is the part that distinguishes it from the other one. It is not
    /// vertically centred and deliberately never was — a window floating in the
    /// dead middle of a tablet covers the one part of the map you are looking
    /// at, which is wherever you just tapped.
    case centred

    /// The whole window as a column down the right-hand edge, with the map
    /// running full height beside it.
    case trailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .centred: return "Centre"
        case .trailing: return "Right"
        }
    }

    var detail: String {
        switch self {
        case .centred: return "Low and centred, with the map around it"
        case .trailing: return "A column down the right, with the map beside it"
        }
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
    /// The scheme is stamped here rather than left to the view that presents
    /// the sheet, and that is the whole reason a light window used to come up
    /// dark.
    ///
    /// The system's glass takes its own colour from the environment it is drawn
    /// in. A presentation background is built in a closure and hung on the
    /// sheet itself, so it does not reliably inherit what the content around it
    /// was stamped with — and the app deliberately never forces a scheme on the
    /// window, so what it inherited instead was *iOS's*. Light app on a phone
    /// set to dark meant dark glass under near-black ink, which is exactly the
    /// slab this design spent so long avoiding. Every other surface in the app
    /// stamps this; this one has to as well.
    @ViewBuilder
    var sheetBackground: some View {
        Group {
            if isGlass {
                Rectangle()
                    .fill(windowFill.opacity(groundOpacity))
                    .glassEffect(.regular.tint(scrim), in: Rectangle())
            } else {
                Rectangle().fill(windowFill)
            }
        }
        .environment(\.colorScheme, colorScheme)
    }

    /// The shipping looks, from the three switches that pick between them.
    ///
    /// Adding a look means adding a `static let` and a case here — nothing
    /// downstream branches on which theme is in use.
    static func resolved(palette: AppPalette, scheme: ColorScheme, glass: Bool) -> FlightInfoTheme {
        switch (palette, scheme, glass) {
        case (.mono, .light, true): return .monoLightGlass
        case (.mono, .light, false): return .monoLightSolid
        case (.mono, _, true): return .monoGlass
        case (.mono, _, false): return .monoSolid
        case (.carbon, .light, true): return .lightGlass
        case (.carbon, .light, false): return .lightSolid
        case (.carbon, _, true): return .glass
        case (.carbon, _, false): return .solid
        }
    }

    // MARK: - Mono

    /// The blue, and the only one.
    ///
    /// Two of it, because a hue that reads on black does not read on paper: a
    /// blue bright enough to pick itself out of a black window is a blue that
    /// vanishes into a white one. Same hue, different lightness — so the accent
    /// is recognisably the same colour whichever way round the app is, which is
    /// the whole reason for naming it once here rather than twice below.
    ///
    /// Both are picked against what has to sit on top of them. `monoInk` is
    /// nearly six to one on the light blue and the dark blue carries white at
    /// better than five, so the glyph inside a badge is legible either way
    /// without the badge having to shout.
    private static let monoBlue = Color(red: 0.29, green: 0.58, blue: 1.0)
    private static let monoBlueDeep = Color(red: 0.06, green: 0.36, blue: 0.80)

    /// Black with the faintest lean towards blue, and paper with the same.
    ///
    /// Not neutral, and only just not: a hair of the accent's own hue in the
    /// ground is what keeps a window full of white text from reading as a
    /// screenshot of a terminal. At this distance from grey nobody could name
    /// the colour, which is the intention — "a hint" is a thing you feel and do
    /// not see.
    private static let monoGround = Color(red: 0.012, green: 0.016, blue: 0.028)
    private static let monoPaper = Color(red: 0.975, green: 0.978, blue: 0.992)
    private static let monoInk = Color(red: 0.04, green: 0.045, blue: 0.06)

    static let monoGlass = FlightInfoTheme(
        isGlass: true,
        isLight: false,
        windowFill: Self.monoGround,
        scrim: .clear,
        chromeTint: Self.monoGround.opacity(0.14),
        surfaceTint: Color.white.opacity(0.04),
        elevatedTint: Color.white.opacity(0.09),
        surfaceFill: Color.white.opacity(0.08),
        elevatedFill: Color.white.opacity(0.14),
        stroke: Color.white.opacity(0.16),
        strokeStrong: Color.white.opacity(0.26),
        textPrimary: .white,
        textSecondary: Color(white: 0.72),
        textDim: Color(white: 0.50),
        accent: Self.monoBlue,
        onAccent: Self.monoGround,
        trackFill: Color.white.opacity(0.16),
        groundOpacity: 0,
        textHalo: Color.black.opacity(0.55)
    )

    static let monoSolid = FlightInfoTheme(
        isGlass: false,
        isLight: false,
        windowFill: Self.monoGround,
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
        // A shade lighter than carbon's cards at the same step, because they
        // are sitting on black rather than on carbon and have further to come
        // up before they read as a surface at all.
        surfaceFill: Color(white: 0.13),
        elevatedFill: Color(white: 0.19),
        stroke: Color.white.opacity(0.10),
        strokeStrong: Color.white.opacity(0.16),
        textPrimary: .white,
        textSecondary: Color(white: 0.72),
        textDim: Color(white: 0.50),
        accent: Self.monoBlue,
        onAccent: Self.monoGround,
        trackFill: Color.white.opacity(0.14),
        groundOpacity: 1,
        textHalo: .clear
    )

    /// Inverted, not recoloured — the same note as the carbon light themes,
    /// with one addition: the accent goes *deeper* rather than flipping to ink.
    ///
    /// Carbon's light themes have no accent hue at all; their accent is very
    /// nearly black, because in a look whose only accent is white there is
    /// nothing to invert white to but black. Mono has a colour, so it keeps it,
    /// and what changes is the lightness. A blue that reads on black is lost on
    /// paper and the other way round; the hue is the constant.
    static let monoLightGlass = FlightInfoTheme(
        isGlass: true,
        isLight: true,
        windowFill: Self.monoPaper,
        scrim: Color.white.opacity(0.28),
        chromeTint: Color.white.opacity(0.30),
        surfaceTint: Color.black.opacity(0.035),
        elevatedTint: Color.black.opacity(0.075),
        surfaceFill: Color.black.opacity(0.055),
        elevatedFill: Color.black.opacity(0.10),
        stroke: Color.black.opacity(0.10),
        strokeStrong: Color.black.opacity(0.18),
        textPrimary: Self.monoInk,
        textSecondary: Color(white: 0.34),
        textDim: Color(white: 0.54),
        accent: Self.monoBlueDeep,
        onAccent: .white,
        trackFill: Color.black.opacity(0.14),
        groundOpacity: 0.85,
        textHalo: Color.white.opacity(0.5)
    )

    static let monoLightSolid = FlightInfoTheme(
        isGlass: false,
        isLight: true,
        windowFill: Self.monoPaper,
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
        surfaceFill: .white,
        elevatedFill: Color(white: 0.93),
        stroke: Color.black.opacity(0.09),
        strokeStrong: Color.black.opacity(0.15),
        textPrimary: Self.monoInk,
        textSecondary: Color(white: 0.34),
        textDim: Color(white: 0.54),
        accent: Self.monoBlueDeep,
        onAccent: .white,
        trackFill: Color.black.opacity(0.12),
        groundOpacity: 1,
        textHalo: .clear
    )

    // MARK: - Carbon

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
    /// The one number that is not a straight inversion is the ground, and it is
    /// the one that had to change.
    ///
    /// Glass *dims* what is behind it. That helps white text, which is why the
    /// dark themes can float on almost nothing, and it works against black ink,
    /// which needs a surface of its own. At a little over half opacity the map
    /// still came through hard enough to grey the paper down — and since the
    /// map itself can now be set to dark or to near-black independently of the
    /// app, "what is behind it" stopped being a safe assumption. The ground is
    /// most of the way to paper now, with the scrim leaning white rather than
    /// sitting neutral, so a light window reads as light over any map the app
    /// can draw. There is still a trace of the world coming through, which is
    /// the point of the window being glass at all.
    static let lightGlass = FlightInfoTheme(
        isGlass: true,
        isLight: true,
        windowFill: Color(red: 0.96, green: 0.96, blue: 0.97),
        scrim: Color.white.opacity(0.28),
        chromeTint: Color.white.opacity(0.30),
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
        groundOpacity: 0.85,
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
        elevated: Bool = false,
        interactive: Bool = false
    ) -> some View {
        modifier(
            FlightInfoSurfaceModifier(
                theme: theme,
                radius: radius,
                elevated: elevated,
                interactive: interactive
            )
        )
    }
}

struct FlightInfoSurfaceModifier: ViewModifier {

    let theme: FlightInfoTheme
    let radius: CGFloat
    let elevated: Bool

    /// Whether this surface is a control rather than a card.
    ///
    /// Interactive glass is the system's own press response: the pane bends
    /// towards the finger and the light on it moves. It is most of what makes
    /// a piece of iOS 26 chrome feel like it is made of something, and it is
    /// free — but only a control should have it. A card that flexes when the
    /// list under it is scrolled past is a card pretending to be a button.
    var interactive: Bool = false

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
                .regular
                    .tint(elevated ? theme.elevatedTint : theme.surfaceTint)
                    .interactive(interactive),
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
    func flightInfoChrome(
        _ theme: FlightInfoTheme,
        in shape: some Shape,
        interactive: Bool = false
    ) -> some View {
        if theme.isGlass {
            glassEffect(.regular.tint(theme.chromeTint).interactive(interactive), in: shape)
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
