import SwiftUI

/// The peak state — the compact bar the info window opens in, modelled on the
/// Capacitor build's collapsed flight info bar.
///
/// Everything a tap on the map is asking for is here: who it is, what they're
/// flying, and how far along the route they are. Dragging the sheet up
/// cross-fades this into the full window.
struct FlightInfoPeak: View {

    let flight: Flight
    let photo: AircraftPhoto?
    let theme: FlightInfoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            identityRow
            routeCard
        }
        // Clears the drag indicator, which floats over the top of the sheet.
        .padding(.top, 22)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Identity

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(flight.displayName)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, compact: true)
                }

                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textDim)

                    Text(flight.username ?? "Pilot")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine()
                }

                HStack(spacing: 7) {
                    if !flight.aircraftName.isEmpty {
                        Text(flight.aircraftName)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .flightInfoSurface(theme, radius: 6)
                            .flightInfoLine()
                            .layoutPriority(1)
                    }

                    Text(flight.liveryName.isEmpty ? "Tap for details" : flight.liveryName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AircraftPhotoImage(
                photo: photo,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 34
            )
            .frame(width: 118, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(theme.strokeStrong, lineWidth: 1)
            }
        }
    }

    // MARK: - Route

    private var routeCard: some View {
        let progress = FlightProgress(flight: flight)

        return VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                port(icao: flight.departureIcao, alignment: .leading)

                RouteTrack(fraction: progress?.fraction ?? 0, theme: theme, planeSize: 11)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                port(icao: flight.arrivalIcao, alignment: .trailing)
            }

            Divider()
                .overlay(theme.stroke)

            HStack(spacing: 10) {
                Text(flownLabel(progress))
                Spacer(minLength: 8)
                Text(remainingLabel(progress))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .flightInfoLine(minimumScale: 0.8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func port(icao: String?, alignment: HorizontalAlignment) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let airport = AirportStore.shared.airport(icao)

        return VStack(alignment: alignment, spacing: 5) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .tracking(-1)
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Unknown").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)
        }
        // A hard share of the row: the ICAOs are the only fixed-size text here,
        // so without this a long airport name would stretch the card.
        .frame(width: 96, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func flownLabel(_ progress: FlightProgress?) -> String {
        guard let progress = progress else { return "Route unavailable" }
        return "\(Format.number(progress.flownNM)) NM flown"
    }

    private func remainingLabel(_ progress: FlightProgress?) -> String {
        guard let progress = progress else {
            return "\(Format.number(flight.groundSpeedKnots)) kts"
        }

        let distance = "\(Format.number(progress.remainingNM)) NM"
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return distance
        }
        return "\(distance) · ETE \(Format.duration(ete))"
    }
}
