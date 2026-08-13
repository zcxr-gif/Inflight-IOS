import CoreLocation
import SwiftUI

/// Weather where the map is looking, top left.
///
/// Collapsed it is the field being passed over: conditions, temperature, ICAO
/// and wind. Tapped, it opens out to add both ends of whatever route is open,
/// each marked day or night, so a long-haul's destination weather is one tap
/// away from the map.
struct WeatherChip: View {

    @ObservedObject var model: WeatherModel
    let theme: FlightInfoTheme

    @Binding var isExpanded: Bool

    private var stations: [WeatherModel.Station] {
        [model.nearby, model.departure, model.arrival].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nearby = model.nearby {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        isExpanded.toggle()
                    }
                } label: {
                    summary(for: nearby)
                }
                .buttonStyle(.plain)
            }

            if isExpanded, !stations.isEmpty {
                expanded
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Collapsed

    private func summary(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 9) {
            Image(systemName: station.metar?.symbol(isDaylight: station.isDaylight)
                  ?? (station.isDaylight ? "sun.max.fill" : "moon.stars.fill"))
                .font(.system(size: 17))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 22)

            Text(station.metar?.temperatureLabel ?? "—")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()

            VStack(alignment: .leading, spacing: 1) {
                Text(station.airport.icao)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)

                Text(station.metar?.windLabel ?? station.airport.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }
            .frame(maxWidth: 118, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { chipBackground(cornerRadius: 22) }
        .contentShape(Capsule())
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                if index > 0 {
                    Rectangle()
                        .fill(theme.stroke)
                        .frame(height: 1)
                }
                row(for: station)
            }
        }
        .background { chipBackground(cornerRadius: theme.radiusMedium) }
        .frame(maxWidth: 268, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
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

                    dayNight(for: station)
                }

                Text(detail(for: station))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(station.metar?.temperatureLabel ?? "—")
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
        return "\(metar.conditionLabel) · \(metar.windLabel)"
    }

    // MARK: - Chrome

    private func chipBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return shape
            .fill(.ultraThinMaterial)
            .overlay { shape.fill(Color.black.opacity(0.16)) }
            .overlay { shape.strokeBorder(theme.stroke, lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
