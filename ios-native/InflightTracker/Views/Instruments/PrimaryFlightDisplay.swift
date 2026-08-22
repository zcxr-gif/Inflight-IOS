import SwiftUI

/// The primary flight display: attitude, speed, height, vertical speed and
/// heading, laid out the way every glass cockpit lays them out.
///
/// Drawn into a `Canvas` at a fixed design size and scaled to whatever it is
/// given, so every measurement below is in one coordinate system and the
/// instrument is the same instrument in a card as it is full screen.
///
/// ## What is measured and what is worked out
///
/// Speed, height, vertical speed and heading are reported. Attitude usually is
/// not: only a pilot broadcasting through Infinite Flight Connect sends real
/// pitch and bank, and for everyone else the horizon is derived — the flight
/// path angle from vertical speed against ground speed, and the bank a
/// coordinated turn at the observed turn rate would need. The display says
/// which, in the footer, every time. An artificial horizon that quietly
/// presents arithmetic as telemetry is the one version of this worth refusing
/// to build.
struct PrimaryFlightDisplay: View {

    let reading: InstrumentReading

    /// Everything below is in these units. 360 across is wide enough for the
    /// two tapes and the ball at readable sizes, and the aspect fits a card
    /// without letterboxing.
    static let designSize = CGSize(width: 360, height: 280)

    private enum Layout {
        /// The ball and the three tapes share a top and a bottom, so the
        /// horizon, the current speed and the current height are all on one
        /// line across the display — which is the line the eye scans.
        static let ball = CGRect(x: 66, y: 32, width: 196, height: 172)
        static let speed = CGRect(x: 10, y: 32, width: 50, height: 172)
        static let altitude = CGRect(x: 268, y: 32, width: 48, height: 172)
        static let verticalSpeed = CGRect(x: 320, y: 32, width: 30, height: 172)
        static let heading = CGRect(x: 66, y: 214, width: 196, height: 26)

        /// Pixels per degree of pitch: about eighteen degrees either side of
        /// the horizon, which covers everything an airliner does.
        static let pitchScale: CGFloat = 4.7

        /// Pixels per knot and per foot on the two tapes.
        static let speedScale: CGFloat = 2.15
        static let altitudeScale: CGFloat = 0.086

        /// Pixels per degree along the heading tape.
        static let headingScale: CGFloat = 196.0 / 60.0

        /// Radius of the bank scale, measured from the middle of the ball.
        static let bankRadius: CGFloat = 74
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

