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
/// ## What it contributes, and what it takes
///
/// It contributes CONTAINERS, and they are plugged into the window that is
/// already there. The band, the picture, the route, the cells: each is a card
/// on the window's own ground, at the window's own spacing, drawn through the
/// window's own `FlightInfoTheme` — so it is light on a light phone, glass
/// where the app is glass, and wearing the open airline's colour like every
/// other card in the sheet.
///
/// It was briefly built the other way: one self-contained face with a palette
/// of its own, laid into the window like a photograph in an album. Two things
/// were wrong with that. A panel with its own ground sitting inside a panel
/// with a different one is a box in a box — the window stops being a window and
/// becomes a frame around somebody else's card. And a fixed palette is a fixed
/// palette: it ignores light and dark, it ignores glass, and it throws away the
/// airline accent, which is the one thing on this window that is actually ours.
///
/// So what is different about this look is the ARRANGEMENT and the emphasis —
/// what is on top, what is beside what, what is big. Not the colours. A look
/// that has to bring its own colours to be a look was not a layout worth
/// choosing in the first place.
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

// MARK: - The operator's bar

/// The band that opens both states: who this is, over the operator's name.
///
/// Elevated rather than dark. It is the head of the face and has to read first,
/// which under a fixed palette meant a near-black slab and under the window's
/// own theme means one step up off the ground — the same move the window
/// already makes for a chip sitting on a card, and it works in both directions
/// without the look having to know which way round the app is.
struct FlightDetailOperatorBar: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// The callsign size. The peek runs smaller than the open window.
    var callsignSize: CGFloat = 19

    /// The type code beside the callsign.
    var showsTypeChip: Bool = false

    /// The tail beside it. Off in the peek, which stands the bar next to a
    /// photograph and says the tail along its foot instead — there is not room
    /// for the callsign, two chips, the phase and a picture on one line, and
    /// the tail is the one of those that is said elsewhere.
    var showsTailChip: Bool = false

    var registration: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(flight.displayName)
                    .font(.system(size: callsignSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .flightInfoLine(minimumScale: 0.6)
                    // Tapping a second aeroplane changes this window rather
                    // than replacing it, so the callsign crosses into the new
                    // one instead of cutting to it.
                    .motionWords(flight.displayName)

                if showsTailChip, !registration.isEmpty { chip(registration) }
                if showsTypeChip, !typeCode.isEmpty { chip(typeCode) }

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
        .padding(.vertical, 11)
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .flightInfoSurface(theme, radius: 6, elevated: true)
            .fixedSize()
    }
}

// MARK: - Shared pieces

/// The badge between the two ends of a route.
///
/// The app's own filled-accent marker, the same one the route card puts on a
/// controlled field: accent disc, `onAccent` glyph. That is what a badge looks
/// like in this window, and this look has no business inventing a second one.
private struct FlightDetailRouteBadge: View {

    let theme: FlightInfoTheme

    var diameter: CGFloat = 30

    var body: some View {
        Circle()
            .fill(theme.accent)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "airplane")
                    .font(.system(size: diameter * 0.46, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
            }
            .accessibilityHidden(true)
    }
}

/// Both ends of a route, side by side, with the badge between them.
///
/// Shared by the two states because it is the piece that makes this look what
/// it is — the route as a headline rather than as a line of a card — and the
/// two differ only in how big it is set.
private struct FlightDetailRouteEnds: View {

    let flight: Flight
    let progress: FlightProgress?
    let theme: FlightInfoTheme

    let codeSize: CGFloat
    let nameSize: CGFloat
    let badgeSize: CGFloat

    /// Whether either end opens as a field of its own. The peak state is a drag
    /// target from edge to edge and passes nothing.
    var onSelectAirport: ((Airport) -> Void)? = nil

    /// Whether the flag under the name is drawn. Room for it in the open
    /// window; none in the peek.
    var showsFlag: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            end(progress?.departure, icao: flight.departureIcao, alignment: .leading)

            FlightDetailRouteBadge(theme: theme, diameter: badgeSize)
                .padding(.top, 2)

