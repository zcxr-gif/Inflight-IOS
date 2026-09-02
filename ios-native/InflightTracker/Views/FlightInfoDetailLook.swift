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
/// A stack of blocks, in whatever order `FlightInfoBlocks` says, each wearing
/// whatever colour it has been given. The window's own cards follow underneath
/// unchanged — this look decides what the top of the sheet is made of, and the
/// sheet goes on being a sheet.
///
/// ## Nothing here is said twice
///
/// The look owns the live numbers now. Before this it printed the height and
/// the speed at the top of the window and the window printed them again in its
/// telemetry card four cards down, which is the sort of thing you only notice
/// once and then cannot stop noticing. So the telemetry block carries all four
/// — height, speed, climb, heading — and `FlightDetailView` draws no telemetry
/// card of its own under this look. One place, and it is the one you can move.
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

    @ObservedObject private var arrangement = FlightInfoBlocks.shared

    private var progress: FlightProgress? {
        guard flight.departureIcao?.isEmpty == false,
              flight.arrivalIcao?.isEmpty == false else { return nil }
        return FlightProgress(flight: flight)
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(arrangement.visible) { block in
                content(for: block)
                    // Keyed on the block rather than on its kind, so changing a
                    // colour in the editor with the window open crosses to the
                    // new one instead of cutting to it.
                    .motion(Motion.panel, value: block)
            }
        }
        // The whole stack re-lays out when a block is moved, switched off or
        // added, and it does it as a movement rather than as a jump.
        .motion(Motion.panel, value: arrangement.blocks)
    }

    /// One block, drawn and dressed.
    ///
    /// The photograph is the one that takes no card: it is a picture, and a
    /// picture in a tinted card with a rule along the top is a picture in a
    /// frame. It takes the corner and nothing else.
    @ViewBuilder
    private func content(for block: FlightInfoBlock) -> some View {
        let dressed = theme.wearing(block)

        switch block.kind {
        case .identity:
            FlightDetailOperatorBar(
                flight: flight,
                theme: dressed,
                callsignSize: 24,
                showsTypeChip: true,
                showsTailChip: true,
                registration: registration
            )
            .flightInfoBlock(block, theme: dressed, elevated: true)

        case .photo:
            photograph

        case .route:
            route(dressed).flightInfoBlock(block, theme: dressed)

        case .progress:
            run(dressed).flightInfoBlock(block, theme: dressed)

        case .times:
            times(dressed).flightInfoBlock(block, theme: dressed)

        case .telemetry:
            telemetry(dressed).flightInfoBlock(block, theme: dressed)

        case .aircraft:
            aircraft(dressed).flightInfoBlock(block, theme: dressed)

        case .position:
            coordinates(dressed).flightInfoBlock(block, theme: dressed)
        }
    }

    // MARK: The picture

    /// The photograph as a card of its own.
    ///
    /// The window's other looks run it full bleed off the top of the sheet,
    /// where it is the header and has an edge of the screen to end on. Here it
    /// is one block among several with cards above and below it, so it takes
    /// the same corner as they do and does not fade out at its foot — a picture
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

    // MARK: Where

    private func route(_ theme: FlightInfoTheme) -> some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bar, and the two distances either side of it.
    ///
    /// Draws the distances as dashes rather than drawing nothing when there is
    /// no route: a block that is on and empty is a block that looks broken,
    /// where a block saying "—" is a block saying nothing is filed.
    @ViewBuilder
    private func run(_ theme: FlightInfoTheme) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            RouteTrack(
                fraction: progress?.fraction ?? 0,
                theme: theme,
                planeSize: 13
            )

            HStack(spacing: 8) {
                Text(flownLine)
                    .flightInfoLine(minimumScale: 0.7)
                    .motionWords(flownLine)

                Spacer(minLength: 6)

                Text(remainingLine)
                    .flightInfoLine(minimumScale: 0.7)
                    .motionWords(remainingLine)
            }
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: How

    private func times(_ theme: FlightInfoTheme) -> some View {
        HStack(spacing: 0) {
            cell("DEPARTED", departedValue, theme: theme, isEstimate: false)

            divider(theme)

            cell("ARRIVING", arrivingValue, theme: theme, isEstimate: true)
        }
        .padding(.vertical, 12)
    }

    /// The four live numbers, as two rows of two.
    ///
    /// All four, and this is the only place they are printed under this look —
    /// see the note on the type. Height and speed lead because they are what a
    /// glance is for; climb and heading follow because they are what you read
    /// once you have decided to look properly.
    private func telemetry(_ theme: FlightInfoTheme) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                cell("ALTITUDE", FlightDetailLook.altitude(flight), theme: theme, isEstimate: false)
                divider(theme)
                cell("GROUND SPEED", FlightDetailLook.speed(flight), theme: theme, isEstimate: false)
            }

            HStack(spacing: 0) {
                cell("VERTICAL", FlightDetailLook.vertical(flight), theme: theme, isEstimate: false)
                divider(theme)
                cell("HEADING", FlightDetailLook.heading(flight), theme: theme, isEstimate: false)
            }
        }
        .padding(.vertical, 12)
    }

    private func cell(
        _ kicker: String,
        _ value: String,
        theme: FlightInfoTheme,
        isEstimate: Bool
    ) -> some View {
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
        .padding(.horizontal, 14)
    }

    /// The rule between two cells of one block.
    ///
    /// Cells inside a card rather than cards of their own, which is the change
    /// this block made when it stopped being two rows of tiles: a block is one
    /// thing you can move, colour and switch off, and a block made of four
    /// separate cards is four things wearing the same colour.
    private func divider(_ theme: FlightInfoTheme) -> some View {
        Rectangle()
            .fill(theme.stroke)
            // A height rather than `maxHeight: .infinity`: a rectangle in a row
            // that sizes itself is proposed no height at all and comes back ten
            // points tall, which is a hairline hyphen between two cells.
            .frame(width: 1, height: 32)
    }

    // MARK: What, and where exactly

    /// What the aeroplane is, as rows.
    ///
    /// Label on the left, value on the right, one per line — the shape every
    /// tracker reaches for when the answer is a word rather than a number, and
    /// the right one here: a registration set in the same 19pt as a ground
    /// speed reads as though it were changing.
    private func aircraft(_ theme: FlightInfoTheme) -> some View {
        VStack(spacing: 0) {
            row("TYPE", flight.aircraftName.isEmpty ? "—" : flight.aircraftName, theme: theme)
            row("REGISTRATION", registration.isEmpty ? "—" : registration, theme: theme, mono: true)
            row("OPERATOR", operatorLine, theme: theme)
            row("PILOT", flight.username ?? "—", theme: theme)
        }
        .padding(.vertical, 4)
    }

    private func coordinates(_ theme: FlightInfoTheme) -> some View {
        VStack(spacing: 0) {
            row("LATITUDE", FlightDetailLook.degrees(flight.latitude, positive: "N", negative: "S"), theme: theme, mono: true)
            row("LONGITUDE", FlightDetailLook.degrees(flight.longitude, positive: "E", negative: "W"), theme: theme, mono: true)
        }
        .padding(.vertical, 4)
    }

    private func row(
        _ kicker: String,
        _ value: String,
        theme: FlightInfoTheme,
        mono: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(kicker)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .flightInfoLine(minimumScale: 0.6)
                .motionWords(value)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Lines

    private var operatorLine: String {
        let livery = flight.liveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return livery.isEmpty ? "—" : livery
    }

    private var flownLine: String {
        guard let progress = progress else { return "NOT FILED" }
        return "\(Format.number(progress.flownNM)) NM FLOWN"
    }

    private var remainingLine: String {
        guard let progress = progress else { return "NO ROUTE" }
        return "\(Format.number(progress.remainingNM)) NM TO RUN"
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

// MARK: - Dressing a block

extension View {

    /// A block's card: the window's own surface, plus whatever colour the block
    /// has been given.
    ///
    /// The four treatments are four different places to put a colour rather
    /// than four amounts of it — a rule on the edge, the accents inside, the
    /// whole ground, or none — and only the last two reach the content, which
    /// `FlightInfoTheme.wearing(_:)` has already done by the time this is
    /// applied.
    fileprivate func flightInfoBlock(
        _ block: FlightInfoBlock,
        theme: FlightInfoTheme,
        elevated: Bool = false
    ) -> some View {
        modifier(FlightInfoBlockSurface(block: block, theme: theme, elevated: elevated))
    }
}

private struct FlightInfoBlockSurface: ViewModifier {

    let block: FlightInfoBlock
    let theme: FlightInfoTheme
    let elevated: Bool

    /// The colour this block is actually drawn in: its own, or the window's
    /// accent for a block that has been given a treatment but no colour.
    private var colour: Color { block.colour ?? theme.accent }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch block.tint {
        case .plain:
            content.flightInfoSurface(theme, radius: theme.radiusMedium, elevated: elevated)

        case .line:
            content
                .flightInfoSurface(theme, radius: theme.radiusMedium, elevated: elevated)
                // Inside the card's own clip, so the rule takes the corner
                // rather than crossing it.
                .overlay(alignment: .top) {
                    Rectangle().fill(colour).frame(height: 3)
                }
                .clipShape(shape)

        case .accent:
            content.flightInfoSurface(theme, radius: theme.radiusMedium, elevated: elevated)

        case .filled:
            // A real fill rather than a tinted piece of glass. Glass takes its
            // colour from what is behind it, so a tint on it is a suggestion —
            // and a block somebody has deliberately painted should be the
            // colour they picked on every ground the window has.
            content
                .background { shape.fill(colour.opacity(theme.isLight ? 0.16 : 0.22)) }
                .overlay { shape.strokeBorder(colour.opacity(0.45), lineWidth: 1) }
                .clipShape(shape)
        }
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

    /// Signed, because the sign is the whole of what this number says: a
    /// vertical speed without one is a rate with no direction.
    static func vertical(_ flight: Flight) -> String {
        let feetPerMinute = flight.verticalSpeedFPM
        guard feetPerMinute.isFinite else { return "—" }
        return "\(Format.signed(feetPerMinute)) fpm"
    }

    static func heading(_ flight: Flight) -> String {
        guard flight.heading.isFinite else { return "—" }
        return "\(Format.heading(flight.heading))°"
    }

    /// A coordinate as degrees and decimal minutes, which is how a position is
    /// read out loud and written on a flight plan — 51°28.6'N rather than
    /// 51.4772, which is a number a computer likes and nobody says.
    static func degrees(_ value: Double, positive: String, negative: String) -> String {
        guard value.isFinite else { return "—" }
        let hemisphere = value < 0 ? negative : positive
        let magnitude = abs(value)
        let whole = Int(magnitude)
        let minutes = (magnitude - Double(whole)) * 60
        return String(format: "%d°%04.1f'%@", whole, minutes, hemisphere)
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
