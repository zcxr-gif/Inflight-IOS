import SwiftUI

/// The flight window's third look, in both of its states.
///
/// ## What it is, and what it is not
///
/// It is not the board. The board is a departures board — four rows about a
/// journey, built to answer "is this flight going to be late" above the fold —
/// and it leads with the schedule. This leads with the AEROPLANE: the
/// operator's own bar, its photograph, and the live numbers coming off it. The
/// two are different answers to different questions and neither is a variation
/// on the other.
///
/// ## It does not wear the app's clothes
///
/// Every other surface in this app is drawn through whichever `FlightInfoTheme`
/// the three appearance switches resolve to — mono or carbon, light or dark,
/// glass or flat — and takes the open airline's colour on top of that. This one
/// does not, and that is the point of it rather than an oversight. It is a
/// *look*: a named, fixed thing you choose instead of the window's own, the way
/// a watch face is a face and not a tint. Handed the app's theme it stopped
/// being that — it came out as the cards look with the boxes moved, dark on a
/// dark phone, blue-accented under mono, wearing an airline's green on its
/// hairlines — which is to say it came out as the two looks it exists to be an
/// alternative to.
///
/// So the palettes live here, as constants, and no theme is passed in. There is
/// no route by which a setting elsewhere in the app can reach these views: the
/// dark band, the grey cards, the amber and the near-black ink are what this
/// look is made of, on every phone and under every other choice.
///
/// The window's own cards go on following underneath in the app's theme. Those
/// are the window; this is its head.
///
/// ## What is sold, and what is not
///
/// The layout, and only the layout. Every number here is on the free looks
/// already — height and speed are in the telemetry card, the type and tail are
/// at the foot of the route card, both ends are on the route strip. Pro buys
/// having them on one face, and having the PEEK carry them before the window is
/// opened at all. Nothing about which aeroplanes can be seen, or what is known
/// about any of them, is behind this.
///
/// ## The times, and why there are only two
///
/// Every tracker's flight card prints four: scheduled and actual off, scheduled
/// and estimated on. Two of those come from an airline's published timetable,
/// and the feed behind this app is a simulator's — there is no timetable and no
/// honest way to draw one. So this carries the two that are real: when the
/// flight was first seen moving, and when it arrives at the speed it is doing
/// now. The estimate is marked as one.

// MARK: - What this look is made of

/// The palette, the metrics and the arithmetic of the third look.
///
/// Fixed values rather than a theme, for the reason in the file's own note: a
/// look that resolved against the app's switches would be the cards look with
/// the boxes moved. Nothing here reads a setting.
enum FlightDetailLook {

    // MARK: Colour

    /// The one colour in the look. It carries the callsign on the dark band,
    /// the flown part of the track, the glyph in the route badge and the mark
    /// against the arrival — and nothing else.
    static let accent = Color(red: 0.96, green: 0.68, blue: 0.13)

    /// The band across the top of both states.
    ///
    /// Dark in a look whose body is light, and deliberately: it is the one part
    /// of this that has to read at arm's length — what you check when you have
    /// glanced at an aeroplane and want to know whose it is — and a band that
    /// inverts is a band the eye finds without being aimed.
    static let barGround = Color(red: 0.16, green: 0.16, blue: 0.17)

    /// The two chips beside the callsign. Grey for the tail, which is an
    /// identity, and blue for the type, which is a class of aircraft — the one
    /// place in the look with a second colour, because the two chips sit
    /// side by side and say different kinds of thing.
    static let tailChip = Color(white: 0.34)
    static let typeChip = Color(red: 0.20, green: 0.35, blue: 0.49)

    // MARK: Metrics

    /// Corner on the panel as a whole, and on a card inside it.
    static let panelRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10

    /// The ground showing between cards. Small: these are one face divided,
    /// not a stack of separate cards.
    static let gutter: CGFloat = 4

    /// The width of the right-hand column, which both rows of the peek share so
    /// their edges line up.
    static let sideColumn: CGFloat = 128

    // MARK: The body