            end(progress?.arrival, icao: flight.arrivalIcao, alignment: .trailing)
        }
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
                .font(.system(size: codeSize, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Not filed").uppercased())
                .font(.system(size: nameSize, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)

            if showsFlag, let flag = airport?.flag, !flag.isEmpty {
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
}

// MARK: - The peek

/// The bar this look peeks as: everything on one face, before the window is
/// opened.
///
/// Three containers on the window's own ground — who, then where and how, then
/// what — laid out so the eye can take the whole thing in one go rather than
/// reading it. The photograph is flush into the end of the band, which is the
/// one place on a face this dense where a picture does not push a number off
/// the end.
struct FlightDetailPeek: View {

    let flight: Flight
    let registration: String
    let theme: FlightInfoTheme

    /// The photograph, and everything the lookup found for this type.
    let image: UIImage?
    var photos: [AircraftPhoto] = []
    var isAutoplaying: Bool = true

    /// When the flight was first seen moving.
    let began: Date?

    @State private var page = 0

    private var progress: FlightProgress? {
        guard flight.departureIcao?.isEmpty == false,
              flight.arrivalIcao?.isEmpty == false else { return nil }
        return FlightProgress(flight: flight)
    }

    var body: some View {
        VStack(spacing: FlightDetailLook.gutter) {
            band

            HStack(alignment: .top, spacing: FlightDetailLook.gutter) {
                route
                readouts
            }

            HStack(alignment: .top, spacing: FlightDetailLook.gutter) {
                type
                tail
            }
        }
    }

    // MARK: Who

    /// How much of the band the photograph takes.
    private static let thumbnailWidth: CGFloat = 120

    /// The band, with the photograph flush into the end of it.
    ///
    /// The picture is an overlay over the band rather than the second half of a
    /// row, and that is what makes it fill the band's height exactly: an
    /// overlay is proposed the size of what it is drawn over, where a sibling
    /// in a self-sizing row is proposed nothing and comes back at whatever
    /// height a photograph thinks it is. The bar keeps clear of it with a
    /// trailing inset of the same width.
    private var band: some View {
        FlightDetailOperatorBar(
            flight: flight,
            theme: theme,
            callsignSize: 19,
            showsTypeChip: true
        )
        .padding(.trailing, Self.thumbnailWidth)
        .flightInfoSurface(theme, radius: theme.radiusMedium, elevated: true)
        .overlay(alignment: .trailing) {
            thumbnail.frame(width: Self.thumbnailWidth)
        }
        // After the surface as well as the overlay: glass is drawn in the
        // shape but does not clip what is inside it, and the photograph is
        // inside it.
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
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
            FlightDetailRouteEnds(
                flight: flight,
                progress: progress,
                theme: theme,
                codeSize: 25,
                nameSize: 9.5,
                badgeSize: 28
            )

            if let progress = progress {
                RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 10)

                HStack(spacing: 6) {
                    Text(departedLine)
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(departedLine)

                    Spacer(minLength: 4)

                    Text(arrivingLine)
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(arrivingLine)
                }
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    /// The two live numbers, in a column of their own.
    ///
    /// Beside the route rather than under it because the two answer at
    /// different speeds: the route is what the flight IS and barely changes,
    /// these are what it is doing and change every packet. Putting the moving
    /// half in its own column stops the whole face from looking restless.
    private var readouts: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout("ALTITUDE", FlightDetailLook.altitude(flight))
            readout("GROUND SPEED", FlightDetailLook.speed(flight))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: FlightDetailLook.sideColumn, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func readout(_ kicker: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kicker)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)

            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
                .motionWords(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What

    private var type: some View {
        Text(flight.aircraftName.isEmpty ? "Unknown type" : flight.aircraftName)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .flightInfoLine(minimumScale: 0.6)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var tail: some View {
        HStack(spacing: 5) {
            Text("REG")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)

            Text(registration.isEmpty ? "—" : registration)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)
                // Blank until the photo lookup finds a tail number, which lands
                // a second after the window opens.
                .motionWords(registration)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: FlightDetailLook.sideColumn, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: Lines

    private var departedLine: String {
        guard let began = began else { return "DEPARTURE NOT SEEN" }
        return "DEPARTED \(FlightDetailLook.elapsed(since: began)) AGO"
    }

    private var arrivingLine: String {
        guard let progress = progress,
              let remaining = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)
        else { return "NO ESTIMATE" }
        return "ARRIVING IN \(Format.duration(remaining))"
    }
}

// MARK: - The open window's head

/// What replaces the identity block when this look is chosen and the window is
/// open.
///
/// The operator's bar, the photograph under it at the size it wants to be, both
/// ends of the route under that, then the live numbers. Cards on the window's
/// own ground at the window's own spacing, so the sheet goes on being one
/// stack of cards from the top of the photograph to the foot of the hints —
/// this look decides the order and the emphasis of the first five, and the
/// window's own cards follow underneath unchanged.
struct FlightDetailHead: View {

    let flight: Flight
    let registration: String
    let theme: FlightInfoTheme

    let image: UIImage?
    let contributor: String?
    var photos: [AircraftPhoto] = []
    var isAutoplaying: Bool = true

    /// The width the photograph has to fill.
    let width: CGFloat

    let began: Date?

    var onSelectAirport: ((Airport) -> Void)? = nil

    private var progress: FlightProgress? {
        guard flight.departureIcao?.isEmpty == false,
              flight.arrivalIcao?.isEmpty == false else { return nil }
        return FlightProgress(flight: flight)
    }

    var body: some View {
        VStack(spacing: 10) {
            FlightDetailOperatorBar(
                flight: flight,
                theme: theme,
                callsignSize: 24,
                showsTypeChip: true,
                showsTailChip: true,
                registration: registration
            )
            .flightInfoSurface(theme, radius: theme.radiusMedium, elevated: true)

            photograph

            route

            HStack(spacing: 8) {
                cell("ALTITUDE", FlightDetailLook.altitude(flight), isEstimate: false)
                cell("GROUND SPEED", FlightDetailLook.speed(flight), isEstimate: false)
            }

            HStack(spacing: 8) {
                cell("DEPARTED", departedValue, isEstimate: false)
                cell("ARRIVING", arrivingValue, isEstimate: true)
            }
        }
    }

    // MARK: The picture

    /// The photograph as a card of its own.
    ///
    /// The window's other looks run it full bleed off the top of the sheet,
    /// where it is the header and has an edge of the screen to end on. Here it
    /// is the second card down with cards above and below it, so it takes the
    /// same corner as they do and does not fade out at its foot — a picture
    /// dissolving into the middle of a stack reads as a rendering fault rather
    /// than as a seam.
    private var photograph: some View {
        FlightHero(
            image: image,
            spriteKey: flight.spriteKey,
            contributor: contributor,
            theme: theme,
            width: width,
            photos: photos,
            isAutoplaying: isAutoplaying,
            fadesIntoGround: false
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }

    // MARK: Where, and how

    private var route: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlightDetailRouteEnds(
                flight: flight,
                progress: progress,
                theme: theme,
                codeSize: 36,
                nameSize: 11,
                badgeSize: 40,
                onSelectAirport: onSelectAirport,
                showsFlag: true
            )

            if let progress = progress {
                RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 13)

                HStack(spacing: 8) {
                    Text(flownLine(progress))
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(flownLine(progress))

                    Spacer(minLength: 6)

                    Text(remainingLine(progress))
                        .flightInfoLine(minimumScale: 0.7)
                        .motionWords(remainingLine(progress))
                }
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func cell(_ kicker: String, _ value: String, isEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // The mark that says this one is arithmetic rather than
                // observation — the difference between a time and a promise.
                if isEstimate {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                }

                Text(kicker)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }

            Text(value)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.55)
                .motionWords(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }

    // MARK: Lines

    private func flownLine(_ progress: FlightProgress) -> String {
        "\(Format.number(progress.flownNM)) NM FLOWN"
    }

    private func remainingLine(_ progress: FlightProgress) -> String {
        "\(Format.number(progress.remainingNM)) NM TO RUN"
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

// MARK: - Shared measurements and arithmetic

/// The bits both states say the same way, so they cannot drift apart.
///
/// No colours. See the file's own note: this look brings an arrangement, and
/// takes its palette from the window it is plugged into.
enum FlightDetailLook {

    /// The window's own ground, showing between this look's cards. Tighter than
    /// the twelve the sheet stacks its cards at: these are one face divided,
    /// and at the sheet's spacing they stop reading as a face at all.
    static let gutter: CGFloat = 6

    /// The width of the right-hand column of the peek, which both of its rows
    /// share so their edges line up.
    static let sideColumn: CGFloat = 124

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
