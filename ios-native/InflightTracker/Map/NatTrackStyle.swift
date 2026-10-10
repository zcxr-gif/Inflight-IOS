import CoreLocation
import UIKit

/// How the organised tracks are drawn.
///
/// The way the oceanic charts and the track planners draw them: every track
/// in one purple, with a badge on the line that carries its letter and points
/// the way the track is flown. One colour rather than one per letter, because
/// the letter is now written on the line itself — the colour no longer has to
/// say which track is which, only that this is the track system, and a single
/// saturated colour on a monochrome map says that at a glance.
enum NatTrackStyle {

    /// The line and the badge.
    static let colour = UIColor(red: 0.55, green: 0.33, blue: 0.92, alpha: 1)

    /// The line, a little see-through so traffic flying the track reads on top.
    static let lineColour = colour.withAlphaComponent(0.85)

    // MARK: - The badge

    /// The badge's sprite, one for each way it can point.
    static func badgeImage(pointsRight: Bool) -> String {
        pointsRight ? "nat-badge|right" : "nat-badge|left"
    }

    /// A tag with one pointed end: a rounded block the letter sits in, and an
    /// arrowhead the way the track is flown.
    ///
    /// Drawn with as much empty space behind it as the point takes in front,
    /// so the middle of the image is the middle of the block — which is where
    /// Mapbox centres the letter.
    static func badge(pointsRight: Bool) -> UIImage {
        let blockWidth: CGFloat = 20
        let height: CGFloat = 18
        let point: CGFloat = 7
        let radius: CGFloat = 3
        let inset: CGFloat = 0.75
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
            // A darker edge, so the badge holds its shape over pale imagery.
            UIColor(red: 0.30, green: 0.15, blue: 0.58, alpha: 1).setStroke()
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

    /// The levels a track is valid at, written under the badge at each end.
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
