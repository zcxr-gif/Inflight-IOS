import UIKit

/// Height bands used to colour a flown path and the profile under it.
///
/// ## Why this is a real colour ramp now
///
/// The first version ran orange → amber → pale gold → white, deliberately
/// avoiding blue "without putting blue on the map". The trouble is that three
/// of those four are the same hue at different lightnesses, and the fourth is
/// not a hue at all — so a cruise leg, which is the great majority of any long
/// flight, drew as one flat pale line and the ramp read as no colouring at all.
/// A scale whose whole job is to say "this bit was low and this bit was high"
/// has to separate by hue, because hue is what the eye reads first.
///
/// So: crimson on the deck through orange, amber, green and teal to blue and
/// violet in the flight levels. It is the ramp every other altitude chart in
/// aviation uses, for the same reason.
///
/// ## Seven bands, not four
///
/// Four bands put the whole of 25,000–40,000 ft in one colour, which is most
/// aircraft most of the time. Seven splits the cruise levels where the traffic
/// actually is, so two aircraft 6,000 ft apart at cruise no longer draw
/// identically.
///
/// Banded rather than interpolated *for the map*, so a path is a handful of
/// polylines rather than one per breadcrumb. `color(forFeet:)` interpolates
/// between the same stops for the profile chart, where a smooth gradient costs
/// nothing.
enum AltitudeBand {

    /// Every band, low to high. The map filters offer exactly these, so the
    /// heights you can filter by and the heights the path is coloured by are
    /// the same set of numbers.
    static let all = [0, 1, 2, 3, 4, 5, 6]

    /// The upper bound of each band in feet, in order. The last band is open.
    private static let ceilings: [Double] = [2_500, 10_000, 18_000, 25_000, 32_000, 40_000]

    /// How the band reads as a range of feet.
    static func label(for band: Int) -> String {
        switch band {
        case 0: return "Below 2,500"
        case 1: return "2,500 – 10,000"
        case 2: return "10,000 – 18,000"
        case 3: return "18,000 – 25,000"
        case 4: return "25,000 – 32,000"
        case 5: return "32,000 – 40,000"
        default: return "Above 40,000"
        }
    }

    /// Band index for an altitude, from ground to the flight levels.
    static func band(forFeet feet: Double) -> Int {
        guard feet.isFinite else { return 0 }
        for (index, ceiling) in ceilings.enumerated() where feet < ceiling { return index }
        return ceilings.count
    }

    /// The colour at the centre of each band — the stops the ramp is built
    /// from, and what the map draws.
    ///
    /// Fixed rather than trait-dependent, unlike the old top band: every one of
    /// these carries enough chroma to sit on either a light or a dark map, so
    /// none of them has to change identity with the appearance. A path that
    /// changed colour when you switched to light mode would be telling you
    /// about the theme rather than about the aeroplane.
    static func color(for band: Int) -> UIColor {
        switch band {
        case 0: return UIColor(red: 0.839, green: 0.153, blue: 0.216, alpha: 0.95)  // crimson
        case 1: return UIColor(red: 0.945, green: 0.427, blue: 0.114, alpha: 0.95)  // orange
        case 2: return UIColor(red: 0.949, green: 0.706, blue: 0.106, alpha: 0.95)  // amber
        case 3: return UIColor(red: 0.400, green: 0.729, blue: 0.204, alpha: 0.95)  // green
        case 4: return UIColor(red: 0.129, green: 0.702, blue: 0.647, alpha: 0.95)  // teal
        case 5: return UIColor(red: 0.180, green: 0.494, blue: 0.902, alpha: 0.95)  // blue
        default: return UIColor(red: 0.514, green: 0.322, blue: 0.855, alpha: 0.95) // violet
        }
    }

    /// The height at the middle of a band, used to place its stop on the ramp.
    private static func midpoint(of band: Int) -> Double {
        let low = band == 0 ? 0 : ceilings[band - 1]
        // The open top band has no ceiling; 45,000 puts its stop a sensible
        // distance above the one below rather than at infinity.
        let high = band < ceilings.count ? ceilings[band] : 45_000
        return (low + high) / 2
    }

    /// A colour interpolated between the band stops, for anything drawing a
    /// continuous scale rather than discrete runs.
    ///
    /// The map does not use this — it wants whole polylines of one colour — but
    /// the profile chart does, and it is what makes a climb read as a sweep
    /// through the ramp instead of six steps.
    static func color(forFeet feet: Double) -> UIColor {
        guard feet.isFinite else { return color(for: 0) }

        let clamped = max(feet, 0)
        if clamped <= midpoint(of: 0) { return color(for: 0) }
        if clamped >= midpoint(of: all.count - 1) { return color(for: all.count - 1) }

        for upper in 1..<all.count {
            let high = midpoint(of: upper)
            guard clamped <= high else { continue }

            let low = midpoint(of: upper - 1)
            let span = high - low
            let t = span > 0 ? CGFloat((clamped - low) / span) : 0
            return blend(color(for: upper - 1), color(for: upper), t)
        }

        return color(for: all.count - 1)
    }

    private static func blend(_ from: UIColor, _ to: UIColor, _ t: CGFloat) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

        let k = min(max(t, 0), 1)
        return UIColor(
            red: fr + (tr - fr) * k,
            green: fg + (tg - fg) * k,
            blue: fb + (tb - fb) * k,
            alpha: fa + (ta - fa) * k
        )
    }
}
