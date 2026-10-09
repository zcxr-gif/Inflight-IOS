import SwiftUI

/// Where the dock is resting.
///
/// Three stops, the way every pull-up sheet on the phone has them: the bar
/// along the bottom, half the screen, and the whole of it under the status bar.
enum MapDockDetent: Int, CaseIterable {
    case collapsed
    case half
    case full
}

/// What a toolbar panel is handed when it opens inside the dock's sheet rather
/// than as a window of its own: the way to close it, and the way its title band
/// moves the sheet, since the title stands where the search field did.
struct DockPanelHost {
    let close: () -> Void
    /// The finger's travel so far, upwards positive.
    let pullChanged: (CGFloat) -> Void
    /// Where the flick would land, upwards positive.
    let pullEnded: (CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var dockPanelHost: DockPanelHost? = nil
}

/// The furniture along the bottom of the map: one sheet, with a handle on it.
///
/// It is one shape that grows, not a bar that opens a window. Pull it and the
/// search field rides up with the top edge, all the way to the status bar, and
/// the lists come up underneath it — friends in the air, the server's numbers,
/// the longest flights, what is landing, the busiest fields. The bar of
/// destinations stays on the foot of it the whole way.
///
/// The pull is measured in screen coordinates rather than in the dock's own,
/// because the dock *moves while you are dragging it*. Measured locally, every
/// point it grew was subtracted from the distance the finger had travelled.
///
/// The toolbar's panels open inside it too. Friends, ATC, filters and the rest
/// take the search field's place with their own title and fill the sheet's
/// body, rather than throwing a second window up over the map; the close
/// button, or letting the sheet down to the bar, puts the field back.
///
/// Where the drag is taken from depends on the stop. Short of the top, the
/// whole sheet is a handle and the lists do not scroll — a drag anywhere moves
/// it. At the top the lists scroll, the field and the bar still move the sheet,
/// and pulling the lists down past their top lets the sheet back down to half.
struct MapDock: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme

    /// Positions currently open, badged on ATC.
    let atcCount: Int

    /// How many of the filter groups are narrowed.
    let activeFilters: Int

    /// Watched pilots currently in the air.
    let friendsAloft: Int

    /// Who is being watched, for the friends list in the sheet.
    let watched: Set<String>

    /// Where the sheet is resting. Held by the map so the chrome in the corners
    /// can step aside while it is up.
    @Binding var detent: MapDockDetent

    /// The height the sheet can grow into: from the top of the safe area to the
    /// foot of it, less the keyboard while one is up.
    let room: CGFloat

    let onPanel: (MapPanelKind) -> Void

    /// The whole stats window.
    let onOpenStats: () -> Void

    let onOpenFlight: (String) -> Void
    let onOpenAirport: (String) -> Void

    /// The toolbar panel open in the sheet, if one is: which, for the bar to
    /// mark, and the panel itself.
    let panelKind: MapPanelKind?
    let panel: AnyView?
    let onClosePanel: () -> Void

    @Binding var query: String
    let results: [MapSearchResult]
    let onSelect: (MapSearchResult) -> Void

    /// How far the finger has carried the sheet, upwards positive. Reset with
    /// the spring below, so a sheet let go of between stops settles.
    @GestureState(resetTransaction: Transaction(animation: Motion.chrome))
    private var pull: CGFloat = 0

    @GestureState private var isHeld = false

    /// The same pull, from a docked panel's title band — which is the panel's
    /// view rather than this one's, so it reports in rather than holding a
    /// gesture state of its own.
    @State private var titlePull: CGFloat = 0

    @State private var isSearchFocused = false

    @State private var scroll = ScrollPosition(edge: .top)

    // MARK: - Metrics

    /// The radius along the sheet's top. The bottom is square — it runs off the
    /// foot of the screen and the display rounds it. See `BottomEdge`.
    static let cornerRadius: CGFloat = BottomEdge.cornerRadius

    /// How far in from the sides of the screen everything in the dock sits.
    static let cardInset: CGFloat = 14

    private static let cardTop: CGFloat = 2
    private static let cardBottom: CGFloat = 6
    private static let rowGap: CGFloat = 10

    /// The band the grabber sits in.
    static let handleBand: CGFloat = 18

