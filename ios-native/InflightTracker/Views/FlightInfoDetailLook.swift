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
/// Dark and full-width in both, because it is the one part of this look that
/// has to read at arm's length — it is what you check when you have glanced at
/// an aeroplane and want to know whose it is.
struct FlightDetailOperatorBar: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// The callsign size. The peek runs smaller than the open window.
    var callsignSize: CGFloat = 19

    /// Chips beside the callsign — the tail and the type code. Off in the peek,
    /// which says both along its foot instead and has no room for them twice.
    var showsChips: Bool = false

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

                if showsChips {
                    if !registration.isEmpty { chip(registration) }
                    if !typeCode.isEmpty { chip(typeCode) }
                }

                Spacer(minLength: 6)

                FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
            }

            HStack(spacing: 6) {
                Text(operatorLine)
                    .font(.system(size: 11.5, weight: .semibold))
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .flightInfoSurface(theme, radius: 5, elevated: true)
            .fixedSize()
    }
}

// MARK: - The peek

/// The bar this look peeks as: everything on one face, before the window is
/// opened.
///
/// Four bands — who, where, how, and what — laid out so the eye can take the
/// whole thing in one go rather than reading it. The photograph is small and to
/// the right of the operator's bar, which is the one place on a bar this dense
/// where a picture does not push a number off the end.
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
        VStack(spacing: 0) {
            head
            hairline
            middle
            hairline
            foot
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: Who

    private var head: some View {
        HStack(spacing: 10) {
            FlightDetailOperatorBar(flight: flight, theme: theme, callsignSize: 19)

            thumbnail
                .frame(width: 104, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .strokeBorder(theme.strokeStrong, lineWidth: 1)
                }
                .padding(.trailing, 11)
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

    /// The route on the left, the two live numbers on the right.
    ///
    /// Side by side rather than stacked because they answer at different
    /// speeds: the route is what the flight IS and barely changes, the numbers
    /// are what it is doing and change every packet. Putting the moving half in
    /// its own column stops the whole bar from looking restless.
    private var middle: some View {
        HStack(alignment: .top, spacing: 0) {
            route
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)

            Rectangle()
                .fill(theme.stroke)
                .frame(width: 1)

            readouts
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(width: 132, alignment: .leading)
        }
    }

    @ViewBuilder
    private var route: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                end(progress?.departure, icao: flight.departureIcao, alignment: .leading)

                Image(systemName: "airplane")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.top, 5)
                    .accessibilityHidden(true)

                end(progress?.arrival, icao: flight.arrivalIcao, alignment: .trailing)
            }

            if let progress = progress {
                RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 9)

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
    }

    private func end(
        _ airport: Airport?,
        icao: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        return VStack(alignment: alignment, spacing: 1) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Not filed").uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 9) {
            readout("CALIBRATED ALT.", FlightDetailLook.altitude(flight))
            readout("GROUND SPEED", FlightDetailLook.speed(flight))
        }
    }

    private func readout(_ kicker: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kicker)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)

            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
                .motionWords(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What

    private var foot: some View {
        HStack(spacing: 8) {
            Text(flight.aircraftName.isEmpty ? "Unknown type" : flight.aircraftName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.6)

            Spacer(minLength: 6)

            Text(registration.isEmpty ? "REG —" : "REG: \(registration)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .fixedSize()
                // Blank until the photo lookup finds a tail number, which lands
                // a second after the window opens.
                .motionWords(registration)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
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

    private var hairline: some View {
        Rectangle().fill(theme.stroke).frame(height: 1)
    }
}

// MARK: - The open window's head

/// What replaces the identity block when this look is chosen and the window is
/// open.
///
/// The photograph across the top at the size it wants to be, the operator's bar
/// over it, both ends of the route under it, and the live numbers beside them.
/// The window's own cards follow underneath, unchanged — this replaces the head
/// of the window, not the window.
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
        VStack(spacing: 0) {
            FlightDetailOperatorBar(
                flight: flight,
                theme: theme,
                callsignSize: 24,
                showsChips: true,
                registration: registration
            )

            FlightHero(
                image: image,
                spriteKey: flight.spriteKey,
                contributor: contributor,
                theme: theme,
                width: width,
                photos: photos,
                isAutoplaying: isAutoplaying
            )

            route

            hairline

            numbers
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: Where

    private var route: some View {
        HStack(alignment: .top, spacing: 10) {
            end(progress?.departure, icao: flight.departureIcao, alignment: .leading)

            Image(systemName: "airplane")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.top, 8)
                .accessibilityHidden(true)

            end(progress?.arrival, icao: flight.arrivalIcao, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func end(
        _ airport: Airport?,
        icao: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        let block = VStack(alignment: alignment, spacing: 3) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text((airport?.name ?? "Not filed").uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
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

    // MARK: How

    /// The bar, the two distances either side of it, and the four numbers
    /// under that — height and speed on the left, the two times on the right.
    private var numbers: some View {
        VStack(spacing: 11) {
            if let progress = progress {
                VStack(spacing: 8) {
                    RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 12)

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

            HStack(spacing: 8) {
                cell("CALIBRATED ALT.", FlightDetailLook.altitude(flight), isEstimate: false)
                cell("GROUND SPEED", FlightDetailLook.speed(flight), isEstimate: false)
            }

            HStack(spacing: 8) {
                cell("DEPARTED", departedValue, isEstimate: false)
                cell("ARRIVING", arrivingValue, isEstimate: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
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
        .flightInfoSurface(theme, radius: theme.radiusSmall, elevated: true)
    }

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

    private var hairline: some View {
        Rectangle().fill(theme.stroke).frame(height: 1)
    }
}

// MARK: - Shared arithmetic

/// The bits both states say the same way, so they cannot drift apart.
enum FlightDetailLook {

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
        return "\(Format.number(knots)) kt"
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
