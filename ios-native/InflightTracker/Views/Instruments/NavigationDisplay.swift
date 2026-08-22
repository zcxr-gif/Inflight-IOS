import CoreLocation
import SwiftUI

/// The navigation display: where the aeroplane is going, the route it filed,
/// the fields at either end of it, and what else is in the air nearby.
///
/// Two looks, the same two an airliner offers. ARC puts the aircraft at the
/// bottom and draws the fan in front of it — what you would fly with. ROSE puts
/// it in the middle of a full compass, which is the better one on a tracker,
/// because most of the traffic worth seeing is behind you.
///
/// Everything is drawn heading-up: the compass turns under a fixed pointer, and
/// so does the world. That is why the plan and the traffic are projected here
/// rather than handed in as points — the projection depends on the aircraft's
/// own heading, which changes every packet.
struct NavigationDisplay: View {

    /// A named place worth marking: either end of the route.
    struct Marker: Equatable {
        enum Kind: Equatable { case departure, arrival }

        let name: String
        let coordinate: CLLocationCoordinate2D
        let kind: Kind

        static func == (lhs: Marker, rhs: Marker) -> Bool {
            lhs.name == rhs.name
                && lhs.kind == rhs.kind
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Somebody else, from the same feed the map is drawn from.
    struct Target: Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let altitudeFeet: Double
        let verticalSpeedFPM: Double

        static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.id == rhs.id
                && lhs.altitudeFeet == rhs.altitudeFeet
                && lhs.verticalSpeedFPM == rhs.verticalSpeedFPM
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    let reading: InstrumentReading
    let mode: NavigationDisplayMode
    let rangeNM: Double
    var waypoints: [PlanWaypoint] = []
    var markers: [Marker] = []
    var traffic: [Target] = []

    static let designSize = CGSize(width: 340, height: 340)

    private enum Layout {
        /// Aircraft near the bottom, so the fan in front of it gets the screen.
        static let arcCentre = CGPoint(x: 170, y: 262)
        static let arcRadius: CGFloat = 190

        /// How far either side of the nose the fan reaches. Chosen so the ends
        /// of the arc land just inside the left and right edges.
        static let arcHalfAngle: Double = 62

        static let roseCentre = CGPoint(x: 170, y: 186)
        static let roseRadius: CGFloat = 122
    }

    private var centre: CGPoint {
        mode == .arc ? Layout.arcCentre : Layout.roseCentre
    }

    private var radius: CGFloat {
        mode == .arc ? Layout.arcRadius : Layout.roseRadius
    }

    /// Screen points per nautical mile. The whole projection is this number.
    private var pointsPerNM: CGFloat {
        radius / CGFloat(max(rangeNM, 1))
    }

    var body: some View {
        // The context arrives `inout`, so the transform below applies to the
        // canvas itself rather than to a copy of it.
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = min(
                size.width / Self.designSize.width,
                size.height / Self.designSize.height
            )
            context.translateBy(
                x: (size.width - Self.designSize.width * scale) / 2,
                y: (size.height - Self.designSize.height * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)

            context.fill(
                Path(CGRect(origin: .zero, size: Self.designSize)),
                with: .color(InstrumentPalette.screen)
            )

            drawCompass(in: &context)
            drawRangeRings(in: &context)

            // Everything positional shares one clip, so a route running off the
            // edge stops at the compass rather than at the bezel.
            context.drawLayer { layer in
                layer.clip(to: fieldOfView())
                drawRoute(in: &layer)
                drawMarkers(in: &layer)
                drawTraffic(in: &layer)
            }

            drawTrackLine(in: &context)
            drawAircraft(in: &context)
            drawHeadingPointer(in: &context)
            drawOverlays(in: &context)
        }
        .aspectRatio(Self.designSize.width / Self.designSize.height, contentMode: .fit)
        .background(InstrumentPalette.screen)
        .accessibilityElement()
        .accessibilityLabel("Navigation display")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [
            "Heading \(Format.heading(reading.headingDegrees))",
            "\(Format.number(reading.groundSpeedKnots)) knots ground speed",
            "range \(Int(rangeNM)) miles"
        ]
        if let leg = nextLeg {
            parts.append(
                "next fix \(leg.waypoint.name), \(Format.number(leg.distanceNM)) miles"
            )
        }
        return parts.joined(separator: ", ")
    }

    private var nextLeg: PlanProgress.Leg? {
        PlanProgress.next(in: waypoints, from: reading.coordinate)
    }

    // MARK: - Projection

    /// Where a place on the earth lands on the glass.
    ///
    /// Flat-earth on purpose. Even at the longest range the display offers, 320
    /// miles, the error against a great circle is under a mile — well inside
    /// the width of the line it is drawn with — and a spherical projection per
    /// fix per frame would cost far more than it could possibly buy.
    private func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        let origin = reading.coordinate
        let latitudeScale = cos(origin.latitude * .pi / 180)

        // Nautical miles east and north. A degree of latitude is sixty miles
        // everywhere; a degree of longitude is sixty times the cosine.
        let east = (coordinate.longitude - origin.longitude) * 60 * latitudeScale
        let north = (coordinate.latitude - origin.latitude) * 60

        return offset(east: east, north: north)
    }