    /// Paper, near-black ink, and grey cards on it.
    ///
    /// Passed down to the shared components — the hero, the photo pager, the
    /// chips — so that everything this look draws is drawn in this look, and
    /// none of it has to know that is what happened.
    static let theme = FlightInfoTheme(
        isGlass: false,
        isLight: true,
        windowFill: Color(white: 1.0),
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
        surfaceFill: Color(white: 0.925),
        elevatedFill: Color(white: 0.86),
        // No hairline anywhere in this look. The cards are told apart by the
        // ground showing between them, and a border on top of that reads as a
        // form rather than as a face.
        stroke: .clear,
        strokeStrong: .clear,
        textPrimary: Color(white: 0.11),
        textSecondary: Color(white: 0.42),
        textDim: Color(white: 0.55),
        accent: Self.accent,
        onAccent: Color(white: 0.11),
        trackFill: Color(white: 0.80),
        groundOpacity: 1,
        textHalo: .clear
    )

    /// The same look, inverted, for the band across the top. Only what is drawn
    /// inside the band reads this.
    static let barTheme = FlightInfoTheme(
        isGlass: false,
        isLight: false,
        windowFill: Self.barGround,
        scrim: .clear,
        chromeTint: .clear,
        surfaceTint: .clear,
        elevatedTint: .clear,
        surfaceFill: Self.tailChip,
        elevatedFill: Self.tailChip,
        stroke: .clear,
        strokeStrong: .clear,
        textPrimary: .white,
        textSecondary: Color(white: 0.80),
        textDim: Color(white: 0.62),
        accent: Self.accent,
        onAccent: Color(white: 0.10),
        trackFill: Color.white.opacity(0.22),
        groundOpacity: 1,
        textHalo: .clear
    )

    // MARK: Arithmetic

    /// Feet, because that is what the feed sends and what every other surface
    /// in this app prints. A metric readout would be a units setting, which is
    /// its own feature and not this one — half the app in feet and this one
    /// panel in metres is worse than either.
    static func altitude(_ flight: Flight) -> String {
        let feet = flight.altitudeFeet
        guard feet.isFinite else { return "—" }
        return "\(Format.number(feet)) ft"
    }

    static func speed(_ flight: Flight) -> String {
        let knots = flight.groundSpeedKnots
        guard knots.isFinite else { return "—" }
        return "\(Format.number(knots)) kts"
    }

    /// The model without its manufacturer: the feed sends "Boeing 777-300ER",
    /// and a chip has room for one or the other.
    static func typeCode(_ aircraftName: String) -> String {
        let name = aircraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        let manufacturers = ["Boeing", "Airbus", "Embraer", "Bombardier", "Cessna", "McDonnell Douglas"]
        for maker in manufacturers where name.hasPrefix(maker) {
            let rest = name.dropFirst(maker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? name : rest
        }
        return name
    }

    static func elapsed(since date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        guard interval.isFinite, interval >= 60 else { return "0:00" }
        return Format.duration(interval)
    }
}

extension View {

    /// A card in this look: the grey, the corner, and nothing else.
    fileprivate func flightDetailCard() -> some View {
        background(FlightDetailLook.theme.surfaceFill)
            .clipShape(
                RoundedRectangle(cornerRadius: FlightDetailLook.cardRadius, style: .continuous)
            )
    }

    /// A block in the open window's grid, which is the same grey with square
    /// edges — the grid is one field divided by the ground showing through it,
    /// so the cuts are straight and only the panel has a corner.
    fileprivate func flightDetailBlock() -> some View {
        background(FlightDetailLook.theme.surfaceFill)
    }
}

// MARK: - The operator's bar

/// The band that opens both states: who this is, over the operator's name.
///
/// Dark and full-width in both. It draws its ink out of `barTheme` and nothing
/// else — see the file's note on why no theme reaches this file.
struct FlightDetailOperatorBar: View {

    let flight: Flight

    /// The callsign size. The peek runs smaller than the open window.
    var callsignSize: CGFloat = 19

    /// The type code beside the callsign, in blue.
    var showsTypeChip: Bool = false

    /// The tail beside it, in grey. Off in the peek, which stands the bar
    /// next to a photograph and says the tail along its foot instead — there
    /// is not room for the callsign, two chips, the phase and a picture on one
    /// line, and the tail is the one of those that is said elsewhere.
    var showsTailChip: Bool = false

    var registration: String = ""

