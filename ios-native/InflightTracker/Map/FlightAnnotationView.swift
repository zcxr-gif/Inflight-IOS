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
/// So the callsign sits on a **plate** instead: a plain `UIView` with a
/// background colour and a corner radius, no `drawRect`, no sublayers and no
/// `masksToBounds` — which Core Animation composites on the GPU as an ordinary
/// rounded rectangle, with none of the offscreen work a shadow costs. The VA
/// logo keeps its blurred edge, because a wordmark needs one and nothing else
/// will give it, but it is rasterised: the shadow is computed once when the
/// logo is set and the cached bitmap is what moves.
///
/// ## Why the plate, rather than a stroke on the glyphs
///
/// The stroke was the first answer, and it was the wrong one for three reasons
/// that all showed up as "the callsign is hard to read":
///
/// 1. **It was always white.** The map has a **Light** palette, and white text
///    with a hairline dark edge on daytime cartography is very nearly nothing.
///    Both the text and the plate now follow the map's own scheme —
///    `isOverLightMap` — so the label is dark on a light map and light on a
///    dark one, rather than betting the map is always dark.
/// 2. **The pen ate the letters.** `strokeWidth` is a percentage of point
///    size and the stroke is centred on the outline, so -8 at 9.5pt heavy put
///    about four tenths of a point *inside* every stem. At that size it closes
///    the counters of a, e, 6, 8, 9 and 0 and the word turns into a bar. There
///    is no stroke now, so the glyphs are the shape the typeface drew.
/// 3. **It truncated.** The frame was measured from the glyph run plus two
///    points for a pen that sits half outside it; when that guess came up
///    short, `byTruncatingTail` quietly ate the last character and the label
///    showed the *wrong callsign*. The width now carries real padding on both
///    sides — which is also what the plate needs — so a fractional
///    under-measure has somewhere to go.
final class FlightAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "flightAnnotation"

    /// The aeroplane, and the only thing here that turns.
    private let sprite = UIImageView()

    /// The VA's mark, above the aeroplane.
    private let mark = UIImageView()

    /// The callsign, beside the mark or on its own.
    private let callsign = UILabel()

    /// What the callsign is written on.
    ///
    /// Its own view rather than the label's `backgroundColor`: a `UILabel`
    /// draws its background into the same backing store as its text, so
    /// rounding *that* needs `masksToBounds` — which is the offscreen pass this
    /// file exists to avoid. A bare `UIView` has no drawn content, so its
    /// corner radius is the compositor's job and costs nothing.
    private let plate = UIView()

    /// How far above the sprite's top edge the marks sit.
    private static let markGap: CGFloat = 5

    private static let markSide: CGFloat = 18

    /// The plate's height, and how far the text sits in from each end.
    ///
    /// The padding is doing two jobs: it is the plate's own inset, and it is
    /// the slack that stops a fractional under-measure from truncating the
    /// callsign. See the note at the top.
    private static let callsignHeight: CGFloat = 15
    private static let callsignPadding: CGFloat = 5
    private static let callsignRadius: CGFloat = 4.5

    /// The widest a callsign may be drawn.
    ///
    /// A callsign is typed by a pilot and some of them are very long indeed. A
    /// band wider than this stops being a label on an aeroplane and starts
    /// being a banner across the map.
    private static let callsignMaxWidth: CGFloat = 108

    /// How the callsign is drawn, for one way round the map.
    private struct CallsignStyle {
        let attributes: [NSAttributedString.Key: Any]
        let plate: UIColor
    }

    /// Both ways round, built once.
    ///
    /// The font is the same in each, which is what lets a scheme change restyle
    /// the label without re-measuring it — the glyph run is identical and only
    /// its colour moves.
    ///
    /// Ten point bold rather than nine and a half heavy: at this size heavy is
    /// most of the way to a solid bar before anything is drawn over it, and the
    /// plate is doing the job the extra weight was there to do. The small
    /// positive kern is for the same reason — callsigns are all caps and
    /// digits, which set tight.
    private static let darkMapStyle = FlightAnnotationView.style(
        text: .white,
        plate: UIColor(white: 0, alpha: 0.62)
    )

    private static let lightMapStyle = FlightAnnotationView.style(
        text: UIColor(white: 0.08, alpha: 1),
        plate: UIColor(white: 1, alpha: 0.80)
    )

    private static func style(text colour: UIColor, plate: UIColor) -> CallsignStyle {
        // Carried in the string rather than left to the label's own properties:
        // assigning `attributedText` hands the string's attributes authority
        // over how it is drawn, so alignment and truncation belong here beside
        // the rest of them or they are two answers to the same question.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        return CallsignStyle(
            attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: colour,
                .kern: 0.2,
                .paragraphStyle: paragraph
            ],
            plate: plate
        )
    }

    private var callsignStyle: CallsignStyle {
        isOverLightMap ? Self.lightMapStyle : Self.darkMapStyle
    }

    /// Which way round the map underneath is drawn.
    ///
    /// Told, not read: this view has no business reading the appearance
    /// setting, and the palette can say something different from it — the map
    /// is light while the app is dark whenever somebody has picked the Light
    /// palette. `TrackerMapView` resolves the two and hands the answer down.
    var isOverLightMap = false {
        didSet {
            guard isOverLightMap != oldValue else { return }
            restyleCallsign()
        }
    }

    /// Re-colours the label and its plate in place.
    ///
    /// The string is rebuilt because attributes are what colour it, and the
    /// width is deliberately *not* recomputed: both styles set the same font at
    /// the same size, so the run measures identically and the frames already
    /// laid out are still right.
    private func restyleCallsign() {
        let look = callsignStyle
        plate.backgroundColor = look.plate

        guard let existing = callsign.attributedText?.string, !existing.isEmpty else { return }
        callsign.attributedText = NSAttributedString(string: existing, attributes: look.attributes)
    }

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

        // Added before the label, so it is behind it. Rounded without
        // `masksToBounds`: nothing is drawn into this view, so the radius
        // applies to a background colour the compositor paints and there is no
        // content to clip. See the note on `plate`.
        plate.isHidden = true
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = Self.callsignRadius
        plate.layer.cornerCurve = .continuous
        addSubview(plate)

        // Alignment and truncation ride in the attributes — see above. What is
        // left here is the one thing the string cannot say: that the label
        // itself paints nothing behind the glyphs, because the plate under it
        // is what does.
        callsign.backgroundColor = .clear
        callsign.isHidden = true
        addSubview(callsign)

        // The plate's colour is the only part of the style that is not carried
        // in the string, so it needs saying once at the start as well as on
        // every later change.
        restyleCallsign()

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
        plate.isHidden = true
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
            plate.isHidden = true
            callsignWidth = 0
        } else {
            let drawn = NSAttributedString(string: trimmed, attributes: callsignStyle.attributes)
            callsign.attributedText = drawn
            callsign.isHidden = false
            plate.isHidden = false
            // Measured here, once, rather than in `layoutMarks` — which also
            // runs whenever the sprite changes, and the text has not.
            //
            // The padding on each side is the plate's inset and the label's
            // safety margin at the same time: `size()` measures a glyph run and
            // rounds, and the old two-point allowance was tight enough that a
            // short measurement truncated the callsign rather than merely
            // crowding it.
            callsignWidth = min(
                ceil(drawn.size().width) + Self.callsignPadding * 2,
                Self.callsignMaxWidth
            )
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
            // Its own height, centred against the logo's, so a label beside a
            // mark lines up with it rather than being a band the same height as
            // a square.
            let inset = (height - Self.callsignHeight) / 2
            let box = CGRect(x: x, y: top + inset, width: textWidth, height: Self.callsignHeight)
            plate.frame = box
            callsign.frame = box
        }
    }

    /// The scale a rasterised layer has to be built at to stay sharp. Zero
    /// while the view has no screen yet, which would cache a one-pixel logo.
    private static func rasterScale(for traits: UITraitCollection) -> CGFloat {
        traits.displayScale > 0 ? traits.displayScale : 3
    }
}
