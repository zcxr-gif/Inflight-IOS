import SwiftUI

/// Where the dock is resting.
///
/// Four stops. The three every pull-up sheet on the phone has — the bar along
/// the bottom, half the screen, and the whole of it under the status bar — and
/// one under the bar, the way Maps has it: pushed down past the bar, the island
/// lets the toolbar go and is the search field alone.
enum MapDockDetent: Int, CaseIterable {
    case minimized
    case collapsed
    case half
    case full

    /// Pulled up over the map, rather than resting along the foot of it.
    var isRaised: Bool { self == .half || self == .full }
}

/// What a toolbar panel is handed when it opens inside the dock's sheet rather
/// than as a window of its own: the width it is laid out at, and the way its
/// title band moves the sheet, since the title stands where the search field
/// did. There is no close button — the sheet is swiped down to close it.
struct DockPanelHost {
    /// The sheet's inner width. Stated rather than left to the panel's rows,
    /// one of which is always long enough to push the sheet off the screen.
    let width: CGFloat
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
/// body, rather than throwing a second window up over the map; letting the
/// sheet down to the bar, or the same item on the bar again, puts the field
/// back.
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
    /// foot of the screen, or to the top of the keyboard while one is up.
    let room: CGFloat

    /// The screen's width. The sheet is held to it, so nothing inside can make
    /// the sheet wider than the screen it stands on.
    let width: CGFloat

    let onPanel: (MapPanelKind) -> Void

    /// The whole stats window.
    let onOpenStats: () -> Void

    let onOpenFlight: (String) -> Void
    let onOpenAirport: (String) -> Void

    /// The toolbar panel open in the sheet, if one is: which, for the bar to
    /// mark, and the panel itself.
    let panelKind: MapPanelKind?
    let panel: AnyView?

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

    /// Bumped to send the lists back to the top. A counter rather than
    /// `ScrollPosition`, which is iOS 18, so the dock behaves the same on 17.
    @State private var scrollToTop = 0

    private static let topAnchor = "dock-top"

    // MARK: - Metrics

    /// The gap the island keeps from the edges of the screen: both sides and
    /// the foot. It floats, the way Safari's bar does, rather than standing on
    /// the bottom edge — so it never touches the display's rounded corners.
    static let islandMargin: CGFloat = 12

    /// How far in from the island's own edges everything inside it sits.
    static let islandPadding: CGFloat = 12

    /// All four corners. The bar's radius plus the padding it is held at, so
    /// the bar's curve and the island's are concentric — and, at this margin,
    /// near enough concentric with the display's own corners as well.
    static let cornerRadius: CGFloat = MapToolbar.radius + islandPadding

    private static let cardTop: CGFloat = 2
    private static let rowGap: CGFloat = 10

    /// The band the grabber sits in.
    static let handleBand: CGFloat = 18

    /// The collapsed island's own height. Added up from the parts so it cannot
    /// drift.
    static let islandHeight: CGFloat =
        cardTop + handleBand + MapSearchField.fieldHeight + rowGap + MapToolbar.height + islandPadding

    /// The minimized island: the grabber and the search field, no toolbar.
    static let minimizedHeight: CGFloat =
        cardTop + handleBand + MapSearchField.fieldHeight + islandPadding

    /// How much of the map's bottom edge the dock covers while it rests along
    /// the foot, measured up from the safe area, which is how the map and the
    /// corner controls ask. Raised stops answer as the bar does: the sheet is
    /// over the map, not something the map frames around.
    ///
    /// The island is laid out from the foot of the screen, not the safe area —
    /// its lower edge stands down into the home indicator's band, as Safari's
    /// does — so the band is taken back off here.
    ///
    /// The band is handed in, worked out from heights SwiftUI measures (see
    /// `ContentView.noteHomeIndicatorBand`). It used to be read off the key
    /// window from inside the body, and with that read in it the main screen
    /// stopped updating after its first pass — no traffic handed to the map,
    /// and no button on it doing anything.
    static func reservedHeight(for detent: MapDockDetent, homeIndicatorBand: CGFloat) -> CGFloat {
        let island = detent == .minimized ? minimizedHeight : islandHeight
        return max(island + islandMargin - homeIndicatorBand, 0)
    }

    /// Room left above the full sheet, under the status bar.
    private static let topGap: CGFloat = 6

    /// How far the sheet gives above the top stop, however hard it is pulled.
    private static let overshootLimit: CGFloat = 24

    /// How far the lists have to be pulled past their top, with the sheet at
    /// full, before the sheet comes down to half.
    private static let releaseOverscroll: CGFloat = 70

