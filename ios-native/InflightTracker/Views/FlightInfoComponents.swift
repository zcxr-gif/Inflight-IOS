import SwiftUI
import UIKit

/// Pieces shared by the peak state and the expanded window, so the two phases
/// can't drift apart as either one is worked on.

// MARK: - Phase chip

/// Flight phase as a neutral pill: a dot and the phase name, no colour coding.
struct FlightPhaseChip: View {

    let phase: FlightPhase
    let theme: FlightInfoTheme
    var elevated: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.phaseAccent(for: phase))
                .frame(width: 5, height: 5)

            Text(phase.rawValue)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .flightInfoSurface(theme, radius: 99, elevated: elevated)
        // Never allowed to shrink: it sits next to a callsign that may be long,
        // and the callsign is the piece that gives way.
        .fixedSize()
    }
}

/// What the pilot is doing, as a pill beside their name.
///
/// The phase chip says what the aircraft is doing; this says whether anyone is
/// flying it. Both are needed: an airframe at cruise reads identically whether
/// it is being hand-flown or sitting on autopilot with nobody watching.
struct PilotStateChip: View {

    let state: PilotState
    let theme: FlightInfoTheme
    var elevated: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.system(size: 7.5, weight: .semibold))

            Text(state.label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(theme.pilotStateAccent(for: state))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .flightInfoSurface(theme, radius: 99, elevated: elevated)
        // Never allowed to shrink: it sits beside a username of arbitrary
        // length, and the username is the piece that gives way.
        .fixedSize()
        .accessibilityLabel("\(state.label). \(state.detail)")
    }
}

// MARK: - Controlled marker

/// Somebody is on frequency here.
///
/// Shared by the airports board and the route card so that "controlled" looks
/// like one thing wherever a field is named. Filled with the accent rather than
/// outlined: in a monochrome window this is the one state worth spending the
/// accent on, because it is the difference between a field you can be talked
/// into and one you cannot.
struct AtcOnlineBadge: View {

    let theme: FlightInfoTheme

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background { Capsule().fill(theme.accent) }
            .accessibilityLabel("Controlled")
    }
}

// MARK: - Route

/// The route card, shared by both phases: endpoints, then the progress bar
/// full width as the divider between them and what has been flown, then the
/// aircraft it is being flown in.
struct RouteCard: View {

    let flight: Flight
    let progress: FlightProgress?
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 24
    var inset: CGFloat = 14

    /// Opens one end of the route as a field of its own.
    ///
    /// Optional because the peak state uses this same card and must not become
    /// tappable: the whole peak is a drag target, and endpoints that could
    /// swallow a drag as a tap would make the window hard to open.
    var onSelectAirport: ((Airport) -> Void)? = nil

    /// Fields with somebody on frequency, so an end of the route can say so.
    ///
    /// Passed in rather than read from the feed here: this card is drawn in the
    /// peak state too, and a component that reached for the feed itself would
    /// re-render both phases on every ATC packet. The peak leaves it empty on
    /// purpose — it is the glance, and this is a detail you open the window for.
    var controlledFields: Set<String> = []

    var body: some View {
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                port(icao: flight.departureIcao, alignment: .leading)
                port(icao: flight.arrivalIcao, alignment: .trailing)
            }

            // Full width, and doing the divider's job: endpoints above, what
            // has actually been flown below.
            RouteTrack(fraction: progress?.fraction ?? 0, theme: theme)

            if let progress = progress {
                HStack(spacing: 8) {
                    MiniStat(
                        label: "FLOWN",
                        value: "\(Format.number(progress.flownNM)) NM",
                        theme: theme
                    )
                    MiniStat(
                        label: "REMAINING",
                        value: "\(Format.number(progress.remainingNM)) NM",
                        theme: theme,
                        alignment: .center
                    )
                    MiniStat(
                        label: "ETE",
                        value: eteLabel,
                        theme: theme,
                        alignment: .trailing
                    )
                }
            }

            Text(aircraftLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .frame(maxWidth: .infinity)
        }
        .padding(inset)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var aircraftLine: String {
        let parts = [flight.aircraftName, flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown aircraft" : parts.joined(separator: " · ")
    }

    private var eteLabel: String {
        guard let ete = progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—"
        }
        return Format.duration(ete)
    }