    /// How much of the map's bottom edge the collapsed dock covers, measured up
    /// from the safe area. Added up from the parts so it cannot drift.
    static let reservedHeight: CGFloat =
        cardTop + handleBand + MapSearchField.fieldHeight + rowGap + MapToolbar.height + cardBottom

    /// Room left above the full sheet, under the status bar.
    private static let topGap: CGFloat = 6

    /// How far the sheet gives above the top stop, however hard it is pulled.
    private static let overshootLimit: CGFloat = 24

    /// How far the lists have to be pulled past their top, with the sheet at
    /// full, before the sheet comes down to half.
    private static let releaseOverscroll: CGFloat = 70

    /// The height of the sheet at a stop, above the safe area's foot.
    static func height(for detent: MapDockDetent, in room: CGFloat) -> CGFloat {
        let full = max(room - topGap, reservedHeight)
        switch detent {
        case .collapsed: return reservedHeight
        case .half: return min(max(reservedHeight + 280, room * 0.5), full)
        case .full: return full
        }
    }

    // MARK: - Where the pull has got to

    private var restingHeight: CGFloat { Self.height(for: detent, in: room) }

    private var fullHeight: CGFloat { Self.height(for: .full, in: room) }

    /// The sheet's height on this frame: the stop, plus the finger, never below
    /// the bar and resisted past the top.
    private var liveHeight: CGFloat {
        let raw = restingHeight + pull + titlePull
        if raw > fullHeight {
            let over = raw - fullHeight
            return fullHeight + over * Self.overshootLimit / (over + 60)
        }
        return max(raw, Self.reservedHeight)
    }

    /// The bar stays on the foot of the sheet, except while the keyboard is up
    /// — then the room is the results'.
    private var showsToolbar: Bool { !isSearchFocused }

    /// Everything in the sheet that is not the scrolling body.
    private var chromeHeight: CGFloat {
        Self.cardTop + Self.handleBand + Self.cardBottom
            + (panel == nil ? MapSearchField.fieldHeight : 0)
            + (showsToolbar ? Self.rowGap + MapToolbar.height : 0)
    }

    private var bodyHeight: CGFloat { max(liveHeight - chromeHeight, 0) }

    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MapSearch.minimumLength
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                handle