    /// The island's height at a stop. `room` runs from the top of the safe
    /// area to the foot of the screen, or to the top of the keyboard while
    /// one is up; the island stands `islandMargin` above that foot.
    static func height(for detent: MapDockDetent, in room: CGFloat) -> CGFloat {
        let full = max(room - topGap - islandMargin, islandHeight)
        switch detent {
        case .minimized: return minimizedHeight
        case .collapsed: return islandHeight
        case .half: return min(max(islandHeight + 280, room * 0.5), full)
        case .full: return full
        }
    }

    // MARK: - Where the pull has got to

    private var restingHeight: CGFloat { Self.height(for: detent, in: room) }

    private var fullHeight: CGFloat { Self.height(for: .full, in: room) }

    /// The sheet's height on this frame: the stop, plus the finger, never below
    /// the search field alone and resisted past the top.
    private var liveHeight: CGFloat {
        let raw = restingHeight + pull + titlePull
        if raw > fullHeight {
            let over = raw - fullHeight
            return fullHeight + over * Self.overshootLimit / (over + 60)
        }
        return max(raw, Self.minimizedHeight)
    }

    /// The bar stays on the foot of the sheet, except while the keyboard is up
    /// — then the room is the results' — and once the island has been pushed
    /// all the way down to the search field alone.
    private var showsToolbar: Bool {
        !isSearchFocused && liveHeight > Self.minimizedHeight + 0.5
    }

    /// How much of the bar is showing, between the minimized island and the
    /// bar's own stop. It rides the finger: pushing the island down slides the
    /// bar under its foot and fades it, rather than snapping it away.
    private var toolbarReveal: Double {
        let travel = Self.islandHeight - Self.minimizedHeight
        guard travel > 0 else { return 1 }
        return Double(min(max((liveHeight - Self.minimizedHeight) / travel, 0), 1))
    }

    /// How far the island has filled out into the screen's edges, 0...1.
    ///
    /// Nothing at half and below, where it floats clear of the edges. All of
    /// it at the top stop, where a panel or the lists have the whole screen
    /// and a gap down both sides and under the foot is just the map showing
    /// through round a page. In between it rides the height, so it follows
    /// the finger on a pull and the sheet's own spring when it settles.
    private var fill: CGFloat {
        let half = Self.height(for: .half, in: room)
        let travel = fullHeight - half
        guard travel > 1 else { return detent == .full ? 1 : 0 }
        return min(max((liveHeight - half) / travel, 0), 1)
    }

    /// How far the island's edge stands out past its content on the sides and
    /// the foot: from nothing to the whole margin, so the gaps close from the
    /// inside out. The content itself never moves.
    private var spread: CGFloat { Self.islandMargin * fill }

    /// The island's two lower corners. Rounded while it floats; square once it
    /// reaches the foot of the screen, where the display's own corners round
    /// it, the same as the flight window.
    private var bottomRadius: CGFloat { Self.cornerRadius * (1 - fill) }

