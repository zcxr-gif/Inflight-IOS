import SwiftUI

/// A shortcut on the sheet's top row: somewhere this pilot goes often enough
/// that finding it by typing is work the app should have saved them.
///
/// Built by the map rather than declared here, because what belongs on the row
/// is entirely about the state of the app — an aeroplane you are flying right
/// now, a field on your profile, a watchlist with somebody in the air. The row
/// disappears when none of them apply, which for a fresh install is all of them.
struct MapPlace: Identifiable {

    /// One answer among several. A shortcut with options is a menu rather than
    /// a button — two aircraft under one name is the case it exists for.
    struct Option: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let action: () -> Void
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String

    /// Filled with the accent when what it points at is live right now, the
    /// same way every other switched-on thing in the app reads.
    var isLive: Bool = false

    var options: [Option] = []

    let action: () -> Void
}

/// One of the sheet's destinations, carrying whatever state it has to report:
/// positions open, pilots in the air, a map that is being filtered.
struct MapDestination: Identifiable {

    let kind: MapPanelKind

    /// A count, when the number is the thing you would open the panel to find
    /// out. Nil shows nothing rather than a zero, which reads as a broken feed.
    var badge: String? = nil

    /// A plain mark, for state that is on or off rather than counted.
    var isMarked: Bool = false

    var id: String { kind.rawValue }
}

/// The map's home: a sheet along the bottom of the screen that stays put.
///
/// This is the Apple Maps arrangement, and it replaces two pieces of furniture
/// that used to sit at opposite ends of the screen — a search field across the
/// top and a five-item bar along the bottom. Both were permanent, both covered
/// map, and neither could hold anything more than it already did.
///
/// One sheet holds all of it: what you are looking for, where you have already
/// been, the shortcuts worth keeping, and every panel the app can open. Resting
/// at its collapsed height it costs the bottom hundred points of the screen and
/// gives the whole top back; a drag or a tap in the field brings the rest up.
///
/// It is a view in the map's own stack rather than a `.sheet`. The system's
/// sheets are modal presentations and only one is up at a time — the flight
/// window is one, and so is every panel this sheet opens. A sheet that has to
/// coexist with those cannot be one of them.
struct MapHomeSheet: View {

    /// Where the sheet rests. Three, like Apple's: out of the way, half up for
    /// reading a list, and all the way up for working through one.
    enum Detent: CaseIterable, Equatable {
        case collapsed
        case medium
        case expanded
    }

    /// What the collapsed sheet covers, measured above the home indicator —
    /// the grabber, the search field, and a few points of the list under it, so
    /// the sheet reads as something that continues rather than as a bar.
    ///
    /// This is what the chrome in the map's bottom corners sits above; that
    /// chrome is laid out inside the safe area, so it is the right number for
    /// it.
    static let collapsedHeight: CGFloat = 88

    /// What the map keeps clear when it frames something: the sheet, plus the
    /// band the home indicator floats in, which the sheet draws into. The map
    /// ignores the safe area, so it needs the taller of the two figures.
    static let reservedHeight: CGFloat = 122

    @Binding var query: String
    @Binding var detent: Detent

    /// Already ranked by `MapSearch`. Passed in rather than computed here so
    /// the map decides what pool is being searched.
    let results: [MapSearchResult]

    let recents: [MapRecent]

    /// Which of the remembered aircraft the feed can still see. A row for one
    /// that has gone is shown and dimmed rather than dropped: it is a record of
    /// where the map has been, and quietly deleting itself when a pilot lands
    /// would make the list look broken.
    let liveFlightKeys: Set<String>

    let places: [MapPlace]
    let destinations: [MapDestination]

    let theme: FlightInfoTheme

    /// One line about the feed, along the foot of the sheet.
    let status: String

    let onSelectResult: (MapSearchResult) -> Void
    let onSelectRecent: (MapRecent) -> Void
    let onClearRecents: () -> Void
    let onOpenPanel: (MapPanelKind) -> Void

    @FocusState private var isFocused: Bool

    /// How far the current drag has travelled, positive downwards. Held in
    /// state rather than in `@GestureState` so it can be animated back to zero
    /// as the sheet settles — a gesture state resets instantly, which lands the
    /// sheet with a jump at the end of every drag.
    @State private var drag: CGFloat = 0