    private var theme: FlightInfoTheme { FlightDetailLook.barTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(flight.displayName)
                    .font(.system(size: callsignSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(FlightDetailLook.accent)
                    .flightInfoLine(minimumScale: 0.6)
                    // Tapping a second aeroplane changes this window rather
                    // than replacing it, so the callsign crosses into the new
                    // one instead of cutting to it.
                    .motionWords(flight.displayName)

                if showsTailChip, !registration.isEmpty {
                    chip(registration, fill: FlightDetailLook.tailChip)
                }

                if showsTypeChip, !typeCode.isEmpty {
                    chip(typeCode, fill: FlightDetailLook.typeChip)
                }

                Spacer(minLength: 6)

                FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
            }

            HStack(spacing: 6) {
                Text(operatorLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.7)
                    .motionWords(operatorLine)

                Spacer(minLength: 6)

                if flight.pilotState.isNoteworthy {
                    PilotStateChip(state: flight.pilotState, theme: theme, elevated: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .motion(Motion.control, value: flight.pilotState)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The livery, or the pilot's name when the aircraft is in no airline's
    /// paint — a bar with a blank line where the operator goes reads as missing
    /// data rather than as a private aeroplane.
    private var operatorLine: String {
        let livery = flight.liveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !livery.isEmpty { return livery }
        return flight.username ?? "Private flight"
    }

    /// The model without its manufacturer, for a chip that has room for one
    /// but not both.
    private var typeCode: String {
        FlightDetailLook.typeCode(flight.aircraftName)
    }

    private func chip(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill)
            }
            .fixedSize()
    }
}

// MARK: - Shared pieces

/// The badge between the two ends of a route: a white disc with the look's
/// amber aeroplane in it.
///
/// Its own view rather than the app's `RouteTrack` glyph, because it is a
/// different thing in a different place — this marks the route, the track marks
/// how far along it the aircraft is.
private struct FlightDetailRouteBadge: View {

    var diameter: CGFloat = 30

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "airplane")
                    .font(.system(size: diameter * 0.46, weight: .semibold))
                    .foregroundStyle(FlightDetailLook.accent)
            }
            .accessibilityHidden(true)
    }
}

/// How far along the route the aircraft is, in this look's own bar.
///
/// Not the app's `RouteTrack`: that one reads the window's theme and carries a
/// plane glyph riding the fill, which is the *cards* look's way of drawing this.
/// Here the bar is a bar.
private struct FlightDetailTrack: View {

    let fraction: Double

    var height: CGFloat = 4

    /// The glyph at the head of the fill. Off in the peek, where the bar is a
    /// hairline under a route and there is no room for it; on in the open
    /// window, where the bar has a line of its own.
    var showsPlane: Bool = false

    var body: some View {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)

        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FlightDetailLook.theme.trackFill)
                    .frame(height: height)

                Capsule()
                    .fill(FlightDetailLook.accent)
                    .frame(width: max(height, width * clamped), height: height)

                if showsPlane {
                    Image(systemName: "airplane")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlightDetailLook.accent)
                        .offset(x: min(max(0, width * clamped - 6.5), max(0, width - 13)))
                }
            }
            .frame(height: geometry.size.height, alignment: .center)
            // The fill is a distance rather than a readout: it has somewhere to
            // travel, so it travels.
            .motion(Motion.content, value: clamped)
        }
        .frame(height: showsPlane ? 14 : height)
    }
}

// MARK: - The peek

/// The bar this look peeks as: everything on one face, before the window is
/// opened.
///
/// Three bands — who, where and how, and what — laid out so the eye can take
/// the whole thing in one go rather than reading it. The photograph is flush
/// into the right of the dark band, which is the one place on a face this dense
/// where a picture does not push a number off the end.
struct FlightDetailPeek: View {

    let flight: Flight
    let registration: String

    /// The photograph, and everything the lookup found for this type.
    let image: UIImage?
    var photos: [AircraftPhoto] = []
    var isAutoplaying: Bool = true

    /// When the flight was first seen moving.
    let began: Date?

    @State private var page = 0

    private var theme: FlightInfoTheme { FlightDetailLook.theme }

    private var progress: FlightProgress? {
        guard flight.departureIcao?.isEmpty == false,
              flight.arrivalIcao?.isEmpty == false else { return nil }
        return FlightProgress(flight: flight)
    }

    var body: some View {
        VStack(spacing: FlightDetailLook.gutter) {
            head

            HStack(alignment: .top, spacing: FlightDetailLook.gutter) {
                route
                readouts
            }

            HStack(alignment: .top, spacing: FlightDetailLook.gutter) {
                type
                tail
            }
        }
        .background(theme.windowFill)
        .clipShape(
            RoundedRectangle(cornerRadius: FlightDetailLook.panelRadius, style: .continuous)
        )
    }

