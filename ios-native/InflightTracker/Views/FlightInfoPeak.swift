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
    let contributor: String?
    let registration: String
    let theme: FlightInfoTheme
    let style: FlightInfoPeakStyle
    let width: CGFloat

    /// Width of the photo. Its height follows the photo's own aspect ratio, so
    /// a square shot and a wide airliner shot both sit in the row properly
    /// instead of being cropped to one fixed box.
    ///
    /// The clamp is deliberately narrow: the sheet is only as tall as this row
    /// plus the card, so a very tall crop would buy empty space beside the
    /// text rather than a better photo.
    private let thumbnailWidth: CGFloat = 148

    private var thumbnailHeight: CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return 88
        }
        let ratio = image.size.height / image.size.width
        return min(max(thumbnailWidth * ratio, 76), 96)
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .strip:
            strip

        case .compact:
            VStack(alignment: .leading, spacing: 12) {
                identityRow
                situationCard
            }
            // Clears the drag indicator, which floats over the top of the sheet.
            .padding(.top, 18)
            .padding(.horizontal, 16)
            // Small: the sheet adds `peakBottomGap` under this, and the two
            // together are the whole distance from the card to the bottom of
            // the window. Anything more here is space with nothing in it.
            .padding(.bottom, 4)

        case .rich:
            rich
        }
    }

    /// The full window's header, stopping after the route.
    ///
    /// Everything here is the same component at the same size the full window
    /// uses, so dragging up grows the window around what is already on screen
    /// rather than swapping it for a different layout.
    private var rich: some View {
        VStack(spacing: 0) {
            FlightHero(
                image: image,
                spriteKey: flight.spriteKey,
                contributor: contributor,
                theme: theme,
                width: width
            )

            VStack(spacing: 12) {
                FlightIdentityBlock(flight: flight, registration: registration, theme: theme)
                situationCard
            }
            .padding(.horizontal, 14)
            .padding(.top, -FlightInfoLayout.heroSeamLift)
            // As with the compact bar: the sheet's own gap finishes this off,
            // so the card sits close to the bottom edge instead of above a
            // band of empty window.
            .padding(.bottom, 4)
        }
    }

    // MARK: - Strip

    /// The photograph's box, and how far of it stands above the band.
    ///
    /// The lift is the whole idea of this style. The band is a boarding pass
    /// and the aeroplane is the thing the pass is about, so the photograph is
    /// raised out of it into the sheet's own glass — which, at the peak detent,
    /// is the map. Boxed inside the band it would read as a thumbnail in a
    /// list, which is what the compact bar already is.
    private var stripPhotoWidth: CGFloat { 104 }
    private var stripPhotoHeight: CGFloat { 66 }
    private var stripLift: CGFloat { 24 }

    /// How much of the photograph is over the band rather than above it. The
    /// head row is held to at least this, so the band is never shorter than
    /// the part of the picture sitting in it.
    private var stripPhotoOverlap: CGFloat { stripPhotoHeight - stripLift }

    private var stripIcaoSize: CGFloat { 24 }

    private var strip: some View {
        // Resolved once and handed down. `FlightSituation.from` searches the
        // airport store for a nearest field on two of its three branches, and
        // the two halves of this layout both want the answer.
        let situation = FlightSituation.from(flight)

        return VStack(spacing: 0) {
            // Deliberately empty: this is the gap the photograph rises into,
            // and what shows through it is the sheet's glass over the map.
            Color.clear.frame(height: stripLift)

            VStack(spacing: 9) {
                stripHeadRow(situation)
                stripFootRow(situation)
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .flightInfoSurface(theme, radius: theme.radiusMedium, elevated: true)
        }
        // Attached before the outer padding, so topLeading is this stack's own
        // corner rather than the screen's.
        .overlay(alignment: .topLeading) { stripPhoto }
        .padding(.horizontal, 12)
        // Matches the compact bar: clears the drag indicator, which floats over
        // the top of the sheet in a band of its own.
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var stripPhoto: some View {
        AircraftPhotoImage(
            image: image,
            spriteKey: flight.spriteKey,
            theme: theme,
            iconSize: 30,
            contentMode: .fit
        )
        .frame(width: stripPhotoWidth, height: stripPhotoHeight)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                .strokeBorder(theme.strokeStrong, lineWidth: 1)
        }
        // The shadow is what sells the lift: without it the photograph reads as
        // a hole cut in the band rather than a card sitting proud of it.
        .shadow(color: .black.opacity(0.34), radius: 9, x: 0, y: 4)
        .padding(.leading, 13)
    }

    /// Identity beside the photograph, route on the right.
    ///
    /// Bottom-aligned rather than laid out under the picture, which is where a
    /// paper boarding pass would put it. On a phone that costs the height of
    /// the whole photograph again, and height is the one thing this style is
    /// spending as little of as it can — beside it, the row is only as tall as
    /// the part of the picture that is in the band at all.
    private func stripHeadRow(_ situation: FlightSituation) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                stripField("Flight num:", flight.displayName)
                stripField("Tail num:", registration.isEmpty ? "—" : registration)
            }
            // Clears the photograph, which is drawn over this row's left edge.
            .padding(.leading, stripPhotoWidth + 4)
            .frame(minHeight: stripPhotoOverlap, alignment: .bottom)

            Spacer(minLength: 6)

            stripDestination(situation)
        }
    }

    private func stripField(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .fixedSize()

            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
    }

    /// Where it is going — or, with nothing filed, where it is.
    @ViewBuilder
    private func stripDestination(_ situation: FlightSituation) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let route = stripRoute {
                HStack(spacing: 7) {
                    Text(route.from)
                    Image(systemName: "arrow.right")
                        .font(.system(size: stripIcaoSize * 0.46, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                    Text(route.to)
                }
                .font(.system(size: stripIcaoSize, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)

                // The pair of silhouettes under the codes, which is what makes
                // the row read as a departure and an arrival rather than as two
                // airports that happen to be next to each other.
                HStack(spacing: 24) {
                    Image(systemName: "airplane.departure")
                    Image(systemName: "airplane.arrival")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textDim)
            } else {
                let place = stripPlace(situation)

                Text(place.kicker)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)

                Text(place.code)
                    .font(.system(size: stripIcaoSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
            }
        }
    }

    /// How far through, when there is a route to be through.
    ///
    /// The pair reads as "207 of 516": what this flight has covered, then the
    /// whole trip. Remaining is the third number and it is the one you can do
    /// in your head, so it stays in the full window rather than crowding this.
    @ViewBuilder
    private func stripFootRow(_ situation: FlightSituation) -> some View {
        if case .enroute(let filed) = situation, let progress = filed {
            HStack(spacing: 9) {
                stripDistance(progress.flownNM)
                RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 10)
                stripDistance(progress.totalNM)
            }
        } else {
            Text(stripAircraftLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stripDistance(_ value: Double) -> some View {
        Text("\(Format.number(value)) nm")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .fixedSize()
    }

    private var stripRoute: (from: String, to: String)? {
        let arrival = (flight.arrivalIcao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !arrival.isEmpty else { return nil }

        let departure = (flight.departureIcao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (departure.isEmpty ? "———" : departure, arrival)
    }

    private func stripPlace(_ situation: FlightSituation) -> (kicker: String, code: String) {
        switch situation {
        case .enroute:
            // Unreachable in practice: `stripRoute` is non-nil for exactly the
            // flights this case covers, and the caller has already taken the
            // other branch. Answered anyway rather than crashed on.
            return ("DESTINATION", flight.arrivalIcao ?? "———")

        case .grounded(let airport, let isTaxiing):
            return (isTaxiing ? "TAXIING AT" : "PARKED AT", airport?.icao ?? "———")

        case .unplanned(_, let nearest):
            return (nearest == nil ? "IN THE AIR" : "PASSING", nearest?.icao ?? "———")
        }
    }

    private var stripAircraftLine: String {
        let parts = [flight.aircraftName, flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown aircraft" : parts.joined(separator: " · ")
    }

    // MARK: - Identity

    private var identityRow: some View {
        // Centred, not top-aligned: the text block is shorter than the photo,
        // and pinning it to the top left an obvious hole under it.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(flight.displayName)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme)
                }

                HStack(spacing: 5) {
                    // Not tappable here: the bar's own tap expands the window,
                    // and two things on one tap is one too many.
                    FlightPilotBadge(username: flight.username, side: 18, isTappable: false)

                    // Only when it says something. The bar is a photo wide and
                    // a name long; ACTIVE is the ordinary case and doesn't earn
                    // the space here the way AWAY or AP+ does.
                    if flight.pilotState.isNoteworthy {
                        PilotStateChip(state: flight.pilotState, theme: theme)
                    }
                }

                // The aircraft and its livery live at the foot of the route
                // card now, which is where the empty space was.
                Text(registration.isEmpty ? " " : registration)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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

    // MARK: - Route / where it is

    /// The photo peak shares the full window's card metrics so the two dissolve
    /// into each other without anything shifting; the compact bar runs a little
    /// tighter.
    private var icaoSize: CGFloat { style == .rich ? 24 : 22 }
    private var cardInset: CGFloat { style == .rich ? 14 : 13 }


    /// Same rule as the full window: a filed destination gets the route strip,
    /// otherwise the card says where the aircraft is sitting.
    @ViewBuilder
    private var situationCard: some View {
        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            RouteCard(flight: flight, progress: progress, theme: theme, icaoSize: icaoSize, inset: cardInset)

        case .grounded(let airport, let isTaxiing):
            PlaceCard(
                kicker: isTaxiing ? "TAXIING AT" : "PARKED AT",
                symbol: isTaxiing ? "airplane" : "parkingsign",
                airport: airport,
                theme: theme,
                icaoSize: icaoSize
            )
            .padding(cardInset)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

        case .unplanned(let departure, let nearest):
            VStack(spacing: 11) {
                PlaceCard(
                    kicker: nearest == nil ? "IN THE AIR" : "PASSING",
                    symbol: "airplane",
                    airport: nearest,
                    theme: theme,
                    icaoSize: icaoSize
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
            .padding(cardInset)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }
}
