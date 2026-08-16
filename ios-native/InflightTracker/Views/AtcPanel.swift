import Combine
import SwiftUI

/// Who is controlling, from the toolbar's ATC button.
///
/// The feed publishes this on its own channel, so the list is exactly what the
/// server is broadcasting rather than anything inferred from the traffic. Each
/// field is a card of the positions open there — read top to bottom, it is the
/// sequence an aircraft would work through on the way out.
struct AtcPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Re-read once a minute so "online for" counts up while the panel is
    /// open. The list itself is redrawn by the feed.
    @State private var now = Date()

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var theme: FlightInfoTheme { appearance.theme }

    /// Tapping a field takes the map to it and closes the panel, which is the
    /// point of knowing a tower is open in the first place. Declared last, so
    /// it is the panel's trailing closure.
    let onSelectAirport: (Airport) -> Void

    var body: some View {
        MapPanel(title: "ATC", subtitle: subtitle) {
            if feed.atcStations.isEmpty {
                PanelSection(title: "ON FREQUENCY") {
                    PanelEmptyState(
                        symbol: "antenna.radiowaves.left.and.right.slash",
                        title: feed.status.isLive ? "Nobody is controlling" : "Waiting for the feed",
                        detail: feed.status.isLive
                            ? "No positions are open on \(feed.server) right now."
                            : "Controllers appear as soon as the server is reporting."
                    )
                }
            } else {
                if !airfields.isEmpty {
                    PanelSection(title: "AIRPORTS") {
                        ForEach(airfields) { station in
                            if station.id != airfields.first?.id { PanelDivider() }
                            stationRow(station)
                        }
                    }
                }

                // Centres work an airspace, and their identifier is an FIR
                // rather than an ICAO — nowhere to fly the map to, so they are
                // listed apart from the fields instead of pretending to be one.
                if !centers.isEmpty {
                    PanelSection(title: "CENTRE") {
                        ForEach(centers) { station in
                            if station.id != centers.first?.id { PanelDivider() }
                            centerRow(station)
                        }
                    }
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private var subtitle: String {
        guard feed.atcCount > 0 else { return feed.server }
        let positions = feed.atcCount == 1 ? "1 position" : "\(feed.atcCount) positions"
        return "\(positions) open · \(feed.server)"
    }

    private var airfields: [AtcStation] {
        feed.atcStations.filter { !$0.isCenter }
    }

    private var centers: [AtcStation] {
        feed.atcStations.filter { $0.isCenter }
    }

    // MARK: - Rows

    private func stationRow(_ station: AtcStation) -> some View {
        Button {
            guard let airport = station.airport else { return }
            onSelectAirport(airport)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(station.identifier)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize()

                    if let airport = station.airport {
                        if !airport.flag.isEmpty {
                            Text(airport.flag).font(.system(size: 11))
                        }

                        Text(airport.name.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(theme.textDim)
                            .flightInfoLine(minimumScale: 0.7)
                    }

                    Spacer(minLength: 4)

                    if station.airport != nil {
                        Image(systemName: "location.magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textDim)
                    }
                }

                ForEach(station.facilities) { facility in
                    PanelFacilityLine(facility: facility, now: now)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing to fly to for a field the dataset doesn't have.
        .disabled(station.airport == nil)
    }

    private func centerRow(_ station: AtcStation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(station.identifier)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            ForEach(station.facilities) { facility in
                PanelFacilityLine(facility: facility, now: now)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