                // A panel's title takes the field's place while one is open.
                if panel == nil {
                    MapSearchField(
                        query: $query,
                        results: results,
                        theme: theme,
                        isInDock: true,
                        showsResults: false,
                        focus: $isSearchFocused,
                        onSelect: pick
                    )
                    .transition(.opacity)
                }
            }
            .simultaneousGesture(pullGesture)

            if bodyHeight > 0.5 {
                Group {
                    if let panel {
                        panel
                            .environment(\.dockPanelHost, host)
                            // Short of the top the sheet takes the drags; the
                            // panel's list scrolls once the sheet is all the
                            // way up, the same as the sheet's own lists.
                            .scrollDisabled(detent != .full)
                            .transition(.opacity)
                    } else {
                        sheetBody
                    }
                }
                    .frame(height: bodyHeight, alignment: .top)
                    .clipped()
                    // Faded on the way up, so the first inch of lists hanging
                    // under the field reads as an opening, not a cut.
                    .opacity(Double(min(bodyHeight / 90, 1)))
                    .simultaneousGesture(pullGesture, including: detent == .full ? .subviews : .all)
            }

            if showsToolbar {
                MapToolbar(
                    theme: theme,
                    atcCount: atcCount,
                    activeFilters: activeFilters,
                    friendsAloft: friendsAloft,
                    selected: panelKind,
                    action: onPanel
                )
                .padding(.top, Self.rowGap)
                .simultaneousGesture(pullGesture)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, Self.cardInset)
        .padding(.top, Self.cardTop)
        .padding(.bottom, Self.cardBottom)
        .frame(height: liveHeight, alignment: .top)
        .background {
            // Down past the safe area and off the foot of the screen, so the
            // sheet fills both bottom corners rather than hovering above them.
            theme.sheetBackground
                .clipShape(BottomEdge.shape)
                .overlay {
                    BottomEdge.shape.stroke(theme.stroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .motion(Motion.chrome, value: showsToolbar)
        .motion(Motion.chrome, value: panelKind)
        .motion(Motion.chrome, value: isSearching)
        .environment(\.colorScheme, theme.colorScheme)
        .onChange(of: isSearchFocused) { _, focused in
            // Typing wants the room: the field goes to the top of the screen
            // and the results come up under it.
            if focused, detent != .full { settle(to: .full) }
        }
        .onChange(of: panelKind) { _, kind in
            if kind != nil, isSearchFocused { isSearchFocused = false }
        }
        .onChange(of: detent) { _, stop in
            if stop != .full {
                scroll.scrollTo(edge: .top)
                if isSearchFocused { isSearchFocused = false }
            }
        }
    }

    /// The scrolling body: what was searched for while there is a query, the
    /// lists otherwise.
    private var sheetBody: some View {
        ScrollView {
            if isSearching {
                MapSearchResultsCard(
                    query: query,
                    results: results,
                    theme: theme,
                    isInDock: true,
                    onSelect: pick
                )
                .padding(.top, 12)
                .padding(.bottom, 16)
            } else {
                MapDockSections(
                    theme: theme,
                    watched: watched,
                    onOpenStats: onOpenStats,
                    onOpenFlight: onOpenFlight,
                    onOpenAirport: onOpenAirport,
                    onPanel: onPanel
                )
                .environmentObject(feed)
            }
        }
        .scrollPosition($scroll)
        .scrollIndicators(.hidden)
        .scrollDisabled(detent != .full)
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            if offset < -Self.releaseOverscroll, detent == .full, !isSearchFocused {
                settle(to: .half)
            }
        }
    }

    /// The grabber, the way every pull-up on the phone marks itself.
    private var handle: some View {
        Capsule()
            .fill(theme.textSecondary.opacity(isHeld || detent != .collapsed ? 0.9 : 0.45))
            .frame(width: isHeld ? 56 : 40, height: 5)
            .motion(Motion.control, value: isHeld)
            .frame(maxWidth: .infinity, minHeight: Self.handleBand)
            .contentShape(Rectangle())
            .onTapGesture { step() }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Pull up for flights, airports and the numbers on this server")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { step() }
            .accessibilityAction(named: "Open the full stats") { onOpenStats() }
    }

    private var accessibilityLabel: String {
        switch detent {
        case .collapsed: return "Show more"
        case .half: return "Expand"
        case .full: return "Collapse"
        }
    }

    /// The pull itself, judged on where the flick would land, so a short flick
    /// moves the sheet the way a flick moves any sheet.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isHeld) { _, state, _ in state = true }
            .updating($pull) { value, state, _ in
                state = -value.translation.height
            }
            .onEnded { value in
                land(flick: -value.predictedEndTranslation.height)
            }
    }

    /// What a docked panel's title band is handed to move the sheet with.
    private var host: DockPanelHost {
        DockPanelHost(
            close: onClosePanel,
            // Only at the top stop. Short of it the whole body already moves
            // the sheet, and counting the title's drag as well would move it
            // twice as far as the finger.
            pullChanged: { travel in
                if detent == .full { titlePull = travel }
            },
            pullEnded: { flick in
                guard detent == .full else { return }
                land(flick: flick)
                withAnimation(Motion.chrome) { titlePull = 0 }
            }
        )
    }

    /// Settles on whichever stop is nearest where the flick would land.
    private func land(flick: CGFloat) {
        let landing = restingHeight + flick
        let nearest = MapDockDetent.allCases.min { lhs, rhs in
            abs(Self.height(for: lhs, in: room) - landing)
                < abs(Self.height(for: rhs, in: room) - landing)
        } ?? detent
        settle(to: nearest)
    }

    /// A tap on the handle: up a stop, and from the top back down to the bar.
    private func step() {
        switch detent {
        case .collapsed: settle(to: .half)
        case .half: settle(to: .full)
        case .full: settle(to: .collapsed)
        }
    }

    private func settle(to stop: MapDockDetent) {
        withAnimation(Motion.chrome) {
            detent = stop
        }
    }

    private func pick(_ result: MapSearchResult) {
        isSearchFocused = false
        query = ""
        onSelect(result)
    }
}
