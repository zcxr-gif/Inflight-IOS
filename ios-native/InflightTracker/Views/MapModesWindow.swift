import SwiftUI

/// The map's own window: which map it is, and — for Pro — the map edited.
///
/// It used to be a menu off the corner button: a column of words with ticks
/// beside them, two submenus deep for the planet. Every choice in it is a
/// choice about how something *looks*, and a menu can only name a look. So it
/// is a window now, standing up from the bottom edge over the map it changes,
/// and every choice in it is a picture of the map you would get — the same
/// snapshots the settings screen takes (see `MapStyleThumbnail`) — with the
/// map itself changing behind it as you pick.
///
/// Top to bottom, most-used first: what the map is drawn in, what shape the
/// world is, the switches that apply to whichever that is, and then what Pro
/// adds — the planet's wardrobe when the planet is up, and the map's own
/// edits otherwise.
struct MapModesWindow: View {

    let onClose: () -> Void

    /// Told when the shape changes, for what the screen around the window has
    /// to tidy up — the ruler has nowhere to be on the drawn planet.
    var onProjectionChanged: (MapProjection) -> Void = { _ in }

    /// Whether the window runs side to side, the way the flight window does on
    /// a phone. On a screen with room for the flight window's column it stands
    /// as a column of its own instead, rather than a strip across a tablet.
    var fillsWidth = true

    /// The band along the foot of the screen the home indicator sits in. The
    /// window stands down into it, as the flight window does, and its content
    /// stops above it.
    var bottomInset: CGFloat = 0

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var entitlements = Entitlements.shared

    @State private var paywallFeature: ProFeature = .mapCustomise
    @State private var isShowingPaywall = false

    /// How far a pull on the header has carried the window down. Let go on
    /// the same spring as the flight window, so a pull that stops short eases
    /// back rather than snapping.
    @GestureState(resetTransaction: Transaction(animation: Motion.chrome))
    private var pull: CGFloat = 0

    @GestureState private var isHeld = false

    private var theme: FlightInfoTheme { appearance.theme }
    private var look: MapLook { appearance.resolvedMapStyle }
    private var projection: MapProjection { appearance.mapProjection }

    /// The light the pictures are taken in — the map's own.
    private func scheme(for palette: MapPalette) -> ColorScheme {
        palette.scheme ?? appearance.resolvedScheme
    }

    private static let tileSide: CGFloat = 70

    /// How wide the window stands where it does not run side to side.
    private static let columnWidth: CGFloat = 560

    /// How far a pull has to go, or be heading, to put the window away. The
    /// flight window's own distance, so the two answer one gesture alike.
    private static let closeTravel: CGFloat = FlightWindowDockMetrics.closeTravel

    var body: some View {
        VStack(spacing: 0) {
            header

            // The whole window when it fits, a scroll of it when it does not:
            // a phone in landscape, or the planet's wardrobe on a small phone.
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical, showsIndicators: false) { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.bottom, bottomInset)
        // Standing on the bottom edge the way the flight window does: side to
        // side, rounded along the top, square along the foot, where the
        // display's own corners do the rounding. It used to float as a card
        // with a margin all round it and four corners of its own — the one
        // window in the app that did, next to a flight window that runs
        // edge to edge.
        .frame(maxWidth: fillsWidth ? .infinity : Self.columnWidth)
        .background { theme.sheetBackground }
        .clipShape(BottomEdge.shape)
        .overlay {
            BottomEdge.shape
                .stroke(theme.stroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        // Out of the dock's island, like every window — see `WindowBirth`.
        // Square at the foot, so it opens out to the sides of the screen
        // exactly as the flight window does.
        .bornFromDock(theme: theme, topRadius: BottomEdge.cornerRadius, bottomRadius: 0)
        .shadow(color: .black.opacity(0.22), radius: 18, y: -2)
        .offset(y: max(pull, 0))
        .environment(\.colorScheme, theme.colorScheme)
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: paywallFeature) }
    }

    // MARK: - Header

