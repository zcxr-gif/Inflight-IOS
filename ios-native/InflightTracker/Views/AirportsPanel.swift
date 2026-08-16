import SwiftUI

/// Where the server actually is, from the toolbar's airports button.
///
/// The map answers "what is flying" and the ATC panel answers "who is
/// working". Neither answers "where is everyone", which on a server of a
/// couple of thousand aircraft is the question you open the app with — and the
/// packet has always known, in the routes every aircraft filed, without anyone
/// reading it.
///
/// It is also how a field gets opened without knowing its code. The airport
/// panel was reachable by typing an ICAO, which is fine for a field you already
/// had in mind and no use at all for finding one.
struct AirportsPanel: View {

    /// Open one of the fields. Declared last so it is the panel's trailing
    /// closure at the call site.
    let onSelect: (Airport) -> Void

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// Long enough to be a board rather than a podium, short enough that the
    /// tail — fields with one aircraft filed through them, of which there are
    /// hundreds — never gets going.
    private static let boardSize = 12

    private var board: [AirportTraffic] {
        AirportTraffic.busiest(in: feed.flights, limit: Self.boardSize)
    }

    /// Fields with somebody on frequency, so a controlled airport can be
    /// marked as one. A set because the board is walked against it per row.
    private var controlled: Set<String> {
        Set(feed.atcStations.filter { !$0.isCenter }.map(\.identifier))
    }

    var body: some View {
        let board = self.board

        MapPanel(title: "Airports", subtitle: subtitle(for: board)) {
            PanelSection(title: "BUSIEST RIGHT NOW") {
                if board.isEmpty {
                    PanelEmptyState(
                        symbol: "mappin.slash",
                        title: feed.status.isLive ? "Nobody has filed a route" : "Waiting for the feed",
                        detail: feed.status.isLive
                            ? "Aircraft on \(feed.server) appear here as soon as they file a departure or a destination."
                            : "The board fills in as soon as the server is reporting."
                    )
                } else {
                    ForEach(board) { entry in
                        if entry.id != board.first?.id { PanelDivider() }
                        row(entry)
                    }
                }
            }

            HintStrip(placement: .airports)
        }
    }

    private func subtitle(for board: [AirportTraffic]) -> String {
        guard !board.isEmpty else { return feed.server }
        return "Busiest of \(feed.flights.count) aircraft · \(feed.server)"
    }

    private func row(_ entry: AirportTraffic) -> some View {
        Button {
            onSelect(entry.airport)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(entry.airport.icao)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize()

                        if !entry.airport.flag.isEmpty {
                            Text(entry.airport.flag).font(.system(size: 11))
                        }

                        // Worth marking rather than leaving to be discovered by
                        // opening it: a field with a tower open is a different
                        // proposition from a busy one without.
                        if controlled.contains(entry.airport.icao) {
                            AtcOnlineBadge(theme: theme)
                        }
                    }

                    Text(entry.airport.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.75)
                }

                Spacer(minLength: 8)

                movements(entry)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(entry.airport.icao), \(entry.inbound) inbound, \(entry.outbound) departing"
        )
    }

    /// In and out, as two small columns. Arrows rather than words: the pair has
    /// to stay narrow enough that a long airport name keeps the row.
    private func movements(_ entry: AirportTraffic) -> some View {
        HStack(spacing: 12) {
            count(entry.inbound, symbol: "arrow.down.to.line")
            count(entry.outbound, symbol: "arrow.up.forward")
        }
        .fixedSize()
    }

    private func count(_ value: Int, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textDim)

            Text("\(value)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                // Dimmed at nought so a field that is all arrivals reads as
                // one, instead of as two numbers you have to compare.
                .foregroundStyle(value == 0 ? theme.textDim : theme.textPrimary)
        }
        .accessibilityHidden(true)
    }
}
