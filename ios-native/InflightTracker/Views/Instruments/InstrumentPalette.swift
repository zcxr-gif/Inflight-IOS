import SwiftUI

/// The colours an electronic flight display is drawn in.
///
/// Deliberately fixed rather than themed. Every other surface in this app
/// follows the appearance setting, because every other surface is *the app*;
/// these two are instruments, and the colour of an instrument carries meaning —
/// green is what the aeroplane is doing, magenta is what it has been told to
/// do, amber is a caution. Re-tinting that for a light theme would not be a
/// paler instrument, it would be a wrong one.
enum InstrumentPalette {

    /// The glass itself.
    static let screen = Color(red: 0.02, green: 0.02, blue: 0.03)

    /// Above and below the horizon.
    static let sky = Color(red: 0.10, green: 0.42, blue: 0.78)
    static let ground = Color(red: 0.44, green: 0.29, blue: 0.13)

    /// Ladder, tapes, compass — anything that is a scale rather than a value.
    static let scale = Color(white: 0.94)
    static let scaleDim = Color(white: 0.62)

    /// The aeroplane itself, on both displays.
    static let aircraft = Color(red: 1.0, green: 0.83, blue: 0.10)

    /// What it is doing now: speeds, the filed route, the wind.
    static let live = Color(red: 0.16, green: 0.94, blue: 0.36)

    /// Distances and ranges.
    static let range = Color(red: 0.20, green: 0.86, blue: 0.95)

    /// Other people's aeroplanes.
    static let traffic = Color(white: 0.92)

    /// Something the pilot should look at.
    static let caution = Color(red: 1.0, green: 0.62, blue: 0.05)

    /// The ground behind a tape or a readout box.
    static let tapeGround = Color(white: 0.06).opacity(0.82)
    static let boxStroke = Color(white: 0.88)

    /// Every number on an instrument is monospaced, so a digit changing does
    /// not shuffle the ones beside it.
    static func digits(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension GraphicsContext {

    /// Draw one piece of instrument text.
    ///
    /// Resolved and shaded rather than handed a coloured `Text`: the shading is
    /// set on the resolved glyphs, which is the supported way to colour text in
    /// a `Canvas` and the only one that does not go through a deprecated
    /// modifier.
    func drawInstrument(
        _ string: String,
        at point: CGPoint,
        size: CGFloat,
        color: Color,
        weight: Font.Weight = .bold,
        anchor: UnitPoint = .center
    ) {
        var text = resolve(Text(string).font(InstrumentPalette.digits(size, weight: weight)))
        text.shading = .color(color)
        draw(text, at: point, anchor: anchor)
    }

    /// A straight line, which is most of what these displays are made of.
    func strokeLine(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        width: CGFloat,
        dash: [CGFloat] = []
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
        )
    }

    /// The diamond a fix and a piece of traffic are both drawn as.
    func diamond(at point: CGPoint, radius: CGFloat, color: Color, filled: Bool, width: CGFloat = 1.6) {
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: point.y - radius))
        path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        path.addLine(to: CGPoint(x: point.x - radius, y: point.y))
        path.closeSubpath()

        if filled {
            fill(path, with: .color(color))
        } else {
            stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
        }
    }
}
