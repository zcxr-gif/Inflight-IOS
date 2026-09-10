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
/// ## And why the ramp runs the other way now
///
/// It used to run crimson on the deck through amber and green to blue and
/// violet in the flight levels — the direction most altitude charts take. On
/// this map it was backwards, for one reason: the great majority of every track
/// is at cruise, and cruise was the dark end. A violet line over a dark basemap,
/// or over satellite imagery, is a line you have to look for. The colour a
/// tracker most wants to find was the one it hid.
///
/// So the ramp is inverted and lightened. Low is PALE — an ice blue on the deck
/// through cyan and light green — and high is HOT, orange into red above
/// FL370. Pale reads on a dark map because it is bright; red reads on a light
/// one because it is saturated; and the height a flight actually spends its
/// hours at is now the loudest thing on the line rather than the quietest.
/// Anything so pale it cannot lift itself off a light map gets a dark halo
/// instead of a glow — see `FlownPathStyle.halo(for:)`, which decides that from
/// the colour rather than from a flag.
///
/// ## Seven bands, not four
///
/// Four bands put the whole of 25,000–40,000 ft in one colour, which is most
/// aircraft most of the time. Seven splits the cruise levels where the traffic
/// actually is, so two aircraft 6,000 ft apart at cruise no longer draw
/// identically.
///
/// ## Bands, and the ramp between them
///
/// The bands are what the map *filters* by, and what the legend names — a set
/// of ranges you can point at. They are no longer what the map draws: a flown
/// path is one gradient line running through `color(forFeet:)`, the same sweep
/// the profile chart has always drawn, so a climb reads as a climb rather than
/// as six steps at heights nobody was thinking about.
enum AltitudeBand {

    /// Every band, low to high. The map filters offer exactly these, so the
    /// heights you can filter by and the heights the path is coloured by are
    /// the same set of numbers.
    static let all = [0, 1, 2, 3, 4, 5, 6]

    /// The upper bound of each band in feet, in order. The last band is open.
    ///
    /// The top two moved down to 31,000 and 37,000, so the open band starts at
    /// FL370. That is where the red is, and it is a boundary worth having: the
    /// old one opened at FL400, which almost nothing in the feed ever reaches,
    /// so the top colour was a colour the map effectively never drew.
    private static let ceilings: [Double] = [2_500, 10_000, 18_000, 25_000, 31_000, 37_000]

    /// How the band reads as a range of feet.
    static func label(for band: Int) -> String {
        switch band {
        case 0: return "Below 2,500"
        case 1: return "2,500 – 10,000"
        case 2: return "10,000 – 18,000"
        case 3: return "18,000 – 25,000"
        case 4: return "25,000 – 31,000"
        case 5: return "31,000 – 37,000"
        default: return "Above 37,000"
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
    ///
    /// Pale and cool at the bottom, hot at the top, ending in red above FL370 —
    /// see the note on this type for why that is round this way. The two ends
    /// are deliberately far apart in lightness as well as in hue, so a climb
    /// reads as a climb on a map printed in greyscale, on a dark basemap, and to
    /// anybody who cannot tell the middle of the ramp apart by hue at all.
    static func color(for band: Int) -> UIColor {
        switch band {
        case 0: return UIColor(red: 0.753, green: 0.902, blue: 0.980, alpha: 0.95) // ice
        case 1: return UIColor(red: 0.470, green: 0.800, blue: 0.925, alpha: 0.95) // sky
        case 2: return UIColor(red: 0.549, green: 0.855, blue: 0.549, alpha: 0.95) // light green
        case 3: return UIColor(red: 0.925, green: 0.871, blue: 0.396, alpha: 0.95) // light yellow
        case 4: return UIColor(red: 0.969, green: 0.741, blue: 0.247, alpha: 0.95) // amber
        case 5: return UIColor(red: 0.957, green: 0.502, blue: 0.161, alpha: 0.95) // orange
        default: return UIColor(red: 0.871, green: 0.161, blue: 0.184, alpha: 0.95) // red
        }
    }

    /// What a stretch of path draws in when its height was never sent.
    ///
    /// Held apart from band 0 on purpose: crimson is a claim about the
    /// aeroplane, and this is an admission about the data.
    ///
    /// Fixed rather than trait-dependent, for the same reason the bands are and
    /// one more. A gradient renderer is handed its stops as colours and resolves
    /// them when it builds the ramp, not per frame against the map's trait — so
    /// a dynamic colour here would be resolved once, against whatever the map
    /// happened to be at the time, and then stay that way through a switch to
    /// light. Mid grey reads on both maps and needs no resolving.
    static let unknownColor = UIColor(white: 0.62, alpha: 0.95)

    /// What a stretch of path draws in while the aircraft is on the ground.
    ///
    /// Held apart from the ramp for the same kind of reason `unknownColor` is:
    /// the ramp answers "how high", and on the ground that question has no
    /// interesting answer. Every field is somewhere between sea level and eight
    /// thousand feet, so a taxi is coloured by the *elevation of the aerodrome*
    /// — ice at Toronto, sky blue at Denver — which says nothing about the
    /// aeroplane and quietly implies the two were at different heights when
    /// both were parked.
    ///
    /// White also happens to be the one colour a taxi needs. The ground part of
    /// a path is the part drawn over an airport diagram — pavement, hold bars,
    /// runway markings, stand numbers, the busiest square mile on the map — and
    /// it is drawn there at the closest zoom anyone ever uses. A hue in among
    /// all that is one more coloured line; white is the aircraft's own trail.
    ///
    /// Fixed rather than trait-dependent, like everything else here. What makes
    /// it read on a light map is the halo behind it — see `FlownPathStyle.halo`.
    static let groundColor = UIColor(white: 1, alpha: 0.95)

    /// The height at the middle of a band, used to place its stop on the ramp.
    ///
    /// The open top band is the exception: its stop sits at its FLOOR rather
    /// than at a made-up midpoint above it, so the ramp reaches red exactly
    /// where the band begins — FL370 — and holds it for everything above.
    /// Placing that stop at an invented 45,000 instead, which is what it used
    /// to do, meant the top colour was never actually drawn: nothing in the
    /// feed cruises there, so the highest traffic on the map got a blend on its
    /// way to a colour it would never arrive at.
    private static func midpoint(of band: Int) -> Double {
        guard band < ceilings.count else { return ceilings[ceilings.count - 1] }
        let low = band == 0 ? 0 : ceilings[band - 1]
        return (low + ceilings[band]) / 2
    }

    /// A colour interpolated between the band stops, for anything drawing a
    /// continuous scale rather than discrete runs.
    ///
    /// Which is both of them now. The profile chart has always drawn the sweep;
    /// the map used to draw one polyline per band and step between them, six
    /// hard edges at heights that mean nothing to anyone watching an aeroplane.
    /// It draws the same ramp along one gradient line now — see `FlownPath`.
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
