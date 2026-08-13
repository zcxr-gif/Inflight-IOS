import SwiftUI

/// The peak state — the compact bar the info window opens in.
///
/// Everything a tap on the map is asking for: who it is, what they're flying,
/// and how far along the route they are. Dragging the sheet up cross-fades this
/// into the full window.
struct FlightInfoPeak: View {

    let flight: Flight
    let photo: AircraftPhoto?
    let theme: FlightInfoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            routeCard
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
                photo: photo,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 30
            )
            .frame(width: 104, height: 66)
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

    // MARK: - Route

    private var routeCard: some View {
        let progress = FlightProgress(flight: flight)

        return VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                port(icao: flight.departureIcao, alignment: .leading)

                RouteTrack(fraction: progress?.fraction ?? 0, theme: theme)
                    // A fixed middle: the ports take what is left, so a long
                    // airport name can only shrink, never widen the card.
                    .frame(width: 84)
                    .padding(.top, 8)

                port(icao: flight.arrivalIcao, alignment: .trailing)
            }

            if let progress = progress {
                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

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
    }

    private func port(icao: String?, alignment: HorizontalAlignment) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let airport = AirportStore.shared.airport(icao)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        return VStack(alignment: alignment, spacing: 4) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)

            Text((airport?.name ?? "Unknown").uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private func eteLabel(_ progress: FlightProgress) -> String {
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—"
        }
        return Format.duration(ete)
    }
}
