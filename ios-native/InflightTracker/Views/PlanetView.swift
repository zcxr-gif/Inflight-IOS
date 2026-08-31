import CoreLocation
import SwiftUI

/// The whole world at once, drawn rather than photographed.
///
/// The map has always been able to show a globe — `MapProjection.globe` — and
/// it has always been MapKit's globe: imagery over real elevation, which is a
/// photograph of the planet. A photograph is the wrong picture for a traffic
/// map. Cloud, coastline, city light and desert all compete with the sprites
/// for exactly the attention the sprites want, and no palette fixes it because
/// the detail is in the imagery.
///
/// So this one is a drawing: a disc, every country as a hairline or a filled
/// shape, a graticule you have to look for, and nothing written on it but the
/// codes of the fields worth knowing about. Which colours all of that comes in
/// is a setting — see `GlobeSkin`.
///
/// ## What this screen is now
///
/// It used to be the only way to see the planet, and it was a screen of its own
/// on purpose: `TrackerMapView` is three thousand lines of MapKit — weather
/// tiles, the terminator, NAT tracks, gate layouts, measuring, replay — and
/// none of it is reachable from a renderer that is not MapKit, so offering the
/// drawn globe as a projection would have meant silently turning a dozen
/// features off when somebody picked it.
///
/// That is no longer the trade. The planet is a `MapProjection` now, and it is
/// the map's own layer rather than a screen instead of the map — so the search
/// field, the filters, the dock, the toolbar, the panels and the flight window
/// all stand over it and all go on working. See `PlanetSurface`, which is the
/// planet itself and is what both this screen and the map draw.
///
/// This screen stays for what it has always been good at: the whole world, full
/// bleed, with nothing on it but a close button — reachable from the corner of
/// a flat map without having to change what your map *is*.
struct PlanetView: View {

    @EnvironmentObject private var feed: LiveFeed
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared

    /// Fields worth marking, worked out by the map and handed in rather than
    /// recomputed: ranking them walks the whole server twice, and the map has
    /// already done it for this packet.
    let airports: [MapAirport]

    /// Opening one of them, and opening an aircraft. Both hand back to the map,
    /// which owns every window in this app.
    let onSelectAirport: (Airport) -> Void
    let onSelectFlight: (Flight) -> Void

    /// Where the planet starts. The map's own centre, so opening this is a
    /// change of projection rather than a change of subject.
    let start: CLLocationCoordinate2D

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        ZStack {
            PlanetSurface(
                flights: visible,
                airports: filters.showsAirports ? airports : [],
                signature: signature,
                start: start,
                onSelectFlight: { flight in
                    onSelectFlight(flight)
                    dismiss()
                },
                onSelectAirport: { field in
                    onSelectAirport(field)
                    dismiss()
                }
            )
            .ignoresSafeArea()

            chrome
        }
        .background(theme.windowFill)
        .environment(\.colorScheme, theme.colorScheme)
        .statusBarHidden()
    }

    /// The packet as the filters leave it. Read twice a redraw — the planet and
    /// the count — so it is worked out once.
    private var visible: [Flight] {
        filters.apply(to: feed.flights)
    }

    /// What the planet is drawn from, as one number. The scene under it is
    /// rebuilt when this moves and at no other time.
    private var signature: Int {
        var hasher = Hasher()
        hasher.combine(feed.lastUpdate)
        hasher.combine(filters.signature)
        hasher.combine(airports.count)
        return hasher.finalize()
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("THE PLANET")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(theme.textDim)

                    Text(feed.server)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 12)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 34, height: 34)
                        .flightInfoSurface(theme, in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the planet")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer(minLength: 0)

            HintStrip(placement: .map)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
        }
    }

    private var subtitle: String {
        let aircraft = visible.count
        let fields = airports.count
        return "\(Format.number(Double(aircraft))) aircraft · \(fields) field\(fields == 1 ? "" : "s")"
    }
}
