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

    /// The VA to name under the route card, when the flight has one.
    /// Resolved by the window and handed down — see `VaPartnerLine`.
    var partner: VaPartner? = nil

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
        case .compact:
            VStack(alignment: .leading, spacing: 12) {
                identityRow
                situationCard
                // Under the bottom edge of the card, in the band of sheet
                // between it and the foot of the window — which is where the
                // bar had nothing at all.
                VaPartnerLine(partner: partner, theme: theme)
            }
            // Clears the drag indicator, which floats over the top of the sheet.
            .padding(.top, 18)
            .padding(.horizontal, 16)
            // Small: the sheet adds `peakBottomGap` under this, and the two
            // together are the whole distance from the last line to the bottom
            // of the window. Anything more here is space with nothing in it.
            .padding(.bottom, 2)

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
                VaPartnerLine(partner: partner, theme: theme)
            }
            .padding(.horizontal, 14)
            .padding(.top, -FlightInfoLayout.heroSeamLift)
            // As with the compact bar: the sheet's own gap finishes this off,
            // so the last line sits close to the bottom edge instead of above a
            // band of empty window.
            .padding(.bottom, 2)
        }
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
