import SwiftUI

/// The full window's other head: a departures board.
///
/// ## What this is instead of
///
/// The window's own layout is a stack of cards, each one a subject, and it is
/// the right shape for reading about an aeroplane you are already watching.
/// It is the wrong shape for the other thing people open a tracker for — is
/// this flight going to be late — because the answer to that is spread across
/// three cards and a scroll.
///
/// A board puts it above the fold: both ends of the route in the size the
/// airport prints them, the time it left and the time it gets in beside each
/// other, and one bar with how far is behind and how far is left. Then the
/// cards, unchanged, underneath — this replaces the head of the window rather
/// than the window.
///
/// ## What it does not do
///
/// It does not invent a schedule. Every other tracker's board has four times on
/// it: scheduled and actual out, scheduled and estimated in. Two of those come
/// from an airline's published timetable, and the live feed this app reads is a
/// simulator's — there is no timetable behind it and there is no honest way to
/// draw one. So the board carries the two times that are real: when the flight
/// was first seen moving, and when it arrives at the speed it is doing now. The
/// labels say which is measured and which is an estimate, and the estimate says
/// so again by being the one that moves.
struct FlightInfoBoard: View {

    let flight: Flight
    let registration: String
    let theme: FlightInfoTheme

    /// Filled when both ends of the route are known, which is the only case
    /// this whole layout is about.
    let progress: FlightProgress?

    /// When the flight was first seen. The backend's history reaches back to
    /// the push-back for most flights, so this is usually the real off-blocks
    /// time rather than the moment the app happened to open.
    let began: Date?

    /// Opening one end of the route. Nil in a preview, where there is nothing
    /// behind the codes to open.
    var onSelectAirport: ((Airport) -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            identity
            route
            times
            distance
        }
    }

    // MARK: - Who

    /// The callsign, what it is flying, and whose livery it wears.
    ///
    /// The chips carry the two things a board always has beside a flight
    /// number and this app can actually answer: the tail, and the type.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(flight.displayName)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .flightInfoLine(minimumScale: 0.6)

                if !registration.isEmpty { chip(registration) }

                if !typeCode.isEmpty { chip(typeCode) }

                Spacer(minLength: 6)

                FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
            }

            // The operator on the left the way a board prints it, and who is
            // actually flying it on the right — which is the half a board at
            // an airport has no equivalent of and this app cannot leave out.
            HStack(spacing: 8) {
                Text(operatorLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.7)

                Spacer(minLength: 6)

                FlightPilotBadge(username: flight.username, side: 20)

                PilotStateChip(state: flight.pilotState, theme: theme, elevated: true)
            }
        }
        .padding(.horizontal, 2)
    }

    /// The livery, or the pilot's name when the aircraft is in no airline's
    /// paint at all — a board with a blank line where the operator goes reads
    /// as missing data rather than as a private aeroplane.
    private var operatorLine: String {
        let livery = flight.liveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !livery.isEmpty { return livery }
        return flight.username ?? "Private flight"
    }

    /// A short type code for the chip, from the aircraft's own name.
    ///
    /// The feed sends "Boeing 777-300ER", which is what the details card
    /// prints in full. Up here there is room for a badge, so the manufacturer
    /// is dropped and the model kept — the same trade a board makes.
    private var typeCode: String {
        let name = flight.aircraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        let manufacturers = ["Boeing", "Airbus", "Embraer", "Bombardier", "Cessna", "McDonnell Douglas"]
        for maker in manufacturers where name.hasPrefix(maker) {
            let rest = name.dropFirst(maker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? name : rest
        }
        return name
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .flightInfoSurface(theme, radius: 6, elevated: true)
            .fixedSize()
    }

    // MARK: - Where

    /// Both ends, at the size an airport prints them.
    ///
    /// The aeroplane between them is the same glyph the map draws and it points
    /// the way the route runs, which is the one piece of this that says the
    /// flight is going *from* the left *to* the right rather than simply
    /// touching two airports.
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
        .flightInfoSurface(theme, radius: theme.radiusMedium)
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

    // MARK: - When

    /// Off blocks on the left, on blocks on the right, each with the plain
    /// English under the clock.
    private var times: some View {
        HStack(spacing: 10) {
            timeTile(
                kicker: "DEPARTED",
                clock: began.map(Self.clock) ?? "—",
                caption: began.map { Self.relative(since: $0) } ?? "Not seen leaving",
                isEstimate: false
            )

            timeTile(
                kicker: "ARRIVING",
                clock: arrival.map(Self.clock) ?? "—",
                caption: remaining.map { "in \(Format.duration($0))" } ?? "No estimate",
                isEstimate: true
            )
        }
    }

    /// How long is left at the speed the aircraft is doing now, or nil when it
    /// is too slow — or has nowhere filed — for the arithmetic to mean
    /// anything.
    private var remaining: TimeInterval? {
        progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)
    }

    private var arrival: Date? {
        remaining.map { Date().addingTimeInterval($0) }
    }

    private func timeTile(
        kicker: String,
        clock: String,
        caption: String,
        isEstimate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                // The mark that says this one is arithmetic rather than
                // observation. Every board has it, and it is the difference
                // between a time and a promise.
                if isEstimate {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 5, height: 5)
                }

                Text(kicker)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }

            Text(clock)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
                .motionWords(clock)

            Text(caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .motionWords(caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: - How far

    /// The bar, and the two distances either side of it.
    private var distance: some View {
        VStack(spacing: 9) {
            RouteTrack(fraction: progress?.fraction ?? 0, theme: theme, planeSize: 12)

            HStack(spacing: 8) {
                Text(flown)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
                    .motionWords(flown)

                Spacer(minLength: 6)

                Text(toRun)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
                    .motionWords(toRun)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var flown: String {
        guard let progress = progress else { return "—" }
        return "\(Format.number(progress.flownNM)) NM FLOWN"
    }

    private var toRun: String {
        guard let progress = progress else { return "—" }
        return "\(Format.number(progress.remainingNM)) NM TO RUN"
    }

    // MARK: - Clocks

    /// The device's own clock, and deliberately not the field's.
    ///
    /// A real board prints local times at both ends, and doing that here would
    /// mean a timezone for every airport in the dataset — which the dataset
    /// does not carry. Guessing one from a longitude is wrong by an hour
    /// wherever anybody observes daylight saving, and an arrival time that is
    /// quietly an hour out is worse than one that is honestly in your own
    /// clock. Both times are yours; both are labelled the same way.
    private static func clock(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// Built once. `setLocalizedDateFormatFromTemplate` walks the locale's
    /// date-format catalogue, and this is read twice on every redraw of an open
    /// window — which is every packet.
    ///
    /// The template rather than a fixed format, so somebody who reads a
    /// twenty-four hour clock gets one.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private static func relative(since date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed.isFinite, elapsed >= 60 else { return "Just now" }
        return "\(Format.duration(elapsed)) ago"
    }
}
