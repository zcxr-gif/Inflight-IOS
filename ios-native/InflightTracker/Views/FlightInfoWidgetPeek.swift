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
///   - the middle is left for the aeroplane;
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

            // The aeroplane's room. A floor rather than a fixed band so a long
            // livery on a large accessibility size can take a second line
            // without pushing the deck off the sheet.
            Spacer(minLength: Self.photoWindow)

            deck(tile, progress: progress, glance: glance)
        }
        .padding(.top, FlightInfoLayout.peakHandleClearance + 4)
        .padding(.horizontal, 18)
        .padding(.bottom, FlightInfoLayout.peakBottomGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            backdrop(altitudeFt: tile.altitudeFt)
                .padding(.bottom, -Self.backdropOverrun)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(tile, glance: glance))
    }

    /// How much photograph is left clear between the name and the deck.
    private static let photoWindow: CGFloat = 54

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

    // MARK: - Ground

    /// The photograph, graded, with the top darkened for the name and the
    /// bottom taken most of the way to carbon for the deck.
    private func backdrop(altitudeFt: Int) -> some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(0.9)
            } else {
                DrawnSky(altitudeFt: altitudeFt)
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.58), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.22),
                    .init(color: .clear, location: 0.34),
                    .init(color: BackdropTokens.carbon.opacity(0.55), location: 0.46),
                    .init(color: BackdropTokens.carbon.opacity(0.9), location: 0.6),
                    .init(color: BackdropTokens.carbon.opacity(0.96), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        // Nothing here is a control, and the photograph's own tap — which opens
        // a real aeroplane's picture at its source — is attached further out.
        .allowsHitTesting(false)
    }

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
