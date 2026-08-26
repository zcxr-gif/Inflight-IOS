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

        case .board:
            board
                .padding(.top, 18)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Board

    /// How far the photograph lies over the top edge of the route card.
    ///
    /// The one measurement this layout is actually about. Too little and it
    /// reads as a photo that happens to be near a card; too much and the card
    /// looks like it is sliding out from under it.
    private let boardPhotoOverlap: CGFloat = 22

    private var boardPhotoWidth: CGFloat { 118 }

    /// The photograph's leading inset, measured from the card's own edge.
    private let boardPhotoInset: CGFloat = 12

    /// The card's content inset.
    private let boardCardInset: CGFloat = 14

    /// The gap after the photograph, on both of the rows that sit beside it.
    private let boardPhotoGap: CGFloat = 16

    /// How much of the card's first row the photograph is lying across.
    ///
    /// Derived from the numbers above rather than measured off a screenshot,
    /// and that is what makes the column line up: the flight number in the
    /// header and the departure ICAO in the card are laid out by two different
    /// containers with two different insets, so the only way their left edges
    /// agree — and go on agreeing when the photo changes size — is for both to
    /// be computed from the same three figures.
    private var boardPhotoLane: CGFloat {
        boardPhotoInset + boardPhotoWidth + boardPhotoGap - boardCardInset
    }

    /// The photo's own shape, within bounds the peak can carry.
    private var boardPhotoHeight: CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return 84
        }
        let ratio = image.size.height / image.size.width
        return min(max(boardPhotoWidth * ratio, 74), 94)
    }

    /// The board.
    ///
    /// One container, and it holds the route — nothing else. The window is
    /// already a pane of glass laid over the map, so a surface behind the whole
    /// peak was a card drawn on a card: two edges, two corner radii and two
    /// shadows for one object, which is what made it look boxed in rather than
    /// laid out. The photograph and the aeroplane's identity sit straight on the
    /// glass now, the way the compact peak's identity row always has, and the
    /// only thing with a border round it is the part that earns one — where the
    /// flight is going and how far it has got, which is a readout rather than a
    /// caption.
    ///
    /// The overhang survives, and is better for it: standing proud of a whole
    /// strip the photograph was breaking a box that had nothing to do with it,
    /// where resting on the route card it is one object lying on another.
    ///
    /// The negative spacing is what does that, and it is deliberately not an
    /// offset or a computed position. Pulling the card up into the header means
    /// the overlap is measured from whatever the header actually turns out to
    /// be — a taller photograph, a longer registration, a larger accessibility
    /// font — rather than from a number written here that any of those would
    /// make wrong. `zIndex` is the other half: without it the card is the later
    /// sibling and draws over the picture it is supposed to lie under.
    private var board: some View {
        VStack(alignment: .leading, spacing: -boardPhotoOverlap) {
            boardHeader
                .zIndex(1)

            boardCard
        }
    }

    /// The photograph, and which flight it is — bare on the window's glass.
    ///
    /// The two fields run side by side rather than stacked, and that is
    /// structural rather than stylistic. Stacked, the column is about sixty
    /// points tall and the card's top edge crosses the header well above that,
    /// so the registration would sit over the card's border on exactly the
    /// aircraft whose photograph is shortest. One row is a single field high and
    /// clears it whatever the picture does.
    private var boardHeader: some View {
        HStack(alignment: .top, spacing: boardPhotoGap) {
            AircraftPhotoImage(
                image: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 34,
                contentMode: .fit
            )
            .frame(width: boardPhotoWidth, height: boardPhotoHeight)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .strokeBorder(theme.strokeStrong, lineWidth: 1)
            }
            // Lifts it off the card rather than decorating it. Without this the
            // photograph and the surface it lies on read as one flat plane and
            // the overlap stops meaning anything.
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)

            HStack(alignment: .top, spacing: 18) {
                boardField("FLIGHT", flight.displayName)
                boardField("TAIL", registration.isEmpty ? "—" : registration)
            }
            // Nudged onto the photograph's own top edge: the label is small and
            // its cap height sits well below the line box, so aligning the
            // boxes leaves the text looking dropped.
            .padding(.top, 3)

            Spacer(minLength: 0)
        }
        // Inset from the card's corner, so the photograph reads as lying on it
        // rather than as being pinned to it.
        .padding(.leading, boardPhotoInset)
        .padding(.trailing, boardCardInset)
    }

    /// One labelled figure — the flight number, the registration.
    private func boardField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(theme.textDim)

            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
        }
    }

    /// Where it is going and how far it has got — the one container.
    ///
    /// The route runs beside the photograph rather than under it. Set below, the
    /// card carries a band of nothing across its whole top edge with a picture
    /// resting on one corner of it, which is a lot of empty card to buy one
    /// alignment. Beside it, the corner the photo covers is the only part of
    /// that row it was ever going to occupy.
    private var boardCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                // The lane the photograph is lying in. Held open rather than
                // left to a leading padding, so the route is a sibling of the
                // space the picture takes rather than an inset that has to be
                // kept in step with it by hand.
                Color.clear
                    .frame(width: boardPhotoLane, height: 0)

                boardRoute

                Spacer(minLength: 0)
            }

            boardProgress

            Text(boardAircraftLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, boardCardInset)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    /// The airframe, and its colours where the feed names them.
    private var boardAircraftLine: String {
        let type = flight.aircraftName.trimmingCharacters(in: .whitespaces)
        let livery = flight.liveryName.trimmingCharacters(in: .whitespaces)

        if type.isEmpty { return livery.isEmpty ? "Unknown aircraft" : livery }
        // A livery that merely repeats the type says nothing twice.
        if livery.isEmpty || livery.caseInsensitiveCompare(type) == .orderedSame { return type }
        return "\(type) · \(livery)"
    }

    /// Where it is going, at the size the strip is for.
    private var boardRoute: some View {
        HStack(spacing: 9) {
            boardPort(flight.departureIcao)

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textDim)

            boardPort(flight.arrivalIcao)
        }
    }

    private func boardPort(_ icao: String?) -> some View {
        VStack(spacing: 2) {
            Text(icao?.uppercased() ?? "————")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(icao == nil ? theme.textDim : theme.textPrimary)
                // Two four-letter ICAOs at this size are wider than the strip
                // on the smallest phone. They shrink rather than being cut in
                // half by the window's clip, which is the one outcome that
                // would make the route unreadable.
                .flightInfoLine(minimumScale: 0.55)

            Image(systemName: "airplane")
                .font(.system(size: 9))
                .foregroundStyle(theme.textDim)
        }
    }

    /// How far it has got, when there is a route to measure it against.
    ///
    /// A parked aircraft and one with no filed destination both land here with
    /// nothing to draw, and draw nothing — the strip simply ends after the
    /// route. Padding out an empty bar would be inventing a journey.
    @ViewBuilder
    private var boardProgress: some View {
        if let progress = FlightProgress(flight: flight) {
            VStack(spacing: 6) {
                RouteTrack(fraction: progress.fraction, theme: theme)

                HStack(spacing: 8) {
                    Text("\(Format.number(progress.flownNM)) NM")
                        .foregroundStyle(theme.textSecondary)

                    Spacer(minLength: 8)

                    Text("\(Format.number(progress.totalNM)) NM")
                        .foregroundStyle(theme.textDim)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
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