    /// Everything in the sheet that is not the scrolling body.
    private var chromeHeight: CGFloat {
        Self.cardTop + Self.handleBand + Self.islandPadding
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
                            .frame(width: innerWidth)
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
                .opacity(toolbarReveal)
                .simultaneousGesture(pullGesture)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, Self.islandPadding)
        .padding(.top, Self.cardTop)
        .padding(.bottom, Self.islandPadding)
        .frame(width: islandWidth, height: liveHeight, alignment: .top)
        // Pushed down towards the minimized stop the bar is taller than the
        // island it is in, and slides out under its foot rather than over it.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .background {
            // An island with four rounded corners, clear of the screen's
            // edges — until the sheet goes to the top, when its edge grows out
            // past the content to meet both sides and the foot. See `fill`.
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: Self.cornerRadius,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: Self.cornerRadius,
                style: .continuous
            )
            theme.sheetBackground
                .clipShape(shape)
                .overlay {
                    shape.stroke(theme.stroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24 * (1 - fill)), radius: 20, y: 6)
                .padding(EdgeInsets(top: 0, leading: -spread, bottom: -spread, trailing: -spread))
        }
        .padding(.bottom, Self.islandMargin)
        .frame(width: width)
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
                scrollToTop += 1
                if isSearchFocused { isSearchFocused = false }
            }
        }
    }

    /// The scrolling body: what was searched for while there is a query, the
    /// lists otherwise.
    private var sheetBody: some View {
        ScrollViewReader { proxy in
            let lists = ScrollView {
                VStack(spacing: 0) {
                    // The top of the lists: what a collapse scrolls back to,
                    // and — before iOS 18 — what the overscroll is read from.
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topAnchor)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: DockOverscrollKey.self,
                                    value: geometry.frame(in: .named(Self.topAnchor)).minY
                                )
                            }
                        }

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
            }
            .coordinateSpace(.named(Self.topAnchor))
            .scrollIndicators(.hidden)
            .scrollDisabled(detent != .full)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: scrollToTop) { _, _ in
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }

            if #available(iOS 18.0, *) {
                lists.onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    releaseIfPulledPast(-offset)
                }
            } else {
                lists.onPreferenceChange(DockOverscrollKey.self) { pulled in
                    releaseIfPulledPast(pulled)
                }
            }
        }
    }

    /// Pulled down past the top of the lists far enough, the full sheet lets
    /// go to the half. `pulled` is how far past the top, positive downwards.
    private func releaseIfPulledPast(_ pulled: CGFloat) {
        if pulled > Self.releaseOverscroll, detent == .full, !isSearchFocused {
            settle(to: .half)
        }
    }

    /// The grabber, the way every pull-up on the phone marks itself.
    private var handle: some View {
        Capsule()
            .fill(theme.textSecondary.opacity(isHeld || detent.isRaised ? 0.9 : 0.45))
            .frame(width: isHeld ? 56 : 40, height: 5)
            .motion(Motion.control, value: isHeld)
            .frame(maxWidth: .infinity, minHeight: Self.handleBand)
            .contentShape(Rectangle())
            .onTapGesture { step() }
            .accessibilityElement()
            .accessibilityLabel(L(accessibilityLabel))
            .accessibilityHint("Pull up for flights, airports and the numbers on this server")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { step() }
            .accessibilityAction(named: "Open the full stats") { onOpenStats() }
    }

    private var accessibilityLabel: String {
        switch detent {
        case .minimized: return "Show toolbar"
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
                land(
                    flick: -value.predictedEndTranslation.height,
                    travel: -value.translation.height
                )
            }
    }

    private var islandWidth: CGFloat { max(width - Self.islandMargin * 2, 0) }

    private var innerWidth: CGFloat { max(islandWidth - Self.islandPadding * 2, 0) }

    /// What a docked panel's title band is handed to move the sheet with.
    private var host: DockPanelHost {
        DockPanelHost(
            width: innerWidth,
            // Only at the top stop. Short of it the whole body already moves
            // the sheet, and counting the title's drag as well would move it
            // twice as far as the finger.
            pullChanged: { travel in
                if detent == .full { titlePull = travel }
            },
            pullEnded: { flick in
                guard detent == .full else { return }
                land(flick: flick, travel: flick)
                withAnimation(Motion.chrome) { titlePull = 0 }
            }
        )
    }

    /// How far a pull has to carry the sheet to have meant it: past this, it
    /// moves at least one stop that way rather than springing back.
    private static let commitTravel: CGFloat = 44

    /// Settles on whichever stop is nearest where the flick would land, with
    /// two rules on top.
    ///
    /// A pull that went somewhere goes somewhere. Nearest alone sent a sheet
    /// pulled a third of the way down from the top straight back up to it —
    /// the stops are far apart there — which reads as the sheet bouncing back
    /// out of your hand.
    ///
    /// And the search field alone is reached only from the bar. A flick down
    /// from half or the top travels past the bar's stop, and nearest then
    /// picked the stop under it, so the bar went with it in one movement: the
    /// sheet came down to the field alone when it was meant to come down to
    /// the field and the bar, and the second push had nothing left to do.
    private func land(flick: CGFloat, travel: CGFloat) {
        let landing = restingHeight + flick
        var target = MapDockDetent.allCases.min { lhs, rhs in
            abs(Self.height(for: lhs, in: room) - landing)
                < abs(Self.height(for: rhs, in: room) - landing)
        } ?? detent

        if target == detent, abs(travel) > Self.commitTravel {
            let next = detent.rawValue + (travel < 0 ? -1 : 1)
            target = MapDockDetent(rawValue: next) ?? detent
        }

        if target == .minimized, detent != .collapsed, detent != .minimized {
            target = .collapsed
        }

        settle(to: target)
    }

    /// A tap on the handle: up a stop, and from the top back down to the bar.
    private func step() {
        switch detent {
        case .minimized: settle(to: .collapsed)
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

/// How far the dock's lists have been pulled down past their top, read from
/// the top anchor's position in the scroll view. Only used before iOS 18,
/// which has `onScrollGeometryChange` for it.
private struct DockOverscrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
