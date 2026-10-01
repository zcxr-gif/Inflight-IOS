import SwiftUI
import UIKit

/// The peek that is a flight card: the aircraft's photograph across the whole
/// window, fading into a dark deck that carries the route and the numbers.
///
/// ## What it was, and why it changed
///
/// This used to be the home-screen tile dropped into the window — a rounded
/// card with its own margins and shadow, floating on a sheet whose ground was
/// switched off. On iOS 26 the system draws the sheet's glass rim whatever the
/// background says, so what people saw was a tile on a tray: a card, a band of
/// empty sheet round it, and a second band under it. It also carried the tile's
/// habits into a place they made no sense — the distance to run printed twice,
/// eight lines apart, and the app's own wordmark in the corner of the app.
///
/// Now the window *is* the card. The photograph runs to every edge the sheet
/// has, so there is no margin for anything to be empty in, and the text sits
/// where the picture has been darkened for it rather than wherever the tile
/// happened to put it:
///
///   - the top carries who it is, over a short scrim;
///   - the middle is a band the aeroplane is framed in — the photograph is
///     scaled to the sheet's width, so the whole aircraft fits end to end, and
///     centred on that band, so nothing is written over it;
///   - the bottom is a deck, nearly opaque, carrying the route with both
///     airports named, how far along it is, and the glance strip.
///
/// ## What it still shares with the widget
///
/// The route line is `RouteStrip`, the same one the tile draws, and the
/// numbers come from the same `WidgetFlight` model for the progress — so the
/// tile on somebody's home screen and this peek still agree about where one
/// aeroplane is. The type and ink are the widget's too: white on a darkened
/// photograph whichever theme the app is in.
struct FlightWidgetPeek: View {

    let flight: Flight

    /// The photograph already in the window's hands. Nil draws `DrawnSky`, the
    /// same as an un-cached tile.
    let image: UIImage?

    let theme: FlightInfoTheme

    /// The VA to name at the foot of the deck, when the flight has one.
    var partner: VaPartner? = nil

    /// How far the backdrop runs past the bottom of what the peek measures.
    ///
    /// The peek sizes the sheet, so in a settled window these are the same
    /// height. They are not while the sheet is arriving or being dragged, and
    /// a photograph that stopped at the peek's own edge would show a strip of
    /// map under it for those frames. The sheet clips the excess.
    private static let backdropOverrun: CGFloat = 120