    @ViewBuilder
    private func port(icao: String?, alignment: HorizontalAlignment) -> some View {
        let airport = AirportStore.shared.airport(icao)

        // Tappable only where there is a field behind the code to open. A route
        // filed to an ICAO the dataset has never heard of still draws — it just
        // isn't a button.
        if let airport = airport, let onSelectAirport = onSelectAirport {
            Button {
                onSelectAirport(airport)
            } label: {
                portLabel(icao: icao, airport: airport, alignment: alignment, isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(airport.icao), \(airport.name). Open this airport.")
        } else {
            portLabel(icao: icao, airport: airport, alignment: alignment, isLink: false)
        }
    }

    private func portLabel(
        icao: String?,
        airport: Airport?,
        alignment: HorizontalAlignment,
        isLink: Bool
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing
        let isControlled = airport.map { controlledFields.contains($0.icao) } ?? false

        return VStack(alignment: alignment, spacing: 4) {
            // Against the code rather than down with the airport's name: "is my
            // destination controlled" is a question about the field, and the
            // name line is already carrying a flag and a chevron.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(code.isEmpty ? "———" : code)
                    .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                if isControlled { AtcOnlineBadge(theme: theme) }
            }

            HStack(spacing: 4) {
                if let flag = airport?.flag, !flag.isEmpty {
                    Text(flag).font(.system(size: 9))
                }
                Text((airport?.name ?? "Unknown").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)

                // The only mark that either end goes anywhere. Sits after the
                // name on both sides rather than mirroring, so the two
                // endpoints read as the same kind of thing rather than as a
                // pair pointing at each other.
                if isLink {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        // Each endpoint takes half the row, so a long airport name can only
        // shrink, never widen the card.
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .contentShape(Rectangle())
    }
}

/// The progress track: filled to `fraction`, with the plane riding the head of
/// the fill. Endpoint dots match the web tracker — filled at the origin, hollow
/// at the destination.
struct RouteTrack: View {

    let fraction: Double
    let theme: FlightInfoTheme
    var planeSize: CGFloat = 11

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.trackFill)
                    .frame(height: 3)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, width * clamped), height: 3)

                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)

