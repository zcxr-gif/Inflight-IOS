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

    /// Every photograph the lookup found of this type in this livery.
    ///
    /// The peak used to be handed none of them on purpose, on the grounds that
    /// a horizontal swipe on a sheet you are dragging is a gesture fighting the
    /// window. It is not — the page style is a scroll view underneath, and a
    /// scroll view that only scrolls sideways hands every vertical drag
    /// straight to the sheet. What the old rule actually cost was the gallery
    /// itself: the peak is the state the window spends nearly all its time in,
    /// so a set of photographs only the fully open window would show is a set
    /// of photographs almost nobody ever saw.
    var photos: [AircraftPhoto] = []

    /// Whether the peak is the half of the window on screen. See
    /// `FlightHero.isAutoplaying` — both halves are mounted at once.
    var isAutoplaying: Bool = true

    /// The tallest the photo peak's header may be drawn, worked out by the
    /// window against the display it is on. See
    /// `FlightInfoLayout.peakHeroCeiling(inScreenHeight:)`: the peak does not
    /// scroll, so on a short screen the photograph is what gives up its room
    /// rather than the route card underneath it.
    var heroCeiling: CGFloat = FlightInfoLayout.peakHeroCap

    /// The VA to name under the route card, when the flight has one.
    /// Resolved by the window and handed down — see `VaPartnerLine`.
    var partner: VaPartner? = nil

    /// When the flight was first seen moving. Resolved by the window from the
    /// backend's history, like the board's, and used only by the detail look —
    /// the other two peeks have nowhere to put a departure time.
    var began: Date? = nil

    /// Width of the photo. Its height follows the photo's own aspect ratio, so
    /// a square shot and a wide airliner shot both sit in the row properly
    /// instead of being cropped to one fixed box.
    ///
    /// The clamp is deliberately narrow: the sheet is only as tall as this row
    /// plus the card, so a very tall crop would buy empty space beside the
    /// text rather than a better photo.
    private let thumbnailWidth: CGFloat = 148

    /// Which of the photographs the bar's thumbnail is showing. Its own state,
    /// not the header's: the two are never on screen at the same time.
    @State private var thumbnailPage = 0

    private var thumbnailHeight: CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return 88
        }
        let ratio = image.size.height / image.size.width
        return min(max(thumbnailWidth * ratio, 76), 96)
    }

    /// The peak lays out to exactly the height it wants, bottom gap included,
    /// and the sheet is sized to what this measures. Nothing here stretches to
    /// fill the window and nothing is pinned to its foot: there is no slack to
    /// put anywhere, because the window is as tall as this and no taller.
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
            // Clears the window's grabber, which floats over the top of the
            // sheet rather than taking a band of its own.
            .padding(.top, FlightInfoLayout.peakHandleClearance)
            .padding(.horizontal, 16)
            .padding(.bottom, FlightInfoLayout.peakBottomGap)

        case .detail:
            VStack(alignment: .leading, spacing: 12) {
                // One view rather than this file's rows: the detail peek is a
                // single face with its own internal divisions, and building it
                // out of the compact bar's pieces would mean every future
                // change to either having to be right for both.
                FlightDetailPeek(
                    flight: flight,
                    registration: registration,
                    theme: theme,
                    image: image,
                    photos: photos,
                    isAutoplaying: isAutoplaying,
                    began: began
                )

                VaPartnerLine(partner: partner, theme: theme)
            }
            .padding(.top, FlightInfoLayout.peakHandleClearance)
            .padding(.horizontal, 16)
            .padding(.bottom, FlightInfoLayout.peakBottomGap)

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
                width: width,
                photos: photos,
                isAutoplaying: isAutoplaying,
                // The one place the peak's header and the full window's differ,
                // and only for a photograph tall enough to need it. See
                // `heroCeiling`: the peak has no scroll view to put the
                // overflow in, so the picture yields before the route card
                // does.
                maxHeight: heroCeiling
            )

            VStack(spacing: 12) {
                FlightIdentityBlock(flight: flight, registration: registration, theme: theme)
                situationCard
                VaPartnerLine(partner: partner, theme: theme)
            }
            .padding(.horizontal, 14)
            .padding(.top, -FlightInfoLayout.heroSeamLift)
            .padding(.bottom, FlightInfoLayout.peakBottomGap)
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
                        // Tapping a second aeroplane changes this window
                        // rather than replacing it, so the callsign crosses
                        // into the new one instead of cutting to it.
                        .motionWords(flight.displayName)

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
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                    }
                }
                // A pilot walking away from their aeroplane puts a chip on this
                // row from nothing. Arriving is a movement like any other.
                .motion(Motion.control, value: flight.pilotState)

                // The aircraft and its livery live at the foot of the route
                // card now, which is where the empty space was.
                Text(registration.isEmpty ? " " : registration)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine()
                    // Blank until the photo lookup finds a tail number, which
                    // lands a second after the window opens.
                    .motionWords(registration)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            thumbnail
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .strokeBorder(theme.strokeStrong, lineWidth: 1)
                }
        }
    }

    /// The bar's photograph.
    ///
    /// The same carousel the photo peak's header runs, at a hundred and
    /// forty-eight points wide: it turns itself over on the same dwell, so the
    /// bar shows the whole set rather than the first shot for ever. No dots on
    /// something this size — the picture changing is the whole of what there
    /// is to say about it.
    @ViewBuilder
    private var thumbnail: some View {
        if photos.count > 1 {
            AircraftPhotoPager(
                photos: photos,
                preloaded: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 38,
                isAutoplaying: isAutoplaying,
                page: $thumbnailPage
            )
        } else {
            AircraftPhotoImage(
                image: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 38,
                contentMode: .fit
            )
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