            drawHeader(in: &context)
            drawAttitude(in: &context)
            drawSpeedTape(in: &context)
            drawAltitudeTape(in: &context)
            drawVerticalSpeed(in: &context)
            drawHeadingTape(in: &context)
            drawFooter(in: &context)
        }
        .aspectRatio(Self.designSize.width / Self.designSize.height, contentMode: .fit)
        .background(InstrumentPalette.screen)
        .accessibilityElement()
        .accessibilityLabel("Primary flight display")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let bank = Int(reading.bankDegrees.rounded())
        let bankWord = bank == 0 ? "wings level" : "\(abs(bank)) degrees \(bank > 0 ? "right" : "left")"
        return """
        \(Format.number(reading.altitudeFeet)) feet, \
        \(Format.number(reading.speedKnots)) knots, \
        heading \(Format.heading(reading.headingDegrees)), \
        \(bankWord)
        """
    }

    // MARK: - Header

    private func drawHeader(in context: inout GraphicsContext) {
        context.drawInstrument(
            reading.callsign,
            at: CGPoint(x: 10, y: 11),
            size: 11,
            color: InstrumentPalette.scale,
            anchor: .leading
        )

        context.drawInstrument(
            reading.isOnGround ? "GROUND" : reading.phase.rawValue,
            at: CGPoint(x: 350, y: 11),
            size: 10,
            color: InstrumentPalette.live,
            anchor: .trailing
        )
    }

    // MARK: - Attitude

    private func drawAttitude(in context: inout GraphicsContext) {
        let rect = Layout.ball
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let clip = Path(roundedRect: rect, cornerRadius: 8)

        // The world. Rotated opposite to the bank — roll right and the horizon
        // rolls left, which is the whole of what "inside out" means — then
        // slid down by the pitch, so nose up puts the horizon low.
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.translateBy(x: centre.x, y: centre.y)
            layer.rotate(by: .degrees(-reading.bankDegrees))
            layer.translateBy(x: 0, y: CGFloat(reading.pitchDegrees) * Layout.pitchScale)

            // Wide enough that no rotation or pitch can bring an edge on
            // screen: the diagonal of the ball is under 270.
            let span: CGFloat = 460
            layer.fill(
                Path(CGRect(x: -span, y: -span, width: span * 2, height: span)),
                with: .color(InstrumentPalette.sky)
            )
            layer.fill(
                Path(CGRect(x: -span, y: 0, width: span * 2, height: span)),
                with: .color(InstrumentPalette.ground)
            )
            layer.strokeLine(
                from: CGPoint(x: -span, y: 0),
                to: CGPoint(x: span, y: 0),
                color: InstrumentPalette.scale,
                width: 1.8
            )

            drawPitchLadder(in: &layer)
        }

        // The bank scale is fixed to the glass...
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.translateBy(x: centre.x, y: centre.y)
            drawBankScale(in: &layer)
        }

        // ...and the pointer is fixed to the horizon, so it reads the bank off
        // that scale without either of them being told what the number is.
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.translateBy(x: centre.x, y: centre.y)
            layer.rotate(by: .degrees(-reading.bankDegrees))

            let tip = Layout.bankRadius - 5
            var pointer = Path()
            pointer.move(to: CGPoint(x: 0, y: -tip))
            pointer.addLine(to: CGPoint(x: -6, y: -tip + 10))
            pointer.addLine(to: CGPoint(x: 6, y: -tip + 10))
            pointer.closeSubpath()
            layer.fill(pointer, with: .color(InstrumentPalette.aircraft))
        }

        drawAircraftSymbol(in: &context, centre: centre)

        context.stroke(clip, with: .color(InstrumentPalette.scaleDim), lineWidth: 1)
    }

    /// The ladder, in the horizon's own frame: five-degree rungs, ten-degree
    /// rungs numbered at both ends.
    private func drawPitchLadder(in context: inout GraphicsContext) {
        for degrees in stride(from: -30, through: 30, by: 5) where degrees != 0 {
            let y = -CGFloat(degrees) * Layout.pitchScale
            let major = degrees % 10 == 0
            let halfWidth: CGFloat = major ? 27 : 13

            context.strokeLine(
                from: CGPoint(x: -halfWidth, y: y),
                to: CGPoint(x: halfWidth, y: y),
                color: InstrumentPalette.scale,
                width: major ? 1.6 : 1.2
            )

            guard major else { continue }
            let label = String(abs(degrees))
            context.drawInstrument(
                label,
                at: CGPoint(x: -halfWidth - 5, y: y),
                size: 8,
                color: InstrumentPalette.scale,
                anchor: .trailing
            )
            context.drawInstrument(
                label,
                at: CGPoint(x: halfWidth + 5, y: y),
                size: 8,
                color: InstrumentPalette.scale,
                anchor: .leading
            )
        }
    }

    private func drawBankScale(in context: inout GraphicsContext) {
        let radius = Layout.bankRadius

        for degrees in [-60.0, -45, -30, -20, -10, 10, 20, 30, 45, 60] {
            let radians = degrees * .pi / 180
            let direction = CGPoint(x: CGFloat(sin(radians)), y: CGFloat(-cos(radians)))
            let length: CGFloat = abs(degrees) == 30 || abs(degrees) == 60 ? 9 : 6

            context.strokeLine(
                from: CGPoint(x: direction.x * radius, y: direction.y * radius),
                to: CGPoint(
                    x: direction.x * (radius + length),
                    y: direction.y * (radius + length)
                ),
                color: InstrumentPalette.scale,
                width: abs(degrees) == 30 ? 2 : 1.4
            )
        }

        // Wings level, marked by the one thing on the scale that is a shape
        // rather than a tick.
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: -radius - 11))
        zero.addLine(to: CGPoint(x: -6, y: -radius - 1))
        zero.addLine(to: CGPoint(x: 6, y: -radius - 1))
        zero.closeSubpath()
        context.stroke(
            zero,
            with: .color(InstrumentPalette.scale),
            style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)
        )
    }

    /// The aeroplane itself: fixed to the glass, because it is the one thing on
    /// the display that never moves.
    private func drawAircraftSymbol(in context: inout GraphicsContext, centre: CGPoint) {
        let colour = InstrumentPalette.aircraft

        var wings = Path()
        // Left wing, elbowed down at the inboard end.
        wings.move(to: CGPoint(x: centre.x - 48, y: centre.y))
        wings.addLine(to: CGPoint(x: centre.x - 20, y: centre.y))
        wings.addLine(to: CGPoint(x: centre.x - 20, y: centre.y + 8))
        // Right wing, mirrored.
        wings.move(to: CGPoint(x: centre.x + 48, y: centre.y))
        wings.addLine(to: CGPoint(x: centre.x + 20, y: centre.y))
        wings.addLine(to: CGPoint(x: centre.x + 20, y: centre.y + 8))

        context.stroke(
            wings,
            with: .color(colour),
            style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter)
        )

        context.fill(
            Path(CGRect(x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5)),
            with: .color(colour)
        )
    }

    // MARK: - Speed

    private func drawSpeedTape(in context: inout GraphicsContext) {
        let rect = Layout.speed
        let speed = max(reading.speedKnots, 0)

        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(InstrumentPalette.tapeGround)
        )

        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect, cornerRadius: 4))

            // Whole tens either side of the current speed, plus a margin so a
            // tick never pops in at the edge.
            let lowest = Int(((speed - 50) / 10).rounded(.down)) * 10
            let highest = Int(((speed + 50) / 10).rounded(.up)) * 10

            for value in stride(from: lowest, through: highest, by: 10) where value >= 0 {
                let y = rect.midY - CGFloat(Double(value) - speed) * Layout.speedScale
                let labelled = value % 20 == 0

                layer.strokeLine(
                    from: CGPoint(x: rect.maxX - (labelled ? 10 : 6), y: y),
                    to: CGPoint(x: rect.maxX, y: y),
                    color: InstrumentPalette.scale,
                    width: 1.3
                )

                guard labelled else { continue }
                layer.drawInstrument(
                    String(value),
                    at: CGPoint(x: rect.maxX - 13, y: y),
                    size: 10,
                    color: InstrumentPalette.scale,
                    anchor: .trailing
                )
            }
        }

        readoutBox(
            in: &context,
            rect: CGRect(x: rect.minX + 1, y: rect.midY - 13, width: rect.width + 7, height: 26),
            text: Self.plain(speed),
            size: 17,
            colour: InstrumentPalette.scale
        )

        // What the tape is a tape of. The distinction matters above about ten
        // thousand feet, where indicated and ground speed are nothing like
        // each other.
        context.drawInstrument(
            reading.speedIsIndicated ? "IAS" : "GS",
            at: CGPoint(x: rect.midX, y: rect.minY - 8),
            size: 8.5,
            color: InstrumentPalette.live
        )
    }

    // MARK: - Altitude

    private func drawAltitudeTape(in context: inout GraphicsContext) {
        let rect = Layout.altitude
        let altitude = reading.altitudeFeet

        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(InstrumentPalette.tapeGround)
        )

        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect, cornerRadius: 4))

            let lowest = Int(((altitude - 1200) / 100).rounded(.down)) * 100
            let highest = Int(((altitude + 1200) / 100).rounded(.up)) * 100

            for value in stride(from: lowest, through: highest, by: 100) {
                let y = rect.midY - CGFloat(Double(value) - altitude) * Layout.altitudeScale
                let labelled = value % 500 == 0

                layer.strokeLine(
                    from: CGPoint(x: rect.minX, y: y),
                    to: CGPoint(x: rect.minX + (labelled ? 10 : 6), y: y),
                    color: InstrumentPalette.scale,
                    width: 1.3
                )

                guard labelled else { continue }
                layer.drawInstrument(
                    String(value),
                    at: CGPoint(x: rect.minX + 13, y: y),
                    size: 9.5,
                    color: InstrumentPalette.scale,
                    anchor: .leading
                )
            }
        }

        readoutBox(
            in: &context,
            rect: CGRect(x: rect.minX - 7, y: rect.midY - 13, width: rect.width + 7, height: 26),
            text: Self.plain(altitude),
            size: 15,
            colour: InstrumentPalette.scale
        )

        context.drawInstrument(
            "ALT",
            at: CGPoint(x: rect.midX, y: rect.minY - 8),
            size: 8.5,
            color: InstrumentPalette.live
        )

        // Height above the field, when the simulator is reporting it. Only
        // worth the space near the ground, which is the only place it is worth
        // anything.
        if let agl = reading.altitudeAGLFeet, agl < 3000 {
            context.drawInstrument(
                "\(Self.plain(agl)) AGL",
                at: CGPoint(x: rect.midX, y: rect.maxY + 9),
                size: 8.5,
                color: InstrumentPalette.range
            )
        }
    }

    // MARK: - Vertical speed

    private func drawVerticalSpeed(in context: inout GraphicsContext) {
        let rect = Layout.verticalSpeed

        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(InstrumentPalette.tapeGround)
        )

        for thousands in [-6.0, -2, -1, 1, 2, 6] {
            let y = rect.midY + Self.verticalSpeedOffset(fpm: thousands * 1000)
            let major = abs(thousands) != 6

            context.strokeLine(
                from: CGPoint(x: rect.minX + 2, y: y),
                to: CGPoint(x: rect.minX + (major ? 9 : 6), y: y),
                color: InstrumentPalette.scaleDim,
                width: 1.2
            )
        }

        context.strokeLine(
            from: CGPoint(x: rect.minX + 2, y: rect.midY),
            to: CGPoint(x: rect.minX + 11, y: rect.midY),
            color: InstrumentPalette.scale,
            width: 1.6
        )

        let tip = CGPoint(
            x: rect.maxX - 5,
            y: rect.midY + Self.verticalSpeedOffset(fpm: reading.verticalSpeedFPM)
        )
        context.strokeLine(
            from: CGPoint(x: rect.minX + 2, y: rect.midY),
            to: tip,
            color: InstrumentPalette.live,
            width: 2.4
        )

        // Only once it means something: every aeroplane's vertical speed
        // wanders by a few dozen feet a minute, and printing that is noise.
        if abs(reading.verticalSpeedFPM) >= 100 {
            context.drawInstrument(
                Self.plain((reading.verticalSpeedFPM / 100).rounded() * 100),
                at: CGPoint(
                    x: rect.midX,
                    y: reading.verticalSpeedFPM > 0 ? rect.minY - 8 : rect.maxY + 8
                ),
                size: 9,
                color: InstrumentPalette.live
            )
        }
    }

    /// Digits with no thousands separator.
    ///
    /// Instruments do not group: an altitude tape reads 36000, and a comma in
    /// the readout box is a character's worth of width spent saying nothing.
    static func plain(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(Int(value.rounded()))
    }

    /// Where a vertical speed sits on the strip, in points from the middle.
    ///
    /// Compressed above a thousand feet a minute, and again above two, exactly
    /// as an airliner's is: the difference between level and 500 fpm is worth
    /// seeing, and the difference between 4,000 and 5,000 is not.
    static func verticalSpeedOffset(fpm: Double) -> CGFloat {
        let magnitude = min(abs(fpm), 6000)
        let sign: CGFloat = fpm < 0 ? 1 : -1

        let distance: CGFloat
        switch magnitude {
        case ..<1000:
            distance = CGFloat(magnitude / 1000) * 36
        case ..<2000:
            distance = 36 + CGFloat((magnitude - 1000) / 1000) * 22
        default:
            distance = 58 + CGFloat((magnitude - 2000) / 4000) * 22
        }

        return sign * distance
    }

    // MARK: - Heading

    private func drawHeadingTape(in context: inout GraphicsContext) {
        let rect = Layout.heading
        let heading = reading.headingDegrees

        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(InstrumentPalette.tapeGround)
        )

        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect, cornerRadius: 4))

            let lowest = Int(((heading - 40) / 5).rounded(.down)) * 5
            let highest = Int(((heading + 40) / 5).rounded(.up)) * 5

            for value in stride(from: lowest, through: highest, by: 5) {
                let x = rect.midX + CGFloat(Double(value) - heading) * Layout.headingScale
                let labelled = value % 10 == 0

                layer.strokeLine(
                    from: CGPoint(x: x, y: rect.maxY - (labelled ? 8 : 5)),
                    to: CGPoint(x: x, y: rect.maxY),
                    color: InstrumentPalette.scale,
                    width: 1.2
                )

                guard labelled else { continue }
                let wrapped = ((value % 360) + 360) % 360
                // Cardinals as letters, everything else as the tens digit —
                // the way a compass card is marked, and the only way ten
                // degrees of tape is wide enough to label.
                let label: String
                switch wrapped {
                case 0: label = "N"
                case 90: label = "E"
                case 180: label = "S"
                case 270: label = "W"
                default: label = String(wrapped / 10)
                }

                layer.drawInstrument(
                    label,
                    at: CGPoint(x: x, y: rect.maxY - 15),
                    size: 9.5,
                    color: InstrumentPalette.scale
                )
            }
        }

        var lubber = Path()
        lubber.move(to: CGPoint(x: rect.midX, y: rect.minY + 8))
        lubber.addLine(to: CGPoint(x: rect.midX - 5, y: rect.minY))
        lubber.addLine(to: CGPoint(x: rect.midX + 5, y: rect.minY))
        lubber.closeSubpath()
        context.fill(lubber, with: .color(InstrumentPalette.aircraft))

        // Sits above the tape and notches into the foot of the ball, which is
        // where every glass cockpit puts it.
        readoutBox(
            in: &context,
            rect: CGRect(x: rect.midX - 23, y: rect.minY - 21, width: 46, height: 18),
            text: Format.heading(heading),
            size: 13,
            colour: InstrumentPalette.scale
        )
    }

    // MARK: - Footer

    private func drawFooter(in context: inout GraphicsContext) {
        let bank = Int(reading.bankDegrees.rounded())
        let bankText = bank == 0
            ? "WINGS LEVEL"
            : "BANK \(abs(bank))° \(bank > 0 ? "R" : "L")"

        context.drawInstrument(
            bankText,
            at: CGPoint(x: 10, y: 256),
            size: 9,
            color: InstrumentPalette.scaleDim,
            anchor: .leading
        )

        // The honesty line. It says, every single frame, whether the horizon
        // above it is a measurement or an inference.
        let source = reading.attitude == .simulator
            ? "ATTITUDE FROM SIM"
            : "ATTITUDE DERIVED"
        context.drawInstrument(
            source,
            at: CGPoint(x: 350, y: 256),
            size: 9,
            color: reading.attitude == .simulator
                ? InstrumentPalette.live
                : InstrumentPalette.caution,
            anchor: .trailing
        )

        if let configuration = reading.configuration {
            context.drawInstrument(
                configuration,
                at: CGPoint(x: 180, y: 271),
                size: 8.5,
                color: InstrumentPalette.scaleDim
            )
        }
    }

    // MARK: - Shared chrome

    /// The box a current value sits in: dark, outlined, and overlapping its
    /// tape so it reads as the pointer rather than as a caption.
    private func readoutBox(
        in context: inout GraphicsContext,
        rect: CGRect,
        text: String,
        size: CGFloat,
        colour: Color
    ) {
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(shape, with: .color(Color(white: 0.04)))
        context.stroke(shape, with: .color(InstrumentPalette.boxStroke), lineWidth: 1.2)
        context.drawInstrument(
            text,
            at: CGPoint(x: rect.midX, y: rect.midY),
            size: size,
            color: colour
        )
    }
}