    /// The results card is up whenever there is something to show for what has
    /// been typed — including nothing, which is worth saying rather than
    /// leaving the field to look broken.
    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MapSearch.minimumLength
    }

    var body: some View {
        GeometryReader { proxy in
            let heights = Heights(available: proxy.size.height)

            sheetBody(in: heights)
                .frame(height: resolvedHeight(in: heights), alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // The sheet is where the keyboard's field lives, and it goes to its full
        // height to make room rather than being shoved up by the system — which
        // would push its top edge off the screen by the height of the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .environment(\.colorScheme, theme.colorScheme)
        .onChange(of: isFocused) { _, focused in
            guard focused, detent != .expanded else { return }
            withAnimation(Self.settle) { detent = .expanded }
        }
    }

    // MARK: - Heights

    /// The three resting heights, worked out from whatever the sheet has to
    /// live in. Two are proportions rather than constants: half a phone and
    /// half a tablet are not the same number of points.
    private struct Heights {

        let collapsed: CGFloat
        let medium: CGFloat
        let expanded: CGFloat

        init(available: CGFloat) {
            collapsed = MapHomeSheet.collapsedHeight
            medium = max(collapsed, min(available * 0.46, 420))
            expanded = max(medium, available * 0.94)
        }

        func value(for detent: Detent) -> CGFloat {
            switch detent {
            case .collapsed: return collapsed
            case .medium: return medium
            case .expanded: return expanded
            }
        }

        /// Whichever rest is nearest to where a drag is heading.
        func detent(nearest height: CGFloat) -> Detent {
            Detent.allCases.min { first, second in
                abs(value(for: first) - height) < abs(value(for: second) - height)
            } ?? .collapsed
        }
    }

    private static let settle = Animation.spring(response: 0.34, dampingFraction: 0.86)

    private func resolvedHeight(in heights: Heights) -> CGFloat {
        min(max(heights.value(for: detent) - drag, heights.collapsed), heights.expanded)
    }

    private func dragGesture(in heights: Heights) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in drag = value.translation.height }
            .onEnded { value in
                // Where the drag is going rather than where it stopped, so a
                // flick lands the sheet a detent away instead of dropping it
                // back to the one it barely left.
                let projected = heights.value(for: detent) - value.predictedEndTranslation.height
                let target = heights.detent(nearest: projected)

                if target == .collapsed { isFocused = false }

                withAnimation(Self.settle) {
                    detent = target
                    drag = 0
                }
            }
    }

    private func move(to target: Detent) {
        if target == .collapsed { isFocused = false }
        withAnimation(Self.settle) { detent = target }
    }

    // MARK: - The sheet itself

    private func sheetBody(in heights: Heights) -> some View {
        VStack(spacing: 0) {
            grabber(in: heights)
            searchRow
            content
        }
        .background {
            theme.sheetBackground
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 26,
                        topTrailingRadius: 26,
                        style: .continuous
                    )
                )
                // The sheet draws to the bottom edge of the screen, so the home
                // indicator floats over its foot rather than claiming a band of
                // its own underneath it.
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The handle, and the whole strip it sits in — a thumb reaching for a
    /// grabber lands somewhere near it, not on five points of capsule.
    ///
    /// The strip is the only thing that drags the sheet. Everything below it is
    /// a scrolling list, and a drag gesture laid over that is a gesture
    /// fighting the scroll view for every swipe.
    private func grabber(in heights: Heights) -> some View {
        Capsule()
            .fill(theme.textDim)
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: heights))
            .onTapGesture { move(to: detent == .collapsed ? .medium : .collapsed) }
            .accessibilityElement()
            .accessibilityLabel("Sheet handle")
            .accessibilityValue(detentLabel)
            .accessibilityAdjustableAction { direction in
                switch (direction, detent) {
                case (.increment, .collapsed): move(to: .medium)
                case (.increment, .medium): move(to: .expanded)
                case (.decrement, .expanded): move(to: .medium)
                case (.decrement, .medium): move(to: .collapsed)
                default: break
                }
            }
    }

    private var detentLabel: String {
        switch detent {
        case .collapsed: return "Closed"
        case .medium: return "Half open"
        case .expanded: return "Open"
        }
    }

    // MARK: - Search

    private var searchRow: some View {
        HStack(spacing: 10) {
            field

            if isFocused || !query.isEmpty {
                Button("Cancel") {
                    query = ""
                    isFocused = false
                    move(to: .collapsed)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: query.isEmpty)
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            TextField("Search flights or airports", text: $query)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                // Return takes the best match, which for a typed callsign or
                // ICAO is the one the search was for.
                .onSubmit {
                    guard let first = results.first else { return }
                    select(first)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .flightInfoSurface(theme, radius: 22)
        .contentShape(Capsule())
        // A tap anywhere on the field, not just on the twenty points of text
        // cursor in the middle of it. Simultaneous rather than exclusive: the
        // field and the clear button are both inside this, and a tap gesture
        // that consumed the press would be a clear button that never fires.
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
    }

    // MARK: - What is under it

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isSearching {
                    resultsSection
                } else {
                    if !places.isEmpty { placesSection }
                    if !recents.isEmpty { recentsSection }
                    destinationsSection
                    statusLine
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        // Nothing to scroll at the collapsed height, and a list that scrolls
        // behind a closed sheet is a list nobody can see moving.
        .scrollDisabled(detent == .collapsed)
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if results.isEmpty {
            PanelEmptyState(
                symbol: "magnifyingglass",
                title: "Nothing matching \"\(query)\"",
                detail: "Callsigns, pilot names, registrations and ICAO codes all work."
            )
        } else {
            card {
                ForEach(results) { result in
                    if result.id != results.first?.id { PanelDivider() }

                    Button { select(result) } label: {
                        resultRow(result)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Places

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Places")

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(places) { place in
                        if place.options.isEmpty {
                            Button { place.action() } label: { tile(place) }
                                .buttonStyle(.plain)
                        } else {
                            Menu {
                                ForEach(place.options) { option in
                                    Button(action: option.action) {
                                        Label(option.label, systemImage: option.symbol)
                                    }
                                }
                            } label: {
                                tile(place)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func tile(_ place: MapPlace) -> some View {
        VStack(spacing: 7) {
            Image(systemName: place.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(place.isLive ? theme.onAccent : theme.textPrimary)
                .frame(width: 58, height: 58)
                .background {
                    Circle().fill(place.isLive ? theme.accent : theme.surfaceFill)
                }
                .overlay {
                    if !place.isLive {
                        Circle().strokeBorder(theme.stroke, lineWidth: 1)
                    }
                }

            Text(place.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            Text(place.detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
        }
        .frame(width: 74)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Recents", action: onClearRecents, actionLabel: "Clear")

            card {
                ForEach(recents) { recent in
                    if recent.id != recents.first?.id { PanelDivider() }

                    let canOpen = isOpenable(recent)

                    Button { onSelectRecent(recent) } label: {
                        row(
                            symbol: recent.symbol,
                            title: recent.title,
                            detail: recent.detail,
                            trailing: canOpen ? nil : "NOT FLYING"
                        )
                        .opacity(canOpen ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    // A row that cannot go anywhere does not pretend it can.
                    .disabled(!canOpen)
                }
            }
        }
    }

    /// A field always opens: the dataset is on the device. An aircraft only
    /// opens while the feed can still see it.
    private func isOpenable(_ recent: MapRecent) -> Bool {
        switch recent.kind {
        case .airport: return true
        case .flight: return liveFlightKeys.contains(recent.key)
        }
    }

    // MARK: - Destinations

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Browse")

            card {
                ForEach(destinations) { destination in
                    if destination.id != destinations.first?.id { PanelDivider() }

                    Button { onOpenPanel(destination.kind) } label: {
                        row(
                            symbol: destination.kind.symbol,
                            title: destination.kind.label,
                            detail: destination.kind.detail,
                            trailing: nil,
                            badge: destination.badge,
                            isMarked: destination.isMarked,
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(readout(for: destination))
                }
            }
        }
    }

    private func readout(for destination: MapDestination) -> String {
        guard let badge = destination.badge else {
            return destination.isMarked
                ? "\(destination.kind.label), on"
                : destination.kind.label
        }
        return "\(destination.kind.label), \(badge)"
    }

    private var statusLine: some View {
        Text(status)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.textDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .flightInfoLine(minimumScale: 0.7)
    }

    // MARK: - Pieces

    private func header(
        _ title: String,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            Spacer(minLength: 8)

            if let action = action, let actionLabel = actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    @ViewBuilder
    private func resultRow(_ result: MapSearchResult) -> some View {
        switch result {
        case .flight(let flight):
            row(
                symbol: "airplane",
                title: flight.displayName,
                detail: flightDetail(flight),
                trailing: routeLabel(flight)
            )

        case .airport(let airport):
            row(
                symbol: "mappin.and.ellipse",
                title: airport.icao,
                detail: airport.name,
                trailing: airport.flag.isEmpty ? "AIRPORT" : "\(airport.flag) AIRPORT"
            )
        }
    }

    private func row(
        symbol: String,
        title: String,
        detail: String,
        trailing: String?,
        badge: String? = nil,
        isMarked: Bool = false,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, height: 34)
                .background { Circle().fill(theme.surfaceFill) }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailing = trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
            }

            if let badge = badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background { Capsule().fill(theme.accent) }
                    .fixedSize()
            } else if isMarked {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 7, height: 7)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func flightDetail(_ flight: Flight) -> String {
        let pilot = flight.username ?? "Pilot"
        let aircraft = flight.aircraftName.isEmpty ? "Unknown aircraft" : flight.aircraftName
        return "\(pilot) · \(aircraft)"
    }

    /// Where it is going, when it has said. Aircraft with nothing filed show
    /// their height instead, which is the next most useful thing about them.
    private func routeLabel(_ flight: Flight) -> String? {
        let departure = flight.departureIcao ?? ""
        let arrival = flight.arrivalIcao ?? ""

        if !arrival.isEmpty {
            return "\(departure.isEmpty ? "———" : departure) → \(arrival)"
        }

        guard flight.altitudeFeet.isFinite, flight.altitudeFeet > 0 else { return nil }
        return "\(Format.number(flight.altitudeFeet)) ft"
    }

    private func select(_ result: MapSearchResult) {
        query = ""
        isFocused = false
        move(to: .collapsed)
        onSelectResult(result)
    }
}
