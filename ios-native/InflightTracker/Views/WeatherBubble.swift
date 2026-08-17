import CoreLocation
import SwiftUI

/// The weather bubble's face: what conditions are, and how warm it is, in the
/// width of one rail button.
///
/// This used to be a pill across the top left, which put it in the search
/// field's lane and meant it could only be shown while the search field was
/// out of the way. As a bubble it lives in the rail on the right with the
/// filters and the map's own look, and opens into the card below.
struct WeatherBubbleFace: View {

    let station: WeatherModel.Station
    let theme: FlightInfoTheme

    @ObservedObject private var preferences = WeatherPreferences.shared

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: station.metar?.symbol(isDaylight: station.isDaylight)
                  ?? (station.isDaylight ? "sun.max.fill" : "moon.stars.fill"))
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)

            Text(station.metar?.temperatureLabel(in: preferences.temperatureUnit) ?? "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .frame(width: 44, height: 46)
        .contentShape(Rectangle())
    }
}

/// What the weather bubble opens into: the field being reported on, and — for
/// an open flight — both ends of its route, each marked day or night.
///
/// Anchored under the rail rather than beside it, so a long airport name grows
/// downwards into the map instead of pushing the rail off the screen.
struct WeatherStationList: View {

    let stations: [WeatherModel.Station]
    let theme: FlightInfoTheme

    @ObservedObject private var preferences = WeatherPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(stations) { station in
                if station.id != stations.first?.id {
                    Rectangle()
                        .fill(theme.stroke)
                        .frame(height: 1)
                }
                row(for: station)
            }
        }
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .frame(maxWidth: 268, alignment: .trailing)
        .environment(\.colorScheme, .dark)
    }

    private func row(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 10) {
            Image(systemName: station.metar?.symbol(isDaylight: station.isDaylight)
                  ?? (station.isDaylight ? "sun.max.fill" : "moon.stars.fill"))
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.role.label)
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(theme.textDim)

                    Text(station.airport.icao)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    // The one thing on the card that colour carries, and the
                    // reason it does: four categories that all read the same
                    // in monochrome.
                    if let category = station.metar?.flightCategory {
                        FlightCategoryBadge(category: category)
                    }

                    dayNight(for: station)
                }

                Text(detail(for: station))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(station.metar?.temperatureLabel(in: preferences.temperatureUnit) ?? "—")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func dayNight(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 3) {
            Image(systemName: station.isDaylight ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 7))
            Text(station.isDaylight ? "DAY" : "NIGHT")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            Capsule().fill(theme.elevatedFill)
        }
        .fixedSize()
    }

    private func detail(for station: WeatherModel.Station) -> String {
        guard let metar = station.metar else { return station.airport.name }
        return "\(metar.conditionLabel) · \(metar.windLabel(in: preferences.windUnit))"
    }
}
