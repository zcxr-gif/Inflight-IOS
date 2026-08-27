import CoreLocation
import MapKit
import UIKit

/// How the flown path is drawn: how wide, and in what.
///
/// ## Why the width is not one number
///
/// `MKOverlayPathRenderer` takes its width in points, so a line set to three
/// and a half of them is three and a half points wide at every zoom — which
/// sounds like exactly what you want and is why the path looked like rope from
/// any distance. A track is not a road. Zoomed in, the line is a thin thing
/// following a wide gap between samples and the width reads as the width of the
/// line. Pulled back to the whole flight, the same track is a tangle of
/// switchbacks compressed into a couple of hundred pixels, and a stroke that
/// stays three and a half points wide while the gaps between its own turns fall
/// below one point stops being a line and becomes a filled shape. The remedy is
/// the obvious one and it is the one MapKit will not do for you: draw it
/// narrower the further back you stand.
///
/// Interpolated on the log of the scale rather than on the scale itself,
/// because that is how zoom works — each step out doubles what is on screen, so
/// a linear ramp would spend almost all of its travel in the first
/// aerodrome-sized fraction of the range and then sit at its minimum across
/// every view that actually shows a flight.
///
/// Keyed on **how much ground a point of screen covers**, which is the one
/// thing about the camera a renderer is told, and is a more direct statement of
/// "zoomed in" than the camera's distance was. It also removes the machinery
/// that used to read the camera on every frame of every pan and push a new
/// width into two renderers: the width is now decided where it is used.
enum FlownPathStyle {

    /// Wide enough to read as a drawn line over cartography and imagery both.
    static let closeWidth: CGFloat = 3.4

    /// Narrow enough that a long-haul's turns are still separate lines rather
    /// than one shape, and no narrower: a hairline over satellite imagery is a
    /// line nobody can see.
    static let farWidth: CGFloat = 1.3

    /// The scales the two widths belong to, in metres of ground per point of
    /// screen. Below the first you are looking at a circuit, above the second at
    /// the planet.
    ///
    /// Carried over from the camera distances these replace — 150 km and
    /// 8 000 km — on the rough equivalence that a camera standing that far back
    /// shows about that much ground down an eight-hundred-point viewport. The
    /// numbers are a judgement about how the track should look and not a
    /// measurement, so the conversion only has to land in the right place.
    static let closeMetresPerPoint: Double = 180
    static let farMetresPerPoint: Double = 10_000

    static func width(forMetresPerPoint metres: Double) -> CGFloat {
        guard metres.isFinite, metres > 0 else { return closeWidth }
        if metres <= closeMetresPerPoint { return closeWidth }
        if metres >= farMetresPerPoint { return farWidth }

        let travel = log(metres / closeMetresPerPoint) / log(farMetresPerPoint / closeMetresPerPoint)
        return closeWidth + (farWidth - closeWidth) * CGFloat(travel)
    }

    // MARK: - The taper

    /// How wide the oldest end of the track is drawn, against the aircraft's
    /// end.
    ///
    /// A flight path is a thing with a direction and a present moment, and a
    /// wire of constant width says neither. Tapering says both, and it settles
    /// the problem the width ramp above exists for from the other side: pulled
    /// back to a whole long-haul, the tangle of old switchbacks is drawn
    /// thinner than the leg being flown now, so the recent track reads through
    /// it rather than being lost in it.
    ///
    /// Gentle on purpose. Half is enough to be felt without the first hour of a
    /// fourteen-hour flight becoming a hairline nobody can see.
    static let tailWidth: CGFloat = 0.55

    /// The taper at a point along the track — 0 at the oldest end, 1 at the
    /// aircraft.
    ///
    /// Eased rather than linear, so most of the change happens over the older
    /// part of the track and the recent leg stays at full width. A linear taper
    /// spends half its travel on the half of the flight you are usually
    /// watching, which reads as the line thinning for no reason.
    static func taper(at along: CGFloat) -> CGFloat {
        let t = min(max(along, 0), 1)
        return tailWidth + (1 - tailWidth) * (t * t * (3 - 2 * t))
    }

    // MARK: - Resolution

    /// How far apart, in points of screen, two drawn points have to be to be
    /// worth drawing separately.
    ///
    /// The curve is a fixed few thousand points, which is the right density for
    /// looking at one turn and thousands of sub-pixel segments for looking at
    /// the whole flight. Resampling to this at draw time is what makes the work
    /// proportional to the screen rather than to the hours in the air — and it
    /// is also why the curve can afford to be dense in the first place.
    ///
    /// A little over a point: fine enough that no corner is visible at any
    /// zoom, coarse enough that a long track collapses to a few hundred
    /// segments when it is all on screen at once.
    static let resampleSpacing: CGFloat = 1.2

    // MARK: - The casing

    /// How much wider the casing under the line is than the line itself.
    ///
    /// ## Why this is not a glow
    ///
    /// It was. The under-layer used to be the path's own colours at a fifth of
    /// their opacity, three and a bit times as wide, on the reasoning that a
    /// wide faint wash of the same colour reads as a halo. It does not, and the
    /// arithmetic says why: at the close width that is a band nearly eleven
    /// points across, and a stroke of uniform opacity has a **hard edge**
    /// wherever it ends. So what got drawn was not a glow but a flat-topped
    /// stripe with a visible border down each side — two extra lines running
    /// parallel to the track, worst exactly where the line is widest, which is
    /// zoomed in. And because the stripe was the line's own colour, the line
    /// inside it had nothing to contrast against: the crisp track vanished into
    /// the middle of a fat soft-coloured ribbon.
    ///
    /// A glow needs a falloff, and a falloff needs either a blur or a stack of
    /// strokes. What the line actually needs is neither — it needs to be
    /// legible over cartography, over labels and over satellite imagery, and
    /// the answer to that is the one the aircraft marks on the same map already
    /// use: a dark casing, barely proud of the line, in a colour the line can
    /// never be.
    ///
    /// A ratio rather than a fixed number of points, so it tracks the width
    /// ramp above: about a point either side when the line is at its widest,
    /// about a third of one when it is at its narrowest. A fixed casing would
    /// be right at one end of the zoom range and a blob at the other.
    static let casingSpread: CGFloat = 1.55

    /// The casing's colour: the same near-black the plane icons are outlined
    /// in, so an aircraft and the track behind it read as one drawing rather
    /// than as two things that happen to meet.
    ///
    /// Opaque, and that is a decision rather than an oversight. The track is
    /// drawn as a run of separate strokes now — it has to be, because each one
    /// is a different width and a different colour — and separate strokes with
    /// round joins overlap each other. Anything translucent composites twice at
    /// every one of those overlaps and the line comes out beaded. Opaque, the
    /// overlaps are invisible and the whole class of artefact is gone.
    ///
    /// Nothing is lost by it: this is a point either side of a line already
    /// several points wide, so the cartography it covers was under the track
    /// anyway. Dark in both appearances for the same reason the icon outline
    /// is — it is contrast against the *line*, not against the map, and the
    /// altitude ramp is light at every height it draws.
    static let casingColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)

    /// The casing under a line of this width. Taken from the line rather than
    /// from the scale so the two can never disagree: the ramp is read once per
    /// draw, and both strokes come off that one answer.
    static func casingWidth(under lineWidth: CGFloat) -> CGFloat {
        lineWidth * casingSpread
    }
}
