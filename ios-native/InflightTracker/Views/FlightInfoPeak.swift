import SwiftUI
import UIKit

/// The peak state — the compact bar the info window opens in.
///
/// Everything a tap on the map is asking for: who it is, what they're flying,
/// and where it is going. Dragging the sheet up cross-fades this into the full
/// window.
struct FlightInfoPeak: View {

    let flight: Flight
    let image: UIImage?
    let theme: FlightInfoTheme

    /// Width of the photo. Its height follows the photo's own aspect ratio, so
    /// a square shot and a wide airliner shot both sit in the row properly
    /// instead of being cropped to one fixed box.
    private let thumbnailWidth: CGFloat = 148

    private var thumbnailHeight: CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return 92
        }
        let ratio = image.size.height / image.size.width
        return min(max(thumbnailWidth * ratio, 78), 110)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            situationCard
        }
        // Clears the drag indicator, which floats over the top of the sheet.
        .padding(.top, 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Identity

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(flight.displayName)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme)
                }

                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textDim)

                    Text(flight.username ?? "Pilot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()
                }

                Text(aircraftLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AircraftPhotoImage(
                image: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 38,
                contentMode: .fit
            )
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .strokeBorder(theme.strokeStrong, lineWidth: 1)
            }
        }
    }

    private var aircraftLine: String {
        let parts = [flight.aircraftName, flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Tap for details" : parts.joined(separator: " · ")
    }

    // MARK: - Route / where it is

    /// Same rule as the full window: a filed destination gets the route strip,
    /// otherwise the card says where the aircraft is sitting.
    @ViewBuilder
    private var situationCard: some View {
        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            VStack(spacing: 11) {
                RouteStrip(
                    departureIcao: flight.departureIcao,
                    arrivalIcao: flight.arrivalIcao,
                    fraction: progress?.fraction ?? 0,
                    theme: theme,
                    icaoSize: 22,
                    trackWidth: 84
                )

                if let progress = progress {
                    hairline

                    HStack(spacing: 8) {
                        MiniStat(
                            label: "FLOWN",
                            value: "\(Format.number(progress.flownNM)) NM",
                            theme: theme
                        )
                        MiniStat(
                            label: "REMAINING",
                            value: "\(Format.number(progress.remainingNM)) NM",
                            theme: theme,
                            alignment: .center
                        )
                        MiniStat(
                            label: "ETE",
                            value: eteLabel(progress),
                            theme: theme,
                            alignment: .trailing
                        )
                    }
                }
            }
            .padding(13)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

        case .grounded(let airport, let isTaxiing):
            PlaceCard(
                kicker: isTaxiing ? "TAXIING AT" : "PARKED AT",
                symbol: isTaxiing ? "airplane" : "parkingsign",
                airport: airport,
                theme: theme
            )
            .padding(13)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

        case .unplanned(let departure, let nearest):
            VStack(spacing: 11) {
                PlaceCard(
                    kicker: nearest == nil ? "IN THE AIR" : "PASSING",
                    symbol: "airplane",
                    airport: nearest,
                    theme: theme
                )

                if departure != nil {
                    hairline

                    HStack(spacing: 8) {
                        MiniStat(label: "DEPARTED", value: departure?.icao ?? "—", theme: theme)
                        MiniStat(
                            label: "DESTINATION",
                            value: "NOT FILED",
                            theme: theme,
                            alignment: .trailing
                        )
                    }
                }
            }
            .padding(13)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }

    private func eteLabel(_ progress: FlightProgress) -> String {
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—"
        }
        return Format.duration(ete)
    }
}