    /// Miles east and north, turned into points on a heading-up display.
    private func offset(east: Double, north: Double) -> CGPoint {
        let heading = reading.headingDegrees * .pi / 180
        let x = east * cos(heading) - north * sin(heading)
        let y = -(north * cos(heading) + east * sin(heading))

        return CGPoint(
            x: centre.x + CGFloat(x) * pointsPerNM,
            y: centre.y + CGFloat(y) * pointsPerNM
        )
    }

    /// The compass's inside: a disc in ROSE, a fan in ARC.
    private func fieldOfView() -> Path {
        var path = Path()
        let inner = radius * 0.985

        switch mode {
        case .rose:
            path.addEllipse(in: CGRect(
                x: centre.x - inner,
                y: centre.y - inner,
                width: inner * 2,
                height: inner * 2
            ))
        case .arc:
            // Angles measured from straight up, which is the nose.
            let start = Angle.degrees(-90 - Layout.arcHalfAngle)
            let end = Angle.degrees(-90 + Layout.arcHalfAngle)
            path.move(to: centre)
            path.addArc(center: centre, radius: inner, startAngle: start, endAngle: end, clockwise: false)
            path.closeSubpath()
        }

        return path
    }

    /// Whether a compass bearing is inside the drawn field of view.
    private func isVisible(bearing: Double) -> Bool {
        guard mode == .arc else { return true }
        var relative = bearing - reading.headingDegrees
        while relative > 180 { relative -= 360 }
        while relative < -180 { relative += 360 }
        return abs(relative) <= Layout.arcHalfAngle + 1
    }

    // MARK: - Compass