    /// The pill along the top and the window's name under it. No close
    /// button: the pill is the way out, as it is on the flight window — a tap
    /// on it, or a pull down anywhere along the header.
    private var header: some View {
        VStack(spacing: 2) {
            WindowGrabber(theme: theme, isHeld: isHeld)
                .frame(width: 132)
                .onTapGesture { onClose() }
                .accessibilityElement()
                .accessibilityLabel(L("Close the map window"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onClose() }

            Text("Map")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        // A pull down on the header puts the window away, the way every other
        // window in the app goes.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($isHeld) { _, state, _ in state = true }
                .updating($pull) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    if value.translation.height > Self.closeTravel
                        || value.predictedEndTranslation.height > Self.closeTravel * 1.6 {
                        onClose()
                    }
                }
        )
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            paletteTiles
            projectionTiles
            switches

            if projection == .planet {
                planetSection
            } else {
                customiseSection
            }

            Text("© Mapbox  © OpenStreetMap")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    // MARK: - Which map

    /// What the map is drawn in, as four pictures of it.
    ///
    /// Only the flat map wears these — the globe is imagery whatever is picked
    /// and the planet has colours of its own — so on either of those the row
    /// is still there, dimmed, with a line saying why, rather than gone.
    private var paletteTiles: some View {
        let ownColours = projection != .flat
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(MapPalette.allCases) { palette in
                    tile(
                        title: palette.label,
                        look: MapLook(
                            projection: .flat,
                            palette: palette,
                            isTerrain: appearance.isMapTerrain,
                            isDetailed: appearance.isMapDetailed,
                            brightness: appearance.mapBrightness,
                            custom: look.custom
                        ),
                        scheme: scheme(for: palette),
                        isSelected: appearance.mapPalette == palette,
                        isLocked: palette.isPro && !entitlements.isPro
                    ) {
                        appearance.mapPalette = palette
                        if palette.isPro, !entitlements.isPro { ask(for: .mapStyles) }
                    }
                }
            }
            .opacity(ownColours ? 0.4 : 1)
            .allowsHitTesting(!ownColours)

            if ownColours {
                note(projection == .globe
                     ? "The globe is drawn in imagery, whatever is picked here."
                     : "The planet has colours of its own, below.")
            }
        }
    }

    /// The shape of the world, as three pictures of it in the current colours.
    private var projectionTiles: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(MapProjection.allCases) { shape in
                tile(
                    title: shape.label,
                    look: MapLook(
                        projection: shape,
                        palette: appearance.mapPalette,
                        isTerrain: appearance.isMapTerrain,
                        isDetailed: appearance.isMapDetailed,
                        brightness: appearance.mapBrightness,
                        custom: look.custom
                    ),
                    scheme: scheme(for: appearance.mapPalette),
                    isSelected: projection == shape,
                    isLocked: shape.isPro && !entitlements.isPro
                ) {
                    appearance.mapProjection = shape
                    onProjectionChanged(shape)
                    if shape.isPro, !entitlements.isPro { ask(for: .mapStyles) }
                }
            }
            // Three to the four above, sitting under the first three of them
            // rather than spread to the edges.
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }

    /// One picture to pick, with its name under it.
    private func tile(
        title: String,
        look: MapLook,
        scheme: ColorScheme,
        isSelected: Bool,
        isLocked: Bool,
        select: @escaping () -> Void
    ) -> some View {
        let isRound = look.projection != .flat
        return Button(action: select) {
            VStack(spacing: 7) {
                MapStyleThumbnail(look: look, scheme: scheme, side: Self.tileSide)
                    .overlay {
                        // The ring sits just outside the picture, so a selected
                        // tile is the same picture with a frame on it rather
                        // than a smaller one.
                        Group {
                            if isRound {
                                Circle().strokeBorder(theme.accent, lineWidth: 2.5)
                            } else {
                                RoundedRectangle(cornerRadius: theme.radiusSmall + 4, style: .continuous)
                                    .strokeBorder(theme.accent, lineWidth: 2.5)
                            }
                        }
                        .padding(-5)
                        .opacity(isSelected ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isLocked { ProBadge().offset(x: 4, y: -4) }
                    }
                    .padding(5)

                Text(L(title))
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motion(Motion.control, value: isSelected)
    }

    // MARK: - Switches

    /// What applies to whichever map is up. Each one is left in place and
    /// dimmed where it has nothing to act on, so the card keeps its shape as
    /// the map underneath changes.
    private var switches: some View {
        let isImagery = look.resolvedPalette.usesImagery
        let isPlanet = projection == .planet
        return VStack(spacing: 0) {
            PanelToggleRow(title: "Full detail", symbol: "map.fill", isOn: $appearance.isMapDetailed)
                .disabled(isImagery || isPlanet)
                .opacity(isImagery || isPlanet ? 0.45 : 1)

            PanelDivider()

            // On the globe the terrain is part of the shape and always there.
            PanelToggleRow(
                title: "3D terrain",
                symbol: "mountain.2.fill",
                isOn: projection == .globe ? .constant(true) : $appearance.isMapTerrain
            )
            .disabled(projection != .flat)
            .opacity(projection != .flat ? 0.45 : 1)

            if !isPlanet {
                PanelDivider()

                PanelSliderRow(
                    title: "Brightness",
                    symbol: "sun.max",
                    reading: { Self.brightnessReading($0) },
                    neutral: MapLook.neutralBrightness,
                    value: $appearance.mapBrightness
                )
            }
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: - Pro: the map, edited

    /// Which parts of the customisation the map that is up can show.
    ///
    /// Cartography takes all of it. The globe's imagery is a photograph with
    /// names over it — it can be lit for a time of day and its names and
    /// borders turned off, and that is all. Flat imagery is one raster with
    /// nothing on it to set.
    private enum Reach { case all, lightAndNames, none }

    private var reach: Reach {
        if projection == .globe { return .lightAndNames }
        return look.resolvedPalette.usesImagery ? .none : .all
    }

    private var customiseSection: some View {
        let unlocked = appearance.canCustomiseMap
        let reach = self.reach
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CUSTOMISE", accessory: unlocked && !appearance.mapCustomisation.isStandard ? AnyView(resetButton) : nil)

            if !unlocked {
                ProUpsellRow(feature: .mapCustomise) { ask(for: .mapCustomise) }
                    .flightInfoSurface(theme, radius: theme.radiusMedium)
            }

            VStack(alignment: .leading, spacing: 14) {
                lightPicker
                    .opacity(reach == .none ? 0.4 : 1)
                    .allowsHitTesting(reach != .none)

                tintPicker
                    .opacity(reach == .all ? 1 : 0.4)
                    .allowsHitTesting(reach == .all)

                fontPicker
                    .opacity(reach == .all ? 1 : 0.4)
                    .allowsHitTesting(reach == .all)

                VStack(spacing: 0) {
                    PanelToggleRow(title: "Place names", symbol: "textformat", isOn: $appearance.mapShowsPlaceNames)
                        .opacity(reach == .none ? 0.4 : 1)
                        .allowsHitTesting(reach != .none)
                    PanelDivider()
                    PanelToggleRow(title: "Road names", symbol: "road.lanes", isOn: $appearance.mapShowsRoadNames)
                        .opacity(reach == .all ? 1 : 0.4)
                        .allowsHitTesting(reach == .all)
                    PanelDivider()
                    PanelToggleRow(title: "Borders", symbol: "square.dashed", isOn: $appearance.mapShowsBorders)
                        .opacity(reach == .none ? 0.4 : 1)
                        .allowsHitTesting(reach != .none)
                    PanelDivider()
                    PanelToggleRow(title: "3D buildings", symbol: "building.2", isOn: $appearance.mapShows3DBuildings)
                        .opacity(reach == .all ? 1 : 0.4)
                        .allowsHitTesting(reach == .all)
                }
                .flightInfoSurface(theme, radius: theme.radiusMedium)
            }
            .proLocked(unlocked) { ask(for: .mapCustomise) }

            if reach != .all {
                note(reach == .none
                     ? "Satellite imagery has nothing to edit. Pick a drawn map to customise it."
                     : "The globe takes the light, the names and the borders.")
            }
        }
    }

    private var lightPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Time of day")
            HStack(spacing: 6) {
                ForEach(MapLight.allCases) { light in
                    chip(isSelected: appearance.mapLight == light) {
                        appearance.mapLight = light
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: light.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Text(L(light.label))
                                .font(.system(size: 11, weight: .semibold))
                                .flightInfoLine(minimumScale: 0.7)
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var tintPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Colours")
            HStack(spacing: 0) {
                ForEach(MapTint.allCases) { tint in
                    Button {
                        appearance.mapTint = tint
                    } label: {
                        VStack(spacing: 5) {
                            swatch(tint)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle()
                                        .strokeBorder(theme.accent, lineWidth: 2.5)
                                        .padding(-4)
                                        .opacity(appearance.mapTint == tint ? 1 : 0)
                                }
                                .padding(4)
                            Text(L(tint.label))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(appearance.mapTint == tint ? theme.textPrimary : theme.textSecondary)
                                .flightInfoLine(minimumScale: 0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(tint.label))
                    .accessibilityAddTraits(appearance.mapTint == tint ? .isSelected : [])
                }
            }
        }
    }

    /// Land, with a band of its water across the lower half — enough to tell
    /// the sets apart at a glance.
    private func swatch(_ tint: MapTint) -> some View {
        // Mapbox's own land and water for the standard set.
        let colours: (land: Color, water: Color) = tint.swatch ?? (
            land: Color(hue: 20 / 360, saturation: 0.20, brightness: 0.95),
            water: Color(hue: 200 / 360, saturation: 0.45, brightness: 1.0)
        )
        return Circle()
            .fill(colours.land)
            .overlay(alignment: .bottom) {
                Rectangle().fill(colours.water).frame(height: 13)
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(theme.strokeStrong, lineWidth: 1) }
    }

    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Typeface")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MapFont.allCases) { font in
                        chip(isSelected: appearance.mapFont == font) {
                            appearance.mapFont = font
                        } label: {
                            Text(L(font.label))
                                .font(.system(size: 13, weight: .semibold, design: font.preview))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var resetButton: some View {
        Button {
            withAnimation(Motion.control) { appearance.resetMapCustomisation() }
        } label: {
            Text("Reset")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - The planet's own

    /// The drawn planet's wardrobe: its colour, what is behind it, and whether
    /// the traffic on it is aircraft or dots. Pro — see `ProFeature.planetLook`.
    private var planetSection: some View {
        let unlocked = appearance.canEditPlanet
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("PLANET", accessory: nil)

            if !unlocked {
                ProUpsellRow(feature: .planetLook) { ask(for: .planetLook) }
                    .flightInfoSurface(theme, radius: theme.radiusMedium)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    label("Colour")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(GlobeSkin.allCases) { skin in
                                planetTile(
                                    title: skin.label,
                                    skin: skin,
                                    backdrop: appearance.resolvedGlobeBackdrop,
                                    isSelected: appearance.resolvedGlobeSkin == skin
                                ) { appearance.globeSkin = skin }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    label("Background")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(GlobeBackdrop.allCases) { backdrop in
                                planetTile(
                                    title: backdrop.label,
                                    skin: appearance.resolvedGlobeSkin,
                                    backdrop: backdrop,
                                    isSelected: appearance.resolvedGlobeBackdrop == backdrop
                                ) { appearance.globeBackdrop = backdrop }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                PanelToggleRow(
                    title: "Aircraft shapes",
                    symbol: "airplane",
                    isOn: unlocked ? $appearance.globeShowsPlanes : .constant(true)
                )
                .flightInfoSurface(theme, radius: theme.radiusMedium)
            }
            .proLocked(unlocked) { ask(for: .planetLook) }
        }
    }

    private func planetTile(
        title: String,
        skin: GlobeSkin,
        backdrop: GlobeBackdrop,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            VStack(spacing: 6) {
                GlobeSwatch(skin: skin, backdrop: backdrop, side: 52)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(theme.accent, lineWidth: 2.5)
                            .padding(-4)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .padding(4)
                Text(L(title))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String, accessory: AnyView?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(title))
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 2)
    }

    private func label(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 2)
    }

    private func note(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    /// A selectable lozenge: the accent's wash when picked, the panel's own
    /// surface when not.
    private func chip<Face: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Face
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? theme.accent.opacity(0.22) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? theme.accent.opacity(0.6) : theme.stroke, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motion(Motion.control, value: isSelected)
    }

    private func ask(for feature: ProFeature) {
        paywallFeature = feature
        isShowingPaywall = true
    }

    /// The same reading the settings screen's slider gives.
    private static func brightnessReading(_ value: CGFloat) -> String {
        let travel = (value - MapLook.neutralBrightness) / MapLook.neutralBrightness
        guard abs(travel) > 0.01 else { return "Normal" }
        return String(format: "%+.0f%%", Double(travel * 100))
    }
}