                Circle()
                    .strokeBorder(theme.trackFill, lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .offset(x: max(0, width - 6))

                Image(systemName: "airplane")
                    .font(.system(size: planeSize, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    // Kept inside the track so the glyph never clips the card.
                    .offset(x: min(max(0, width * clamped - planeSize / 2), max(0, width - planeSize)))
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
        .frame(height: planeSize + 3)
    }
}

/// Where an aircraft is when there is no route to draw — parked at a gate,
/// taxiing, or airborne with no destination filed.
struct PlaceCard: View {

    let kicker: String
    let symbol: String
    let airport: Airport?
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 22

    /// Opens the field this card names. Optional for the same reason the route
    /// card's is — the peak state draws this too, and everything in the peak
    /// belongs to the drag.
    var onSelectAirport: ((Airport) -> Void)? = nil

    /// Fields with somebody on frequency — see `RouteCard.controlledFields`.
    var controlledFields: Set<String> = []

    var body: some View {
        if let airport = airport, let onSelectAirport = onSelectAirport {
            Button {
                onSelectAirport(airport)
            } label: {
                card(isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kicker) \(airport.icao), \(airport.name). Open this airport.")
        } else {
            card(isLink: false)
        }
    }

    private func card(isLink: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: icaoSize * 0.52, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .frame(width: icaoSize * 1.7, height: icaoSize * 1.7)
                .background(Circle().fill(theme.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(kicker)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(airport?.icao ?? "———")
                        .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    if let airport = airport, controlledFields.contains(airport.icao) {
                        AtcOnlineBadge(theme: theme)
                    }
                }

                HStack(spacing: 4) {
                    if let flag = airport?.flag, !flag.isEmpty {
                        Text(flag).font(.system(size: 9))
                    }
                    Text((airport?.name ?? "Position unknown").uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLink {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Hero

/// The photo header, shared by the full window and the photo peak state.
///
/// Both draw it at the same size from the same rules, so dragging the window
/// open grows what is already on screen instead of swapping one header for
/// another.
struct FlightHero: View {

    let image: UIImage?
    let spriteKey: String
    let contributor: String?
    let theme: FlightInfoTheme
    let width: CGFloat

    /// Takes the photo's own shape where it can, so a fitted photo fills the
    /// header edge to edge instead of sitting between blurred bars. Extremes
    /// are clamped — a panoramic shot may not eat the whole sheet.
    static func height(for width: CGFloat, image: UIImage?) -> CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return min(max(width * 0.56, 190), 250)
        }

        let ratio = image.size.height / image.size.width
        return min(max(width * ratio, 180), 300)
    }

    var body: some View {
        AircraftPhotoImage(
            image: image,
            spriteKey: spriteKey,
            theme: theme,
            iconSize: 64,
            // Airliner photos are wide; filling this frame would cut the nose
            // and tail off, so the whole airframe is fitted onto a blurred
            // copy of itself instead.
            contentMode: .fit
        )
        .frame(width: width, height: Self.height(for: width, image: image))
        .overlay { PhotoScrim() }
        // The photo's own alpha is faded out at the bottom, so it melts into
        // the window's ground rather than ending on a black band.
        .mask { PhotoFadeMask() }
        .overlay(alignment: .topTrailing) { credit }
    }

    @ViewBuilder
    private var credit: some View {
        if let contributor = contributor {
            Text("© \(contributor)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .flightInfoSurface(theme, radius: 6, elevated: true)
                .flightInfoLine(minimumScale: 0.8)
                // Clear of the drag indicator, which floats over the photo.
                .frame(maxWidth: 150, alignment: .trailing)
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
    }
}

/// Callsign, phase, pilot and registration. Sits at the seam under the hero.
struct FlightIdentityBlock: View {

    let flight: Flight
    let registration: String
    let theme: FlightInfoTheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(flight.displayName)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
                }

                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textDim)

                    Text(flight.username ?? "Pilot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()

                    PilotStateChip(state: flight.pilotState, theme: theme, elevated: true)
                }

                // Where the flight is in its day. What it is being flown in
                // lives at the foot of the route card.
                Text(stateLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !registration.isEmpty {
                Text(registration)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .flightInfoSurface(theme, radius: 7, elevated: true)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 2)
    }

    private var stateLine: String {
        let phase = FlightPhase.from(flight)
        let altitude = "\(Format.number(flight.altitudeFeet)) ft"
        let speed = "\(Format.number(flight.groundSpeedKnots)) kts"
        return "\(phase.rawValue.capitalized) · \(altitude) · \(speed)"
    }
}

// MARK: - Telemetry

/// Speed, height and rate, in one row.
///
/// The peak state answered who and where and left out how fast, which is the
/// number you tap an aeroplane to see. It was in the full window only — behind
/// a drag — so the compact bar told you everything about a flight except what
/// it was doing.
///
/// Three, not four: heading is in the full window's grid and is the one of the
/// four you can read off the map, because the icon is already pointing at it.
struct FlightTelemetryStrip: View {

    let flight: Flight
    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 0) {
            cell(
                symbol: "speedometer",
                value: Format.number(flight.groundSpeedKnots),
                unit: "kts"
            )

            divider

            cell(
                symbol: "cloud",
                value: Format.number(flight.altitudeFeet),
                unit: "ft"
            )

            divider

            cell(
                // Points where the aeroplane is going: level flight gets a
                // dash rather than an arrow that has to mean "neither".
                symbol: rateSymbol,
                value: Format.signed(flight.verticalSpeedFPM),
                unit: "fpm"
            )
        }
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }

    private var rateSymbol: String {
        if flight.verticalSpeedFPM > 300 { return "arrow.up.right" }
        if flight.verticalSpeedFPM < -300 { return "arrow.down.right" }
        return "arrow.right"
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(width: 1, height: 22)
    }

    private func cell(symbol: String, value: String, unit: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(unit)")
    }
}

// MARK: - Aircraft photo

/// Community aircraft photo with the sprite placeholder underneath, so the
/// frame is never empty while the request is in flight.
struct AircraftPhotoImage: View {

    let image: UIImage?
    let spriteKey: String
    let theme: FlightInfoTheme
    var iconSize: CGFloat = 44

    /// `.fit` keeps the whole airframe in frame — a blurred, scaled copy of
    /// the same photo fills what is left, so the frame is still edge to edge
    /// but the nose and tail are never cropped off.
    var contentMode: ContentMode = .fit

    var body: some View {
        ZStack {
            if let image = image {
                if contentMode == .fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 18, opaque: true)
                        // Blur samples past the edges, so oversize the backdrop
                        // rather than letting it fade out at the frame.
                        .scaleEffect(1.2)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder
            }
        }
        // Fill the frame, then clip: a resizable image reports its own
        // intrinsic size, which would otherwise widen everything around it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(theme.surfaceFill)

            if let icon = PlaneSprites.shared.icon(forKey: spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.degrees(90))
                    .opacity(0.45)
            }
        }
    }
}

/// Dissolves the bottom of the hero photo into whatever the window is sitting
/// on.
///
/// Used as a mask rather than as a black gradient painted on top: a black fade
/// leaves a dark band that belongs to neither the photo nor the window, while
/// fading the photo's own alpha lets the sheet's blur (or the carbon ground)
/// come through and the two blend into each other.
struct PhotoFadeMask: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.58),
                .init(color: .black.opacity(0.55), location: 0.82),
                .init(color: .black.opacity(0.12), location: 0.95),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Just enough shading under the identity block to keep white text off a
/// bright sky. Fades out again at the very bottom so it can't reintroduce the
/// band the mask is there to avoid.
struct PhotoScrim: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.10), location: 0.45),
                .init(color: .black.opacity(0.30), location: 0.78),
                .init(color: .black.opacity(0.10), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Flown path

/// What the flown path looks like from the side.
///
/// Built from the same breadcrumbs the map draws — the backend's history plus
/// live samples — so the window shows the whole climb, cruise and descent
/// rather than just the current numbers.
struct AltitudeProfileCard: View {

    let points: [TrackPoint]
    let theme: FlightInfoTheme

    private var altitudes: [Double] {
        points.map { $0.altitudeFeet.isFinite ? max($0.altitudeFeet, 0) : 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("FLOWN PROFILE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.textDim)

                Spacer(minLength: 4)

                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }

            profile
                .frame(height: 62)

            HStack(spacing: 8) {
                MiniStat(label: "PEAK", value: "\(Format.number(peakAltitude)) ft", theme: theme)
                MiniStat(
                    label: "TOP SPEED",
                    value: "\(Format.number(topSpeed)) kts",
                    theme: theme,
                    alignment: .center
                )
                MiniStat(
                    label: "TRACKED",
                    value: "\(Format.number(trackedNM)) NM",
                    theme: theme,
                    alignment: .trailing
                )
            }
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var profile: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let values = altitudes
            let ceiling = max(values.max() ?? 1, 1)

            ZStack {
                shape(in: size, values: values, ceiling: ceiling, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.22), theme.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                shape(in: size, values: values, ceiling: ceiling, closed: false)
                    .stroke(theme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
        }
    }

    private func shape(in size: CGSize, values: [Double], ceiling: Double, closed: Bool) -> Path {
        Path { path in
            guard values.count >= 2, size.width > 0, size.height > 0 else { return }

            let step = size.width / CGFloat(values.count - 1)

            func point(_ index: Int) -> CGPoint {
                let normalised = CGFloat(values[index] / ceiling)
                return CGPoint(
                    x: CGFloat(index) * step,
                    // A little headroom so the peak doesn't sit on the edge.
                    y: size.height - normalised * (size.height - 3) - 1
                )
            }

            path.move(to: point(0))
            for index in 1..<values.count { path.addLine(to: point(index)) }

            guard closed else { return }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }

    private var peakAltitude: Double { altitudes.max() ?? 0 }

    private var topSpeed: Double {
        points.map { $0.groundSpeedKnots.isFinite ? $0.groundSpeedKnots : 0 }.max() ?? 0
    }

    /// Length of the path itself, which is longer than the great-circle
    /// distance whenever the aircraft has been vectored around.
    private var trackedNM: Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + FlightProgress.distanceNM(from: pair.0.coordinate, to: pair.1.coordinate)
        }
    }
}

// MARK: - Small readouts

/// Label-over-value readout used for the route's flown / remaining / ETE row.
struct MiniStat: View {

    let label: String
    let value: String
    let theme: FlightInfoTheme
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

// MARK: - Text helpers

extension View {

    /// One line, shrinking before it truncates. Every string in the window is
    /// user or feed supplied, so nothing may push the layout wider.
    func flightInfoLine(minimumScale: CGFloat = 0.7) -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(minimumScale)
            .truncationMode(.tail)
    }
}
