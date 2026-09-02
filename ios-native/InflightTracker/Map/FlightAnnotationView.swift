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

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        clipsToBounds = false

        sprite.contentMode = .center
        addSubview(sprite)

        mark.contentMode = .scaleAspectFit
        mark.isHidden = true
        // A logo drawn straight onto the map has no edge of its own, and a
        // white wordmark over a snowfield is nothing at all. The same shadow
        // the ground labels use, for the same reason.
        mark.layer.shadowColor = UIColor.black.cgColor
        mark.layer.shadowOpacity = 0.55
        mark.layer.shadowRadius = 2.5
        mark.layer.shadowOffset = .zero
        addSubview(mark)

        // Lifted from `GroundLabelView`: white with a black halo is what stays
        // legible over a light map, a dark one and satellite imagery alike, and
        // the map already says every other piece of text this way.
        callsign.font = .systemFont(ofSize: 9.5, weight: .heavy)
        callsign.textColor = .white
        callsign.textAlignment = .center
        callsign.layer.shadowColor = UIColor.black.cgColor
        callsign.layer.shadowOpacity = 0.9
        callsign.layer.shadowRadius = 2
        callsign.layer.shadowOffset = .zero
        callsign.isHidden = true
        addSubview(callsign)
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
        callsign.text = nil
        callsign.isHidden = true
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

        callsign.text = trimmed.isEmpty ? nil : trimmed
        callsign.isHidden = trimmed.isEmpty

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

        let textWidth: CGFloat
        if hasText {
            let ideal = callsign.sizeThatFits(
                CGSize(width: .greatestFiniteMagnitude, height: Self.markSide)
            ).width
            // Capped, because a callsign is typed by a pilot and some of them
            // are very long indeed. A band wider than this stops being a label
            // on an aeroplane and starts being a banner across the map.
            textWidth = min(ceil(ideal), 96)
        } else {
            textWidth = 0
        }

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
}