    // MARK: Who

    /// How much of the dark band the photograph takes.
    private static let thumbnailWidth: CGFloat = 124

    /// The dark band, with the photograph flush into the end of it.
    ///
    /// The picture is an overlay over the band rather than the second half of a
    /// row, and that is what makes it fill the band's height exactly: an
    /// overlay is proposed the size of what it is drawn over, where a sibling
    /// in a self-sizing row is proposed nothing and comes back at whatever
    /// height a photograph thinks it is. The bar keeps clear of it with a
    /// trailing inset of the same width.
    private var head: some View {
        FlightDetailOperatorBar(
            flight: flight,
            callsignSize: 19,
            showsTypeChip: true
        )
        .padding(.trailing, Self.thumbnailWidth + 8)
        .background(FlightDetailLook.barGround)
        .overlay(alignment: .trailing) {
            thumbnail
                .frame(width: Self.thumbnailWidth)
                .clipped()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if photos.count > 1 {
            AircraftPhotoPager(
                photos: photos,
                preloaded: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 28,
                isAutoplaying: isAutoplaying,
                page: $page
            )
        } else {
            AircraftPhotoImage(
                image: image,
                spriteKey: flight.spriteKey,
                theme: theme,
                iconSize: 28,
                contentMode: .fit
            )
        }
    }

    // MARK: Where, and how

    /// Both ends of the route, the bar between them, and the two times under
    /// it.
    private var route: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 6) {
                end(progress?.departure, icao: flight.departureIcao, alignment: .leading)

                FlightDetailRouteBadge(diameter: 30)
                    .padding(.top, 1)

                end(progress?.arrival, icao: flight.arrivalIcao, alignment: .trailing)
            }

            if let progress = progress {
                FlightDetailTrack(fraction: progress.fraction)

                HStack(spacing: 6) {
                    Text(departedLine)
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(departedLine)

                    Spacer(minLength: 4)

                    Text(arrivingLine)
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(arrivingLine)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightDetailCard()
    }

    private func end(
        _ airport: Airport?,
        icao: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        return VStack(alignment: alignment, spacing: 0) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Not filed").uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    /// The two live numbers, in a column of their own.
    ///
    /// Beside the route rather than under it because the two answer at
    /// different speeds: the route is what the flight IS and barely changes,
    /// these are what it is doing and change every packet. Putting the moving
    /// half in its own column stops the whole face from looking restless.
    private var readouts: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout("BAROMETRIC ALT.", FlightDetailLook.altitude(flight))
            readout("GROUND SPEED", FlightDetailLook.speed(flight))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: FlightDetailLook.sideColumn, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .flightDetailCard()
    }

    private func readout(_ kicker: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kicker)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.7)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
                .motionWords(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What

    private var type: some View {
        Text(flight.aircraftName.isEmpty ? "Unknown type" : flight.aircraftName)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .flightInfoLine(minimumScale: 0.6)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightDetailCard()
    }

    private var tail: some View {
        HStack(spacing: 5) {
            Text("REG.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Text(registration.isEmpty ? "—" : registration)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
                // Blank until the photo lookup finds a tail number, which lands
                // a second after the window opens.
                .motionWords(registration)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: FlightDetailLook.sideColumn, alignment: .leading)
        .flightDetailCard()
    }

    // MARK: Lines

    private var departedLine: String {
        guard let began = began else { return "Departure not seen" }
        return "Departed \(FlightDetailLook.elapsed(since: began)) ago"
    }

    private var arrivingLine: String {
        guard let progress = progress,
              let remaining = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)
        else { return "No estimate" }
        return "Arriving in \(Format.duration(remaining))"
    }
}

// MARK: - The open window's head

/// What replaces the identity block when this look is chosen and the window is
/// open.
///
/// The operator's bar, the photograph under it at the size it wants to be, both
/// ends of the route under that, then the live numbers as a grid and the run
/// itself at the foot. The window's own cards follow underneath in the app's
/// theme — this replaces the head of the window, not the window.
struct FlightDetailHead: View {

    let flight: Flight
    let registration: String

    let image: UIImage?
    let contributor: String?
    var photos: [AircraftPhoto] = []
    var isAutoplaying: Bool = true

