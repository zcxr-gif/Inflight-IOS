import CoreLocation
import UIKit

/// How the organised tracks are drawn.
///
/// The way the oceanic charts and the track planners draw them: a line per
/// track, with a small badge on it that carries the letter and points the way
/// the track is flown. Each track keeps a colour of its own, and its badge and
/// its levels wear the same one, so a badge is matched to its line by colour
/// before the letter is even read.
enum NatTrackStyle {

    /// The colours the tracks are drawn in, handed out by letter.
    ///
    /// The first six are the web tracker's, so the westbound A to F look as
    /// they always have. Eight in all, so the tracks either side of any one —
    /// the next letter and the one before — are never the same colour, which
    /// is what matters when the lines run a degree apart.
    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1),
        UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1),
        UIColor(red: 0.64, green: 0.61, blue: 1.00, alpha: 1),
        UIColor(red: 0.90, green: 0.49, blue: 0.13, alpha: 1),
        UIColor(red: 0.00, green: 0.81, blue: 0.79, alpha: 1),
        UIColor(red: 0.96, green: 0.45, blue: 0.80, alpha: 1),
        UIColor(red: 0.62, green: 0.86, blue: 0.20, alpha: 1),
    ]

    /// Where in the palette a track's letter lands.
    static func colourIndex(for name: String) -> Int {
        guard let letter = name.uppercased().unicodeScalars.first,
              (65...90).contains(letter.value) else { return 0 }
        return Int(letter.value - 65) % palette.count
    }

    static func colour(for name: String) -> UIColor {
        palette[colourIndex(for: name)]
    }

    /// The line, a little see-through so traffic flying the track reads on top.
    static func lineColour(for name: String) -> UIColor {
        colour(for: name).withAlphaComponent(0.85)
    }

    // MARK: - The badge

    /// The badge's sprite: one per colour, for each way it can point.
    static func badgeImage(colourIndex: Int, pointsRight: Bool) -> String {
        "nat-badge|\(colourIndex)|\(pointsRight ? "right" : "left")"
    }

    /// A tag with one pointed end: a rounded block the letter sits in, and an
    /// arrowhead the way the track is flown.
    ///
    /// Small on purpose — it labels a line, and it sits on a part of the map
    /// that is already crowded with the traffic flying it. Drawn with as much
    /// empty space behind it as the point takes in front, so the middle of the
    /// image is the middle of the block, which is where Mapbox centres the
    /// letter.
    static func badge(colour: UIColor, pointsRight: Bool) -> UIImage {
        let blockWidth: CGFloat = 13
        let height: CGFloat = 12
        let point: CGFloat = 4.5
        let radius: CGFloat = 2.5
        let inset: CGFloat = 0.5
        let size = CGSize(width: blockWidth + point * 2, height: height)

        let left = point
        let right = point + blockWidth
        let top = inset
        let bottom = height - inset

        let path = UIBezierPath()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right + point - inset, y: height / 2))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addArc(
            withCenter: CGPoint(x: left + radius, y: bottom - radius),
            radius: radius, startAngle: .pi / 2, endAngle: .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addArc(
            withCenter: CGPoint(x: left + radius, y: top + radius),
            radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true
        )
        path.close()

        if !pointsRight {
            path.apply(CGAffineTransform(translationX: size.width, y: 0).scaledBy(x: -1, y: 1))
        }

        return UIGraphicsImageRenderer(size: size).image { _ in
            colour.setFill()
            path.fill()
            // A dark edge, so a pale badge holds its shape over pale imagery
            // and the white letter on a yellow one still has something to sit
            // against.
            UIColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Which sprite to use for a track flown on `bearing`, and how far to turn
    /// it, so the point leads and the letter is never upside down.
    ///
    /// The right-pointing sprite unturned points east, the left-pointing one
    /// west. Whichever of the two is nearer the direction of travel is turned
    /// the rest of the way, which keeps the turn within a quarter either side
    /// of level — and a letter turned less than a quarter still reads.
    static func badgePlacement(bearing: Double) -> (pointsRight: Bool, rotation: Double) {
        let heading = bearing.truncatingRemainder(dividingBy: 360) + (bearing < 0 ? 360 : 0)
        let pointsRight = heading < 180
        return (pointsRight, heading - (pointsRight ? 90 : 270))
    }

    /// The levels a track is valid at, written under the badge at its entry.
    static func levelsLabel(for track: NatTrack) -> String? {
        track.levelsLabel.map { "FL \($0)" }
    }
}

extension NatTrack {

    /// The fixes in the order the track is flown.
    ///
    /// The direction is in the levels — a track carries eastbound levels or
    /// westbound ones — and the coordinates are put in that order whatever
    /// order the message listed them in, because the badges point along them.
    /// A track with neither is left as published.
    var coordinatesInFlightOrder: [CLLocationCoordinate2D] {
        guard let first = coordinates.first, let last = coordinates.last else { return coordinates }
        if isEastbound, first.longitude > last.longitude { return coordinates.reversed() }
        if eastLevels.isEmpty, !westLevels.isEmpty, first.longitude < last.longitude {
            return coordinates.reversed()
        }
        return coordinates
    }
}