    var body: some View {
        // Resolved once. It walks the airport table and does the route's
        // great-circle arithmetic, which is not work to do five times because
        // five subviews each wanted a number out of it.
        let tile = WidgetFlight(flight: flight)
        let progress = FlightProgress(flight: flight)
        let glance = FlightGlance(flight: flight, progress: progress)

        VStack(alignment: .leading, spacing: 0) {
            header(tile)
                // Its own darkening, over the top of the photograph, so the
                // name reads on a bright sky without the scrim reaching down
                // over the aeroplane.
                .background(alignment: .top) { headerScrim }

            // The aeroplane's room. It draws the photograph itself — see
            // `photoWindow(altitudeFt:)` — and is drawn first, under the name
            // and the deck, so both lie over the picture's edges and neither
            // covers the aeroplane in the middle of it.
            photoWindow(altitudeFt: tile.altitudeFt)
                .zIndex(-1)

            deck(tile, progress: progress, glance: glance)
                .background(alignment: .top) { deckGround }
        }
        .padding(.top, FlightInfoLayout.peakHandleClearance + 4)
        .padding(.horizontal, Self.sideInset)
        .padding(.bottom, FlightInfoLayout.peakBottomGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Anything the photograph does not reach. It reaches nearly
        // everywhere; this is the colour of the edges it does not.
        .background(alignment: .top) {
            BackdropTokens.carbon
                .padding(.bottom, -Self.backdropOverrun)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(tile, glance: glance))
    }

    /// The margin the content keeps from the sheet's sides. The photograph
    /// and the two grounds run out past it to the edges.
    private static let sideInset: CGFloat = 18

    // MARK: - The photograph

    /// How tall the clear band between the name and the deck is.
    ///
    /// Sized to an aeroplane rather than to the card. A spotter's photograph
    /// of an airliner puts the aircraft across most of the frame's width and
    /// about a third of its height, so a picture scaled to the sheet's width —
    /// four hundred points or so, at three by two — carries an aeroplane
    /// close to a hundred points tall. This band is that, and the photograph
    /// is centred on it: the fuselage and the gear sit in the clear, the top
    /// of the fin runs up behind the name and the sky above it behind the
    /// grabber, and the tarmac fades into the deck.
    private static let photoBandHeight: CGFloat = 96

    /// The least height the photograph is drawn at, so a very wide panorama
    /// still reaches from the top of the sheet to the deck instead of leaving
    /// a strip of bare carbon above the name. Scaling up to it crops a little
    /// off either end; it does not crop anything top or bottom that the band
    /// shows.
    private static let minimumPhotoHeight: CGFloat = 250

    /// The band, drawing the photograph centred on itself.
    ///
    /// This is the change from filling the whole card. A photograph scaled to
    /// cover a card three hundred points tall is a landscape picture enlarged
    /// until it is that tall — which zooms into it, crops the nose and the
    /// tail off the sides, and puts the middle of it, where the aeroplane is,
    /// behind the route and the numbers. Scaled to the card's *width*
    /// instead, the whole aircraft is in frame end to end, and centring the
    /// picture on this band puts it where nothing is written over it.
    private func photoWindow(altitudeFt: Int) -> some View {
        Color.clear
            .frame(height: Self.photoBandHeight)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { band in
                    let width = band.size.width + Self.sideInset * 2
                    let centre = CGPoint(x: band.size.width / 2, y: band.size.height / 2)

                    if let image = image, image.size.width > 0, image.size.height > 0 {
                        let aspect = image.size.height / image.size.width
                        let height = max(width * aspect, Self.minimumPhotoHeight)

                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .saturation(0.92)
                            // Wider than the sheet only when the floor above
                            // scaled it up; the sheet clips what overhangs.
                            .frame(width: height / aspect, height: height)
                            .position(centre)
                    } else {
                        DrawnSky(altitudeFt: altitudeFt)
                            .frame(width: width, height: Self.minimumPhotoHeight)
                            .position(centre)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    /// Darkens the top of the sheet for the name, and stops above the
    /// aeroplane.
    private var headerScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.28), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        // Up under the grabber, out to both edges, and a little way below the
        // descriptor so the ramp ends rather than stopping.
        .padding(.top, -(FlightInfoLayout.peakHandleClearance + 4))
        .padding(.horizontal, -Self.sideInset)
        .padding(.bottom, -18)
        .allowsHitTesting(false)
    }

    /// The deck's own ground: the photograph's lower edge fading into carbon
    /// just above the route, and solid carbon from there to the foot of the
    /// sheet and past it.
    private var deckGround: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: BackdropTokens.carbon.opacity(0), location: 0),
                    .init(color: BackdropTokens.carbon.opacity(0.72), location: 0.6),
                    .init(color: BackdropTokens.carbon.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.deckFade)

            BackdropTokens.carbon.opacity(0.94)
        }
        .padding(.top, -Self.deckFade * 0.5)
        .padding(.horizontal, -Self.sideInset)
        .padding(.bottom, -(FlightInfoLayout.peakBottomGap + Self.backdropOverrun))
        .allowsHitTesting(false)
    }

    /// How tall the fade from photograph to deck is. Half of it rises into
    /// the band, so the gear and the tarmac blend away rather than being cut.
    private static let deckFade: CGFloat = 44

    // MARK: - Who

    private func header(_ tile: WidgetFlight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.callsign)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine(minimumScale: 0.6)
                    // Tapping a second aeroplane changes this window rather
                    // than replacing it, the same as every other peek.
                    .motionWords(tile.callsign)

                HStack(spacing: 6) {
                    Text(descriptor(tile))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(WidgetPalette.secondary)
                        .flightInfoWidgetLine(minimumScale: 0.75)
                        .motionWords(descriptor(tile))

                    // A real aeroplane's photographer is credited in the top
                    // corner, over the photograph, which is where the chip
                    // otherwise goes. It drops to this line instead of sitting
                    // under the credit.
                    if flight.origin == .realWorld { phase(tile) }
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)

            Spacer(minLength: 6)

            if flight.origin != .realWorld { phase(tile) }
        }
    }

    private func phase(_ tile: WidgetFlight) -> some View {
        PhaseChip(symbol: tile.phaseSymbol, text: tile.phaseLabel, size: 11)
            .fixedSize()
            .motionWords(tile.phaseLabel)
    }

    // MARK: - Where, and how far

    private func deck(_ tile: WidgetFlight, progress: FlightProgress?, glance: FlightGlance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                RouteStrip(
                    departure: tile.departureIcao,
                    arrival: tile.arrivalIcao,
                    progress: tile.progress,
                    isLanded: !tile.isAirborne && (tile.progress ?? 0) > 0.9,
                    icaoSize: 28,
                    tint: routeTint
                )

                places(progress)
            }

            FlightGlanceStrip(
                glance: glance,
                ink: WidgetPalette.text,
                secondary: WidgetPalette.secondary,
                dim: WidgetPalette.dim,
                divider: Color.white.opacity(0.12),
                accent: routeTint
            )
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                    }
            }

            if partner != nil {
                VaPartnerLine(partner: partner, theme: deckTheme)
            }
        }
    }

    /// Both airports by name under their codes, with how far along the line
    /// the aeroplane is between them. Nothing at all for an aircraft with no
    /// route: the strip already says `———`, and two blank names under two
    /// blank codes would be the same absence said twice.
    @ViewBuilder
    private func places(_ progress: FlightProgress?) -> some View {
        let departure = AirportStore.shared.airport(flight.departureIcao)
        let arrival = AirportStore.shared.airport(flight.arrivalIcao)

        if departure != nil || arrival != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                place(departure, alignment: .leading)

                if let progress = progress {
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(WidgetPalette.dim)
                        .fixedSize()
                        .motionFigure(progress.fraction)
                }

                place(arrival, alignment: .trailing)
            }
        }
    }

    private func place(_ airport: Airport?, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing
        let flag = airport?.flag ?? ""
        let name = airport?.cityName ?? "Not filed"
        let line = alignment == .leading
            ? [flag, name].filter { !$0.isEmpty }.joined(separator: " ")
            : [name, flag].filter { !$0.isEmpty }.joined(separator: " ")

        return Text(line)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(WidgetPalette.secondary)
            .flightInfoWidgetLine(minimumScale: 0.7)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .motionWords(line)
    }

    // MARK: - Ink

    /// The window's own palette, turned dark for the deck. A light theme's
    /// ink is near-black, which on a carbon deck is nothing at all; the airline
    /// colour is kept, taken at the lightness a dark surface wants.
    private var deckTheme: FlightInfoTheme {
        let appearance = FlightInfoAppearance.shared
        let dark = FlightInfoTheme.resolved(
            palette: appearance.palette,
            scheme: .dark,
            glass: appearance.isGlassEnabled
        )
        guard appearance.showsAirlineAccent else { return dark }
        return dark.accented(by: AirlineAccent.colours(forLivery: flight.liveryName, isLight: false))
    }

    /// The progress line and the climb arrows. The airline's colour when the
    /// window is wearing one, and white otherwise — mono's blue on a photograph
    /// reads as a link.
    private var routeTint: Color {
        let appearance = FlightInfoAppearance.shared
        guard appearance.showsAirlineAccent,
              let colours = AirlineAccent.colours(forLivery: flight.liveryName, isLight: false)
        else { return .white }
        return colours.tint
    }

    // MARK: - Lines

    /// What it is, under the callsign: type, operator, and tail.
    ///
    /// A space rather than an empty string when there is nothing to say: this
    /// line holds the header's height, and a peek that loses a line the moment
    /// a lookup comes back empty is a peek that jumps.
    private func descriptor(_ tile: WidgetFlight) -> String {
        var parts: [String] = []

        if !tile.aircraftType.isEmpty { parts.append(tile.aircraftType) }
        if !tile.liveryName.isEmpty,
           tile.liveryName.caseInsensitiveCompare(tile.aircraftType) != .orderedSame {
            parts.append(tile.liveryName)
        }
        if !tile.registration.isEmpty { parts.append(tile.registration) }
        // A real aeroplane has a type designator and no livery; one the feed
        // has told us nothing about has neither, and is still somebody.
        if parts.isEmpty, !tile.username.isEmpty { parts.append(tile.username) }

        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func summary(_ tile: WidgetFlight, glance: FlightGlance) -> String {
        var parts = [tile.callsign, descriptor(tile), tile.phaseLabel]

        if !tile.departureIcao.isEmpty || !tile.arrivalIcao.isEmpty {
            parts.append("\(tile.departureIcao) to \(tile.arrivalIcao)")
        }

        parts.append("\(Format.number(Double(tile.altitudeFt))) feet")
        parts.append("\(tile.groundSpeedKt) knots")

        if let remaining = glance.remaining, let arrival = glance.arrival {
            parts.append("arriving in \(FlightGlance.countdown(remaining)), at \(FlightGlance.clock(arrival))")
        }

        if let partner = partner {
            parts.append(partner.ad.name)
        }

        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: ", ")
    }
}
