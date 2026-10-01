import SwiftUI
import UIKit

/// The peek that is a flight card: the aircraft's photograph across the top of
/// the window, fading into a dark deck that carries the route and the numbers.
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
/// Now the window *is* the card, edge to edge, in two parts:
///
///   - the photograph, at the top, in its own shape. It is drawn the full
///     width of the sheet and as tall as that width makes it, so the whole
///     aeroplane is in frame, nose to tail — see `photographHeight(for:width:)`.
///     The name rides its top edge over a short scrim, the way every photo
///     header in the app does.
///   - the deck, starting just above the photograph's foot, carrying the
///     route with both airports named, how far along it is, and the glance
///     strip. The photograph fades into the deck's own colour as it goes
///     under it, so there is no line anywhere where the picture ends.
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

    /// How wide the sheet is, which is how wide the photograph is drawn and
    /// therefore — with the photograph's own shape — how tall.
    var width: CGFloat = 0

    /// How far the backdrop runs past the bottom of what the peek measures.
    ///
    /// The peek sizes the sheet, so in a settled window these are the same
    /// height. They are not while the sheet is arriving or being dragged, and
    /// a ground that stopped at the peek's own edge would show a strip of map
    /// under it for those frames. The sheet clips the excess.
    private static let backdropOverrun: CGFloat = 120

    var body: some View {
        // Resolved once. It walks the airport table and does the route's
        // great-circle arithmetic, which is not work to do five times because
        // five subviews each wanted a number out of it.
        let tile = WidgetFlight(flight: flight)
        let progress = FlightProgress(flight: flight)
        let glance = FlightGlance(flight: flight, progress: progress)
        let photoHeight = Self.photographHeight(for: image, width: width)

        VStack(alignment: .leading, spacing: 0) {
            // The photograph's room: from the top of the sheet to where the
            // deck takes over. The name rides the top of it; the picture
            // itself is drawn behind, in the background, at its full height.
            Color.clear
                .frame(height: max(0, photoHeight - Self.deckOverlap))
                .overlay(alignment: .topLeading) {
                    header(tile)
                        .padding(.top, FlightInfoLayout.peakHandleClearance + 4)
                        .padding(.horizontal, Self.sideInset)
                }

            deck(tile, progress: progress, glance: glance)
                .padding(.horizontal, Self.sideInset)
        }
        .padding(.bottom, FlightInfoLayout.peakBottomGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                // The deck's colour, everywhere the photograph is not — which
                // the photograph fades into exactly, so the two never meet at
                // an edge.
                BackdropTokens.carbon

                photograph(height: photoHeight, altitudeFt: tile.altitudeFt)
            }
            .padding(.bottom, -Self.backdropOverrun)
            .allowsHitTesting(false)
        }
        // One aeroplane's photograph is a different shape from the next one's,
        // and the card grows or shrinks with it. It moves to its new height
        // rather than jumping there; the window moves the sheet on the same
        // curve — see `FlightDetailView.fitPeak(to:)`.
        .motion(Motion.panel, value: photoHeight)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(tile, glance: glance))
    }

    /// The margin the content keeps from the sheet's sides. The photograph
    /// and the ground run out past it to the edges.
    private static let sideInset: CGFloat = 18

    // MARK: - The photograph

    /// How far the deck rises into the foot of the photograph. The route's
    /// codes sit over the last of the tarmac, already faded most of the way
    /// to the deck's colour, so the card reads as one surface rather than as
    /// a picture with a panel stacked under it.
    private static let deckOverlap: CGFloat = 30

    /// The range the photograph's height is kept to.
    ///
    /// Inside it, a photograph is drawn in its own shape — the full width of
    /// the sheet, and exactly as tall as that makes it — so nothing is cropped
    /// and the whole aeroplane is in frame. A three-by-two shot on a phone is
    /// a little over the ceiling and loses a few points of sky and apron; a
    /// sixteen-by-nine one fits inside it whole.
    ///
    /// Past the ceiling — a portrait shot, or a square one — the photograph
    /// is cropped to it top and bottom, keeping the middle, which is where an
    /// aeroplane is in a photograph of one. Below the floor, a panorama is
    /// scaled up to it and trimmed at the sides. Both limits are there so the
    /// card stays a card: a portrait photograph drawn whole would take most of
    /// the screen, and a letterbox one would leave no room for the name.
    private static let minimumPhotoHeight: CGFloat = 180
    private static let maximumPhotoHeight: CGFloat = 260

    /// The shape assumed before a photograph has arrived, which is what an
    /// airliner photograph usually is. Close to the real thing, so the card is
    /// already nearly the right height when the picture lands and has only a
    /// little way to move.
    private static let placeholderAspect: CGFloat = 0.6

    /// How tall the photograph is drawn. See `minimumPhotoHeight`.
    static func photographHeight(for image: UIImage?, width: CGFloat) -> CGFloat {
        guard width > 0 else { return minimumPhotoHeight }

        let aspect: CGFloat
        if let image = image, image.size.width > 0, image.size.height > 0 {
            aspect = image.size.height / image.size.width
        } else {
            aspect = placeholderAspect
        }

        return min(max(width * aspect, minimumPhotoHeight), maximumPhotoHeight)
    }

    /// The photograph, the full width of the sheet, with a scrim at its top
    /// for the name and its foot faded into the deck.
    ///
    /// A new photograph cross-fades over the last one rather than replacing
    /// it on the frame it arrives — keyed on which photograph it is, so
    /// tapping from one aeroplane to the next dissolves picture into picture.
    /// The window holds the outgoing photograph for a moment while the next is
    /// found (`RemoteImageLoader.handoverGrace`), which is what gives it
    /// something to dissolve from.
    private func photograph(height: CGFloat, altitudeFt: Int) -> some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(0.92)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                DrawnSky(altitudeFt: altitudeFt)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .overlay(alignment: .top) { nameScrim }
        .overlay(alignment: .bottom) { footFade }
        .motion(Motion.panel, value: image.map(ObjectIdentifier.init))
    }

    /// Darkens the top of the photograph for the name, and is gone well
    /// before the aeroplane.
    private var nameScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.24), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 116)
    }

    /// Takes the foot of the photograph into the deck's colour.
    ///
    /// All the way into it — fully opaque at the photograph's last row, which
    /// is the colour the ground beneath it already is — so there is no step
    /// where the picture stops, however short a wide photograph leaves it.
    /// Most of the ramp is spent above the deck's top edge, so the gear and
    /// the apron blend away rather than being cut, and the route's codes sit
    /// on ground that is already nearly the deck.
    private var footFade: some View {
        let height = Self.deckOverlap + 64
        let deckTop = 64 / height

        return LinearGradient(
            stops: [
                .init(color: BackdropTokens.carbon.opacity(0), location: 0),
                .init(color: BackdropTokens.carbon.opacity(0.5), location: deckTop * 0.6),
                .init(color: BackdropTokens.carbon.opacity(0.86), location: deckTop),
                .init(color: BackdropTokens.carbon, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
    }

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
