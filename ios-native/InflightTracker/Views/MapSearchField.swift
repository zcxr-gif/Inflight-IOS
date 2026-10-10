import SwiftUI

/// The search field across the top of the map, and the results under it.
///
/// Both halves of what it finds are already on the device — the traffic packet
/// and the offline airport dataset — so results appear as the query is typed,
/// with no debounce and nothing to wait for. Picking an aircraft opens its
/// window; picking a field opens the field's own panel.
struct MapSearchField: View {

    @Binding var query: String

    /// Already ranked by `MapSearch`. Passed in rather than computed here so
    /// the owner decides what pool is being searched.
    let results: [MapSearchResult]

    let theme: FlightInfoTheme

    /// Set inside the map's dock: the results rise out of the field rather
    /// than dropping below it — the field is at the bottom of the screen and
    /// below it is the keyboard — and the field is a well in the dock rather
    /// than a pane of glass of its own lying on top of one.
    var isInDock: Bool = false

    /// Off where the owner lays the results out itself — the dock puts them in
    /// its own scrolling body, under the field, once the sheet is pulled up.
    var showsResults: Bool = true

    /// Whether the field has the keyboard, for an owner that moves when it
    /// does. Kept in step both ways, so the owner can also put it away.
    var focus: Binding<Bool>? = nil

    let onSelect: (MapSearchResult) -> Void

    @FocusState private var isFocused: Bool

    /// The field's own height in the dock, stated so the dock can add itself
    /// up before anything has drawn.
    static let fieldHeight: CGFloat = 46

    /// The results card is up whenever there is something to show for what has
    /// been typed — including nothing, which is worth saying rather than
    /// leaving the field to look broken.
    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MapSearch.minimumLength
    }

    var body: some View {
        VStack(spacing: 8) {
            if isInDock {
                if showsResults, isSearching {
                    resultsCard
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                field
            } else {
                field

                if showsResults, isSearching {
                    resultsCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .motion(Motion.chrome, value: isSearching)
        .motion(Motion.row, value: results.map(\.id))
        .environment(\.colorScheme, theme.colorScheme)
        .onChange(of: isFocused) { _, focused in
            if let focus, focus.wrappedValue != focused { focus.wrappedValue = focused }
        }
        .onChange(of: focus?.wrappedValue ?? false) { _, wanted in
            if isFocused != wanted { isFocused = wanted }
        }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            TextField("Search flights or airports", text: $query)
                .font(.system(size: 15, weight: .medium))
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
            } else if isFocused {
                // Nothing typed and the keyboard up: the way out is to put the
                // keyboard away, not to clear an empty field.
                Button {
                    isFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keyboard")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isInDock ? 0 : 11)
        .frame(height: isInDock ? Self.fieldHeight : nil)
        .modifier(SearchSurface(theme: theme, isInDock: isInDock, shape: Capsule()))
        .contentShape(Capsule())
    }

    // MARK: - Results

    private var resultsCard: some View {
        MapSearchResultsCard(
            query: query,
            results: results,
            theme: theme,
            isInDock: isInDock,
            onSelect: select
        )
    }

    private func select(_ result: MapSearchResult) {
        isFocused = false
        query = ""
        onSelect(result)
    }
}

/// What the search found, as one card of rows. Its own view so the dock can lay
/// it out in its scrolling body rather than stacked against the field.
struct MapSearchResultsCard: View {

    let query: String
    let results: [MapSearchResult]
    let theme: FlightInfoTheme
    var isInDock: Bool = false
    let onSelect: (MapSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text(Lf("Nothing matching “%@”", query))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                ForEach(results) { result in
                    if result.id != results.first?.id {
                        Rectangle().fill(theme.stroke).frame(height: 1)
                    }

                    Button { onSelect(result) } label: {
                        row(for: result)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .modifier(
            SearchSurface(
                theme: theme,
                isInDock: isInDock,
                shape: RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
            )
        )
    }

    @ViewBuilder
    private func row(for result: MapSearchResult) -> some View {
        switch result {
        case .flight(let flight):
            resultRow(
                symbol: "airplane",
                title: flight.displayName,
                detail: flightDetail(flight),
                trailing: routeLabel(flight)
            )

        case .airport(let airport):
            resultRow(
                symbol: "mappin.and.ellipse",
                title: airport.icao,
                detail: airport.name,
                trailing: airport.flag.isEmpty ? "AIRPORT" : "\(airport.flag) AIRPORT"
            )
        }
    }

    private func resultRow(
        symbol: String,
        title: String,
        detail: String,
        trailing: String?
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                Text(L(detail))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailing = trailing {
                Text(L(trailing))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
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
}

/// What the field and its results are drawn on: glass of their own over the
/// map, or a well pressed into the dock — which is already glass, and glass on
/// glass reads as two cards stacked rather than as a field in a panel.
private struct SearchSurface<S: Shape>: ViewModifier {

    let theme: FlightInfoTheme
    let isInDock: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if isInDock {
            content
                // The same soft well as the bar under it, with no outline.
                .background { shape.fill(theme.surfaceFill) }
                .clipShape(shape)
        } else {
            content.flightInfoChrome(theme, in: shape)
        }
    }
}
