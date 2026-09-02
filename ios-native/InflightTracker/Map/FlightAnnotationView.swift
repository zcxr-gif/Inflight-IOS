import MapKit
import UIKit

/// One aeroplane on the map: the sprite, and the marks over it.
///
/// ## Why the rotation moved off the view
///
/// This used to be a plain `MKAnnotationView` whose `image` was the sprite and
/// whose `transform` was the heading. That is the whole of what a map marker
/// needs right up until something has to sit above it and stay upright, and
/// then it is unworkable: a subview of a rotated view rotates with it, and
/// counter-rotating the subview only fixes which way up it is — it still swings
/// around the aeroplane as the aeroplane turns, because the parent's transform
/// moves its position too. A callsign that orbits its own aircraft is worse
/// than no callsign.
///
/// So the view itself is never transformed. The sprite is a subview and carries
/// the rotation alone; the marks are siblings of it in the view's own upright
/// coordinate space, and simply stay where they are put.
///
/// ## Why the bounds stay the sprite's
///
/// The marks are drawn outside `bounds`, with `clipsToBounds` off. That is
/// deliberate and it is what keeps this change free: MapKit sizes collisions
/// and hit-testing from the view's frame, so a frame grown to fit a callsign
/// would declutter aeroplanes as though each were three times its real size,
/// and would put a tap target over a label nobody is trying to tap. The marks
/// are decoration — they render outside the frame, collide with nothing, and
/// receive no touches, which is exactly right for all three.
///
/// ## Why neither mark casts a layer shadow any more
///
/// Both used to, and it is what made a map full of callsigns crawl. A
/// `CALayer` shadow with no `shadowPath` cannot be drawn in place: Core
/// Animation has to render the layer offscreen, read its alpha, blur it, and
/// composite the result — per layer, per frame. One of those is free. Two
/// hundred aeroplanes wearing their callsigns, moved every frame by the
/// smoothing and again by every pan, is two hundred offscreen passes a frame,
/// and the map drops to a slideshow exactly when the labels are switched on.
///
/// So the halo is drawn *into* the text instead, as a stroke on the glyphs —
/// one ordinary draw, no offscreen pass, and legible over a light map, a dark
/// one and satellite imagery the same way the blur was. The VA logo keeps its
/// blurred edge, because a wordmark needs one and a stroke cannot give it, but
/// it is rasterised: the shadow is computed once when the logo is set and the
/// cached bitmap is what moves, rather than the blur being redone every frame.
final class FlightAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "flightAnnotation"

    /// The aeroplane, and the only thing here that turns.
    private let sprite = UIImageView()

    /// The VA's mark, above the aeroplane.
    private let mark = UIImageView()

    /// The callsign, beside the mark or on its own.
    private let callsign = UILabel()

    /// How far above the sprite's top edge the marks sit.
    private static let markGap: CGFloat = 5

    private static let markSide: CGFloat = 18

    /// How the callsign is drawn: white, with the halo stroked into the glyphs
    /// rather than blurred behind them.
    ///
    /// A negative `strokeWidth` is the one that fills *and* strokes — a
    /// positive one would give hollow letters. The figure is a percentage of
    /// the point size, so eight is a little over three quarters of a point of
    /// pen at this size: enough to sit the text off a bright coastline, not so
    /// much that it closes up the counters of heavy 9.5pt type.
    private static let callsignAttributes: [NSAttributedString.Key: Any] = {
        // Carried in the string rather than left to the label's own properties:
        // assigning `attributedText` hands the string's attributes authority
        // over how it is drawn, so alignment and truncation belong here beside
        // the rest of them or they are two answers to the same question.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        return [
            .font: UIFont.systemFont(ofSize: 9.5, weight: .heavy),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -8.0,
            .paragraphStyle: paragraph
        ]
    }()

    /// The width the current callsign measured to, so a label that has not
    /// changed is never measured twice.
    ///
    /// Measuring is not expensive on its own; it is expensive at the rate this
    /// view is asked to lay itself out, which is every time the sprite is
    /// reassigned as well as every time the marks are.
    private var callsignWidth: CGFloat = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        clipsToBounds = false

        sprite.contentMode = .center
        addSubview(sprite)

        mark.contentMode = .scaleAspectFit
        mark.isHidden = true
        // A logo drawn straight onto the map has no edge of its own, and a
        // white wordmark over a snowfield is nothing at all — so this one keeps
        // its blur, and pays for it once. See the note at the top: rasterising
        // turns a per-frame offscreen pass into a bitmap that is computed when
        // the logo lands and simply moved thereafter.
        mark.layer.shadowColor = UIColor.black.cgColor
        mark.layer.shadowOpacity = 0.55
        mark.layer.shadowRadius = 2.5
        mark.layer.shadowOffset = .zero
        mark.layer.shouldRasterize = true
        mark.layer.rasterizationScale = Self.rasterScale(for: traitCollection)
        addSubview(mark)

        // Alignment and truncation ride in the attributes — see above. What is
        // left here is the one thing the string cannot say: that there is no
        // backing plate for Core Animation to blend the map through.
        callsign.backgroundColor = .clear
        callsign.isHidden = true
        addSubview(callsign)

        // A cache built at the wrong scale is a blurred logo, so this is
        // correctness rather than housekeeping — moving between displays is
        // exactly when it would otherwise go soft. Registered the same way the
        // other annotation views watch their traits.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: FlightAnnotationView, _) in
            view.mark.layer.rasterizationScale =
                FlightAnnotationView.rasterScale(for: view.traitCollection)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A dequeued view arrives wearing the last aeroplane's marks. Cleared
        // here rather than trusted to be overwritten: `apply` writes the marks
        // only when there are marks to write, so a flight with none would
        // otherwise inherit somebody else's callsign.
        mark.image = nil
        mark.isHidden = true
        callsign.attributedText = nil
        callsign.isHidden = true
        callsignWidth = 0
        spriteTransform = .identity
    }

    // MARK: - The aeroplane

    /// The sprite, which also sizes the view.
    var spriteImage: UIImage? {
        get { sprite.image }
        set {
            guard sprite.image !== newValue else { return }
            sprite.image = newValue

            let size = newValue?.size ?? .zero
            // The view is the sprite and nothing more — see the note above on
            // why the marks are not allowed to grow it.
            bounds = CGRect(origin: .zero, size: size)
            sprite.frame = bounds
            layoutMarks()
        }
    }

    /// The heading, applied to the aeroplane alone.
    var spriteTransform: CGAffineTransform {
        get { sprite.transform }
        set { sprite.transform = newValue }
    }

    // MARK: - The marks

    /// Puts the VA's logo and the callsign over the aeroplane. Either may be
    /// nil, and both being nil is the ordinary case.
    func apply(mark image: UIImage?, callsign text: String?) {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        mark.image = image
        mark.isHidden = image == nil
        if image != nil {
            // The trait registration above covers every later change; this
            // covers the first, for a view built before it had a screen.
            mark.layer.rasterizationScale = Self.rasterScale(for: traitCollection)
        }

        if trimmed.isEmpty {
            callsign.attributedText = nil
            callsign.isHidden = true
            callsignWidth = 0
        } else {
            let drawn = NSAttributedString(string: trimmed, attributes: Self.callsignAttributes)
            callsign.attributedText = drawn
            callsign.isHidden = false
            // Measured here, once, rather than in `layoutMarks` — which also
            // runs whenever the sprite changes, and the text has not.
            //
            // Capped, because a callsign is typed by a pilot and some of them
            // are very long indeed. A band wider than this stops being a label
            // on an aeroplane and starts being a banner across the map.
            //
            // The couple of points on top are the stroke: the measurement is of
            // the glyph run, and the pen sits half outside it.
            callsignWidth = min(ceil(drawn.size().width) + 2, 96)
        }

        layoutMarks()
    }

    /// Lays the marks out centred over the aeroplane, in the view's own
    /// upright space.
    ///
    /// Done by hand rather than with a stack view: this runs for every aircraft
    /// on screen whenever the marks change, and a stack view would bring a
    /// layout pass and an engine to each of them for what is two rectangles in
    /// a row.
    private func layoutMarks() {
        let hasMark = !mark.isHidden
        let hasText = !callsign.isHidden

        guard hasMark || hasText else { return }

        let gap: CGFloat = hasMark && hasText ? 4 : 0
        let markWidth = hasMark ? Self.markSide : 0
        let textWidth = hasText ? callsignWidth : 0

        let total = markWidth + gap + textWidth
        let height = Self.markSide
        let top = -(height + Self.markGap)
        var x = bounds.midX - total / 2

        if hasMark {
            mark.frame = CGRect(x: x, y: top, width: markWidth, height: height)
            x += markWidth + gap
        }

        if hasText {
            callsign.frame = CGRect(x: x, y: top, width: textWidth, height: height)
        }
    }

    /// The scale a rasterised layer has to be built at to stay sharp. Zero
    /// while the view has no screen yet, which would cache a one-pixel logo.
    private static func rasterScale(for traits: UITraitCollection) -> CGFloat {
        traits.displayScale > 0 ? traits.displayScale : 3
    }
}