    private func drawCompass(in context: inout GraphicsContext) {
        let longTick = radius * 0.075
        let shortTick = radius * 0.04

        var outline = Path()
        switch mode {
        case .rose:
            outline.addEllipse(in: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        case .arc:
            outline.addArc(
                center: centre,
                radius: radius,
                startAngle: .degrees(-90 - Layout.arcHalfAngle),
                endAngle: .degrees(-90 + Layout.arcHalfAngle),
                clockwise: false
            )
        }
        context.stroke(outline, with: .color(InstrumentPalette.scale), lineWidth: 1.4)

        for degrees in stride(from: 0, to: 360, by: 5) {
            guard isVisible(bearing: Double(degrees)) else { continue }

            let major = degrees % 10 == 0
            let labelled = degrees % 30 == 0
            let length = major ? longTick : shortTick

            let relative = (Double(degrees) - reading.headingDegrees) * .pi / 180
            let direction = CGPoint(x: CGFloat(sin(relative)), y: CGFloat(-cos(relative)))

            context.strokeLine(
                from: CGPoint(
                    x: centre.x + direction.x * (radius - length),
                    y: centre.y + direction.y * (radius - length)
                ),
                to: CGPoint(x: centre.x + direction.x * radius, y: centre.y + direction.y * radius),
                color: InstrumentPalette.scale,
                width: major ? 1.6 : 1.1
            )

            guard labelled else { continue }

            let label: String
            switch degrees {
            case 0: label = "N"
            case 90: label = "E"
            case 180: label = "S"
            case 270: label = "W"
            default: label = String(degrees / 10)
            }

            let labelRadius = radius - length - 10
            context.drawInstrument(
                label,
                at: CGPoint(
                    x: centre.x + direction.x * labelRadius,
                    y: centre.y + direction.y * labelRadius
                ),
                size: 11,
                color: InstrumentPalette.scale
            )
        }
    }

    private func drawRangeRings(in context: inout GraphicsContext) {
        for fraction in [0.25, 0.5, 0.75] {
            let ringRadius = radius * CGFloat(fraction)

            var ring = Path()
            switch mode {
            case .rose:
                ring.addEllipse(in: CGRect(
                    x: centre.x - ringRadius,
                    y: centre.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
            case .arc:
                ring.addArc(
                    center: centre,
                    radius: ringRadius,
                    startAngle: .degrees(-90 - Layout.arcHalfAngle),
                    endAngle: .degrees(-90 + Layout.arcHalfAngle),
                    clockwise: false
                )
            }

            context.stroke(
                ring,
                with: .color(InstrumentPalette.scaleDim.opacity(fraction == 0.5 ? 0.75 : 0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 5])
            )

            // Only the middle ring is worth a number; three of them would be
            // three numbers to read past.
            guard fraction == 0.5 else { continue }
            context.drawInstrument(
                Self.rangeText(rangeNM / 2),
                at: CGPoint(x: centre.x - ringRadius + 2, y: centre.y - 8),
                size: 9.5,
                color: InstrumentPalette.range,
                anchor: .leading
            )
        }
    }

    // MARK: - The filed route

    private func drawRoute(in context: inout GraphicsContext) {
        guard !waypoints.isEmpty else { return }

        let points = waypoints.map { project($0.coordinate) }

        if points.count >= 2 {
            var route = Path()
            route.move(to: points[0])
            for point in points.dropFirst() { route.addLine(to: point) }

            context.stroke(
                route,
                with: .color(InstrumentPalette.live),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )
        }

        let active = nextLeg?.waypoint

        for (waypoint, point) in zip(waypoints, points) {
            // A fix twenty screens away is a diamond nobody can see and a label
            // clipped to nothing; skipping it keeps the frame cheap on a plan
            // with sixty fixes in it.
            guard abs(point.x - centre.x) < 900, abs(point.y - centre.y) < 900 else { continue }

            let isActive = waypoint == active
            let colour = isActive ? InstrumentPalette.range : InstrumentPalette.live

            context.diamond(at: point, radius: 5, color: colour, filled: false, width: 1.8)
            context.drawInstrument(
                waypoint.name,
                at: CGPoint(x: point.x + 9, y: point.y - 8),
                size: 9,
                color: colour,
                anchor: .leading
            )
        }
    }

    private func drawMarkers(in context: inout GraphicsContext) {
        for marker in markers {
            let point = project(marker.coordinate)
            guard abs(point.x - centre.x) < 900, abs(point.y - centre.y) < 900 else { continue }

            // Where it is going reads brighter than where it came from: one
            // of the two is still ahead of the aeroplane.
            let colour = marker.kind == .arrival
                ? InstrumentPalette.range
                : InstrumentPalette.scaleDim

            // A runway pictogram: the shape a field is drawn as on every
            // navigation display there has ever been.
            var glyph = Path()
            glyph.addEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            glyph.move(to: CGPoint(x: point.x - 8, y: point.y))
            glyph.addLine(to: CGPoint(x: point.x + 8, y: point.y))
            context.stroke(glyph, with: .color(colour), lineWidth: 1.6)

            context.drawInstrument(
                marker.name,
                at: CGPoint(x: point.x + 11, y: point.y + 8),
                size: 9.5,
                color: colour,
                anchor: .leading
            )
        }
    }

    // MARK: - Traffic

    private func drawTraffic(in context: inout GraphicsContext) {
        for target in traffic {
            let point = project(target.coordinate)
            guard abs(point.x - centre.x) < 600, abs(point.y - centre.y) < 600 else { continue }

            let difference = target.altitudeFeet - reading.altitudeFeet
            // The feed reads its numbers leniently, so a height can arrive as
            // something that is not one. Skipped rather than drawn at zero,
            // which would claim co-altitude.
            guard difference.isFinite else { continue }

            // Anything within a couple of thousand feet is worth picking out,
            // which is the only bit of collision awareness a tracker can
            // honestly offer.
            let near = abs(difference) < 2000
            let colour = near ? InstrumentPalette.caution : InstrumentPalette.traffic

            context.diamond(at: point, radius: 4.5, color: colour, filled: near, width: 1.5)

            // Hundreds of feet, signed, the way TCAS writes it.
            let hundreds = Int((difference / 100).rounded())
            let label = hundreds >= 0 ? "+\(hundreds)" : "\(hundreds)"
            context.drawInstrument(
                label,
                at: CGPoint(x: point.x + 7, y: point.y - 7),
                size: 8,
                color: colour,
                anchor: .leading
            )

            guard abs(target.verticalSpeedFPM) > 500 else { continue }
            context.drawInstrument(
                target.verticalSpeedFPM > 0 ? "↑" : "↓",
                at: CGPoint(x: point.x + 7, y: point.y + 5),
                size: 8,
                color: colour,
                anchor: .leading
            )
        }
    }

    // MARK: - The aeroplane

    /// Where the aircraft is actually going, when that is not where it is
    /// pointing. Only the simulator ever reports both, so on most aircraft this
    /// sits exactly on the nose — which is itself the honest answer.
    private func drawTrackLine(in context: inout GraphicsContext) {
        var relative = reading.trackDegrees - reading.headingDegrees
        while relative > 180 { relative -= 360 }
        while relative < -180 { relative += 360 }

        let radians = relative * .pi / 180
        let inner = radius * 0.9

        context.strokeLine(
            from: centre,
            to: CGPoint(
                x: centre.x + CGFloat(sin(radians)) * inner,
                y: centre.y - CGFloat(cos(radians)) * inner
            ),
            color: InstrumentPalette.live.opacity(0.5),
            width: 1.4,
            dash: [5, 6]
        )
    }

    private func drawAircraft(in context: inout GraphicsContext) {
        let scale: CGFloat = mode == .arc ? 1.35 : 1.0
        let span = 14 * scale
        let tail = 9 * scale
        let tailSpan = 5 * scale

        var glyph = Path()
        glyph.move(to: CGPoint(x: centre.x, y: centre.y - span))
        glyph.addLine(to: CGPoint(x: centre.x, y: centre.y + span))
        glyph.move(to: CGPoint(x: centre.x - span, y: centre.y))
        glyph.addLine(to: CGPoint(x: centre.x + span, y: centre.y))
        glyph.move(to: CGPoint(x: centre.x - tailSpan, y: centre.y + tail))
        glyph.addLine(to: CGPoint(x: centre.x + tailSpan, y: centre.y + tail))

        context.stroke(
            glyph,
            with: .color(InstrumentPalette.aircraft),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )
    }

    private func drawHeadingPointer(in context: inout GraphicsContext) {
        var pointer = Path()
        let tip = centre.y - radius - 2
        pointer.move(to: CGPoint(x: centre.x, y: tip))
        pointer.addLine(to: CGPoint(x: centre.x - 7, y: tip - 11))
        pointer.addLine(to: CGPoint(x: centre.x + 7, y: tip - 11))
        pointer.closeSubpath()
        context.fill(pointer, with: .color(InstrumentPalette.aircraft))
    }

    // MARK: - Corners

    private func drawOverlays(in context: inout GraphicsContext) {
        let left: CGFloat = 12
        let right = Self.designSize.width - 12
        var line: CGFloat = 20

        context.drawInstrument(
            "GS",
            at: CGPoint(x: left, y: line),
            size: 10,
            color: InstrumentPalette.scaleDim,
            anchor: .leading
        )
        context.drawInstrument(
            Self.padded(reading.groundSpeedKnots),
            at: CGPoint(x: left + 26, y: line),
            size: 12,
            color: InstrumentPalette.live,
            anchor: .leading
        )

        line += 16
        context.drawInstrument(
            "TAS",
            at: CGPoint(x: left, y: line),
            size: 10,
            color: InstrumentPalette.scaleDim,
            anchor: .leading
        )
        context.drawInstrument(
            reading.trueAirspeedKnots.map(Self.padded) ?? "---",
            at: CGPoint(x: left + 26, y: line),
            size: 12,
            color: reading.trueAirspeedKnots == nil
                ? InstrumentPalette.scaleDim
                : InstrumentPalette.live,
            anchor: .leading
        )

        if let direction = reading.windDirectionDegrees, let speed = reading.windSpeedKnots {
            line += 18
            context.drawInstrument(
                "\(Format.heading(direction))°/\(Int(speed.rounded()))",
                at: CGPoint(x: left, y: line),
                size: 10,
                color: InstrumentPalette.live,
                anchor: .leading
            )
            drawWindArrow(
                in: &context,
                at: CGPoint(x: left + 62, y: line),
                directionDegrees: direction
            )
        }

        // The fix being flown to, top right, in the order an ND lists it:
        // which one, how long, how far.
        var rightLine: CGFloat = 20
        if let leg = nextLeg {
            context.drawInstrument(
                leg.waypoint.name,
                at: CGPoint(x: right, y: rightLine),
                size: 12,
                color: InstrumentPalette.live,
                anchor: .trailing
            )

            rightLine += 16
            let ete = leg.timeToRun(groundSpeedKnots: reading.groundSpeedKnots)
            context.drawInstrument(
                ete.map(Format.duration) ?? "--:--",
                at: CGPoint(x: right, y: rightLine),
                size: 11,
                color: InstrumentPalette.scale,
                anchor: .trailing
            )

            rightLine += 15
            context.drawInstrument(
                "\(Self.rangeText(leg.distanceNM)) NM",
                at: CGPoint(x: right, y: rightLine),
                size: 11,
                color: InstrumentPalette.range,
                anchor: .trailing
            )
        } else {
            context.drawInstrument(
                waypoints.isEmpty ? "NO PLAN FILED" : "PLAN ENDED",
                at: CGPoint(x: right, y: rightLine),
                size: 10,
                color: InstrumentPalette.scaleDim,
                anchor: .trailing
            )
        }

        let foot = Self.designSize.height - 14
        context.drawInstrument(
            mode.label,
            at: CGPoint(x: left, y: foot),
            size: 10,
            color: InstrumentPalette.scaleDim,
            anchor: .leading
        )
        context.drawInstrument(
            "\(Self.rangeText(rangeNM)) NM",
            at: CGPoint(x: right, y: foot),
            size: 10,
            color: InstrumentPalette.range,
            anchor: .trailing
        )
    }

    /// Which way the wind is going, relative to the nose — so it points down
    /// the screen when it is on the tail.
    private func drawWindArrow(
        in context: inout GraphicsContext,
        at point: CGPoint,
        directionDegrees: Double
    ) {
        // Wind is reported as the direction it comes *from*; the arrow shows
        // where it is blowing *to*, which is the other way round.
        let relative = (directionDegrees + 180 - reading.headingDegrees) * .pi / 180
        let along = CGPoint(x: CGFloat(sin(relative)), y: CGFloat(-cos(relative)))
        let across = CGPoint(x: -along.y, y: along.x)
        let half: CGFloat = 8

        let tail = CGPoint(x: point.x - along.x * half, y: point.y - along.y * half)
        let head = CGPoint(x: point.x + along.x * half, y: point.y + along.y * half)

        var arrow = Path()
        arrow.move(to: tail)
        arrow.addLine(to: head)
        for side in [CGFloat(-1), CGFloat(1)] {
            arrow.move(to: head)
            arrow.addLine(to: CGPoint(
                x: head.x - along.x * 5 + across.x * 4 * side,
                y: head.y - along.y * 5 + across.y * 4 * side
            ))
        }

        context.stroke(
            arrow,
            with: .color(InstrumentPalette.live),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
    }

    // MARK: - Numbers

    /// Three digits, zero padded, the way every speed on an ND is written.
    private static func padded(_ value: Double) -> String {
        guard value.isFinite else { return "---" }
        return String(format: "%03d", max(0, min(Int(value.rounded()), 999)))
    }

    /// A distance with one decimal under ten miles and none above, so a fix
    /// two miles out reads 1.8 rather than 2.
    private static func rangeText(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value < 10
            ? String(format: "%.1f", value)
            : String(Int(value.rounded()))
    }
}