    /// The width the photograph has to fill.
    let width: CGFloat

    let began: Date?

    var onSelectAirport: ((Airport) -> Void)? = nil

    private var theme: FlightInfoTheme { FlightDetailLook.theme }

    private var progress: FlightProgress? {
        guard flight.departureIcao?.isEmpty == false,
              flight.arrivalIcao?.isEmpty == false else { return nil }
        return FlightProgress(flight: flight)
    }

    var body: some View {
        VStack(spacing: 0) {
            FlightDetailOperatorBar(
                flight: flight,
                callsignSize: 24,
                showsTypeChip: true,
                showsTailChip: true,
                registration: registration
            )
            .background(FlightDetailLook.barGround)

            FlightHero(
                image: image,
                spriteKey: flight.spriteKey,
                contributor: contributor,
                theme: theme,
                width: width,
                photos: photos,
                isAutoplaying: isAutoplaying,
                // A hard edge under the picture. The fade is there so a photo
                // can dissolve into the window's own ground; here the thing
                // under it is the route, on a ground of its own, and a photo
                // that washed out into it would read as a rendering fault.
                blendsWithWindow: false
            )

            grid

            run
        }
        .background(theme.windowFill)
        .clipShape(
            RoundedRectangle(cornerRadius: FlightDetailLook.panelRadius, style: .continuous)
        )
    }

    // MARK: Where, and how

    /// The route and the four numbers, as one field cut by the ground showing
    /// through it.
    private var grid: some View {
        VStack(spacing: 2) {
            route

            HStack(spacing: 2) {
                cell("BAROMETRIC ALT.", FlightDetailLook.altitude(flight), isEstimate: false)
                cell("GROUND SPEED", FlightDetailLook.speed(flight), isEstimate: false)
            }

            HStack(spacing: 2) {
                cell("DEPARTED", departedValue, isEstimate: false)
                cell("ARRIVING", arrivingValue, isEstimate: true)
            }
        }
    }

    private var route: some View {
        HStack(alignment: .top, spacing: 8) {
            end(progress?.departure, icao: flight.departureIcao, alignment: .leading)

            FlightDetailRouteBadge(diameter: 42)
                .padding(.top, 4)

            end(progress?.arrival, icao: flight.arrivalIcao, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .flightDetailBlock()
    }

    @ViewBuilder
    private func end(
        _ airport: Airport?,
        icao: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        let block = VStack(alignment: alignment, spacing: 1) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Not filed").uppercased())
                .font(.system(size: 11.5, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)

            if let flag = airport?.flag, !flag.isEmpty {
                Text(flag).font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)

        if let airport = airport, let onSelectAirport = onSelectAirport {
            Button { onSelectAirport(airport) } label: { block.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(airport.icao), \(airport.name). Open this airport.")
        } else {
            block
        }
    }

    private func cell(_ kicker: String, _ value: String, isEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.7)

            HStack(spacing: 5) {
                // The mark that says this one is arithmetic rather than
                // observation — the difference between a time and a promise.
                if isEstimate {
                    Circle().fill(FlightDetailLook.accent).frame(width: 6, height: 6)
                }

                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.55)
                    .motionWords(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .flightDetailBlock()
    }

    // MARK: The run

    /// The bar, and the two distances either side of it. On the panel's own
    /// ground rather than in the grid: it is the one thing here that moves.
    @ViewBuilder
    private var run: some View {
        if let progress = progress {
            VStack(spacing: 7) {
                FlightDetailTrack(fraction: progress.fraction, showsPlane: true)

                HStack(spacing: 8) {
                    Text(flownLine(progress))
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(flownLine(progress))

                    Spacer(minLength: 6)

                    Text(remainingLine(progress))
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(remainingLine(progress))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
    }

    private func flownLine(_ progress: FlightProgress) -> String {
        "\(Format.number(progress.flownNM)) nm, \(departedValue)"
    }

    private func remainingLine(_ progress: FlightProgress) -> String {
        "\(Format.number(progress.remainingNM)) nm, \(arrivingValue)"
    }

    private var departedValue: String {
        guard let began = began else { return "—" }
        return "\(FlightDetailLook.elapsed(since: began)) ago"
    }

    private var arrivingValue: String {
        guard let progress = progress,
              let remaining = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)
        else { return "—" }
        return "in \(Format.duration(remaining))"
    }
}
