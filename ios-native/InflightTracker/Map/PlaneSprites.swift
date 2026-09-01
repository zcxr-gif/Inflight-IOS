import UIKit

/// The aircraft marks on the map.
///
/// Every icon is drawn from vector artwork at the size, colour and screen scale
/// it is actually wanted at. It used to be cut out of `markers.png`, a 1024x512
/// sheet whose sprites are around 32 pixels square — fine on the web build it
/// came from, soft on a phone that draws them at three device pixels to the
/// point, and impossible to recolour as anything other than a flat blob.
///
/// The shapes themselves come from Virtual Radar Server's markers (BSD) and the
/// community pack written to extend them (CC0); `PlaneArtwork` carries the
/// notices. What that set gives up is a distinct outline per airliner variant —
/// an A320 and a 737 are both `medium2jet` — which is a distinction that does
/// not survive 26 points on a map anyway. What it gives back is engine count,
/// jets against props, and a size that tracks the real aircraft.
///
/// All access happens on the main thread (MapKit delegate callbacks and
/// SwiftUI body evaluation).
final class PlaneSprites {

    static let shared = PlaneSprites()

    /// What a drawn icon is filed under.
    ///
    /// A struct rather than an interpolated string, because this is looked up
    /// once per aircraft that has turned since the last packet — a few hundred
    /// times a second on a busy server — and building the key was costing two
    /// string allocations every time, to look up something that was already
    /// there.
    private struct IconKey: Hashable {
        let sprite: String
        /// The body colour, packed, so two colours a floating-point hair apart
        /// are the same key. They arrive here from a `Color` round-tripped
        /// through user defaults, and without the rounding a slider drag would
        /// mint a new cache entry per frame.
        let body: UInt32
        let pointSize: CGFloat
        let padded: Bool
    }

    private var cache: [IconKey: UIImage] = [:]

    /// The planet's own icons, filed separately: they carry an outline colour
    /// the map's never varies, and mixing the two would mean a key with a field
    /// in it that only one caller ever sets.
    private struct PlanetIconKey: Hashable {
        let sprite: String
        let body: UInt32
        let outline: UInt32
        let pointSize: CGFloat
    }

    private var planetCache: [PlanetIconKey: UIImage] = [:]

    private init() {}

    /// Whether the artwork is present. Kept for the settings panel, which
    /// surfaces it: it used to catch a sprite sheet missing from the bundle,
    /// and now catches a botched regeneration of `PlaneArtwork`.
    var isReady: Bool { !PlaneArtwork.parts.isEmpty }

    // MARK: Colours

    private enum Palette {
        /// Traffic. Light body, dark outline — the pairing that holds up on a
        /// dark map, a light one and satellite imagery alike.
        static let body = UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        static let outline = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)

        /// The aircraft the sheet is open on. Was a second set of red sprites
        /// on the sheet; now it is the same drawing in another colour.
        static let selected = UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1)

        /// The same three, as the integers the cache is keyed on.
        ///
        /// `packed` is four `getRed`-family calls into UIKit and a rounding
        /// apiece, and the planet asks for an icon *per aircraft per frame* —
        /// three thousand times a second at a busy zoom, to arrive at three
        /// numbers that were decided when this file was written. Worked out
        /// once here instead; a tint, which is a colour that genuinely varies,
        /// still packs itself.
        static let bodyPacked = body.packed
        static let outlinePacked = outline.packed
        static let selectedPacked = selected.packed

        /// A field with someone working it, against one without.
        static let controlledField = UIColor(red: 0.36, green: 0.68, blue: 1.00, alpha: 1)
        static let field = UIColor(white: 0.97, alpha: 1)
    }

    // MARK: Public API

    /// Icon for an aircraft, padded into a larger transparent canvas so the
    /// annotation stays easy to tap while the aircraft itself stays small.
    ///
    /// `tint` repaints the body for the aircraft the user has asked to pick out
    /// — their own, and the pilots they watch — leaving the outline alone so a
    /// dark colour still reads against a dark map.
    func icon(forKey key: String, selected: Bool, tint: UIColor? = nil) -> UIImage? {
        let body = tint ?? (selected ? Palette.selected : Palette.body)
        let cacheKey = IconKey(
            sprite: key,
            body: body.packed,
            pointSize: AppConfig.iconPointSize,
            padded: true
        )
        if let cached = cache[cacheKey] { return cached }

        guard let mark = mark(forKey: key) else { return nil }

        let image = PlaneIconRenderer.image(
            mark,
            pointSize: AppConfig.iconPointSize,
            canvas: CGSize(width: AppConfig.iconCanvasSize, height: AppConfig.iconCanvasSize),
            body: body,
            outline: Palette.outline,
            shadow: true
        )

        cache[cacheKey] = image
        return image
    }

    /// The mark on its own, with no padding around it.
    ///
    /// The padded variant exists so an aircraft stays small while its
    /// annotation stays tappable. An airport marker sizes its own image view
    /// and wants the drawing to fill it.
    func rawIcon(forKey key: String, pointSize: CGFloat) -> UIImage? {
        let cacheKey = IconKey(
            sprite: key,
            body: Palette.body.packed,
            pointSize: pointSize,
            padded: false
        )
        if let cached = cache[cacheKey] { return cached }

        guard let mark = mark(forKey: key) else { return nil }

        let image = PlaneIconRenderer.image(
            mark,
            pointSize: pointSize,
            canvas: CGSize(width: pointSize, height: pointSize),
            body: Palette.body,
            outline: Palette.outline,
            shadow: true
        )

        cache[cacheKey] = image
        return image
    }

    /// The map's aircraft, drawn for the planet.
    ///
    /// Deliberately the same artwork in the same two colours the flat map uses,
    /// because that is the entire point of drawing aeroplanes rather than dots:
    /// you already know what a 380 looks like on this map, and a globe that
    /// paints them some other colour is a globe whose traffic you have to learn
    /// twice. `tint` and `selected` are the only two things allowed to change
    /// that, and they are the two the map changes as well — a watched pilot's
    /// colour, and the amber for the aircraft whose window is open.
    ///
    /// What differs from `icon(forKey:selected:tint:)` is only the packaging:
    /// a canvas cut to the mark itself, and any point size. The map's icons sit
    /// at `AppConfig.iconPointSize` inside a canvas twice that wide, padding
    /// that exists so an `MKAnnotationView` stays easy to tap. The planet draws
    /// into a `CGContext` where that padding is dead pixels blitted per
    /// aircraft, several hundred times a frame — so here the canvas is the mark
    /// plus exactly the room the outline and the shadow need, and no more.
    ///
    /// Cached the same way, so a packet of three thousand aircraft over a dozen
    /// airframe types renders a dozen bitmaps and then blits them.
    func planetIcon(
        forKey key: String,
        pointSize: CGFloat,
        body tint: UIColor? = nil,
        selected: Bool = false
    ) -> UIImage? {
        let body = tint ?? (selected ? Palette.selected : Palette.body)
        let bodyPacked = tint?.packed
            ?? (selected ? Palette.selectedPacked : Palette.bodyPacked)

        // Whole points, so a zoom that scales the traffic cannot mint a cache
        // entry per frame.
        let size = max(6, pointSize.rounded())
        let cacheKey = PlanetIconKey(
            sprite: key,
            body: bodyPacked,
            outline: Palette.outlinePacked,
            pointSize: size
        )
        if let cached = planetCache[cacheKey] { return cached }

        guard let mark = mark(forKey: key) else { return nil }

        // The fleet table paints a few marks a colour of their own — the
        // airport pins — and on the planet that would be an airport-coloured
        // aeroplane. The body colour wins here.
        var flat = mark
        flat.body = nil

        // No canvas, so the bitmap is fitted to the mark.
        //
        // It used to be a square of `size`, and `size` is what the *shape* is
        // scaled to — before `mark.scale`, which runs to 1.18 on a 380, and
        // before the outline and the shadow, which stand outside the shape
        // again. So the bitmap was smaller than the drawing on it and the
        // drawing was cropped: a flat nose and a flat tail on every heavy on
        // the planet, and worst on the aircraft whose window is open, which is
        // drawn at 1.45 and is the one being looked at.
        //
        // Fitted rather than simply padded, because these are blitted per
        // aircraft per frame and a square canvas around a shape that is not
        // square is transparent pixels composited several hundred times over.
        // Nothing moves: the mark is still drawn at `size`, still centred on
        // the aeroplane's position.
        let image = PlaneIconRenderer.image(
            flat,
            pointSize: size,
            body: body,
            outline: Palette.outline,
            // The same drop shadow the map's traffic carries, so an aeroplane
            // sits above the planet rather than in it. Rendered once into the
            // cached bitmap, so it costs a blit rather than a shadow pass.
            shadow: true
        )

        planetCache[cacheKey] = image
        return image
    }

    // MARK: Resolution

    private func mark(forKey key: String) -> PlaneIconRenderer.Mark? {
        guard let entry = Self.fleet[key] ?? Self.fleet["TRIANGLE"] else { return nil }
        guard let parts = PlaneArtwork.parts[entry.art] ?? PlaneMarks.parts[entry.art] else { return nil }
        return PlaneIconRenderer.Mark(parts: parts, scale: entry.scale, body: entry.body)
    }

    /// Sprite key to artwork, with the size that key draws at.
    ///
    /// Scales follow the real aircraft, roughly: a 380 against a Cessna is
    /// about the ratio of their wingspans, pulled in toward the middle so the
    /// small ones stay legible at the size these are drawn.
    private static let fleet: [String: (art: String, scale: CGFloat, body: UIColor?)] = [

        // Narrowbodies
        "A318": ("medium2jet", 0.95, nil),
        "A319": ("medium2jet", 0.98, nil),
        "A320": ("medium2jet", 1.00, nil),
        "A321": ("medium2jet", 1.02, nil),
        "B737": ("medium2jet", 1.00, nil),
        "B757": ("medium2jet", 1.04, nil),
        "E190": ("medium2jet", 0.95, nil),

        // Widebodies
        "A300": ("heavy2jet", 1.05, nil),
        "A330": ("heavy2jet", 1.08, nil),
        "A337": ("heavy2jet", 1.10, nil),
        "A350": ("heavy2jet", 1.10, nil),
        "B767": ("heavy2jet", 1.05, nil),
        "B777": ("heavy2jet", 1.11, nil),
        "B787": ("heavy2jet", 1.08, nil),

        // Four engines
        "A340": ("a340", 1.11, nil),
        "A380": ("a380", 1.18, nil),
        "B747": ("heavy4jet", 1.14, nil),
        "RJ100": ("medium4jet", 0.95, nil),
        "KC35R": ("b707", 1.03, nil),
        "R135": ("b707", 1.05, nil),
        "E3CF": ("e3", 1.06, nil),
        "B52": ("b52", 1.10, nil),
        "C17": ("c17", 1.10, nil),

        // Rear-engined jets
        "MD80": ("rearjet", 1.00, nil),
        "FOKKER100": ("rearjet", 0.94, nil),
        "PRIVATEJET": ("bizjet", 0.89, nil),

        // Propellers
        "A400": ("a400", 1.05, nil),
        "C130": ("turboprop4", 1.00, nil),
        "LANC": ("lancaster", 0.98, nil),
        "AT42": ("turboprop2", 0.89, nil),
        "AT72": ("turboprop2", 0.92, nil),
        "DASH8": ("turboprop2", 0.94, nil),
        "Q4": ("turboprop2", 0.94, nil),
        "TWINPROP": ("light2prop", 0.79, nil),
        "PC12": ("light1prop", 0.76, nil),
        "SINGLEPROP": ("light1prop", 0.71, nil),
        "PA28": ("light1prop", 0.70, nil),
        "SPIT": ("spitfire", 0.76, nil),

        // Fast jets
        "F16": ("f16", 0.81, nil),
        "F35": ("f35", 0.82, nil),
        "RC-22": ("f15", 0.86, nil),
        "EUFI": ("eufi", 0.82, nil),
        "TOR": ("tornado", 0.84, nil),
        "HAWK": ("hawk", 0.76, nil),
        "T38": ("trainer", 0.78, nil),

        // High and slow
        "U2": ("u2", 0.94, nil),
        "GLIDER": ("glider", 0.87, nil),
        "BALLOON": ("balloon", 0.76, nil),

        // Rotary
        "EUROCOPTER": ("helicopter", 0.79, nil),
        "H60": ("helicopter", 0.86, nil),
        "LYNX": ("helicopter", 0.81, nil),
        "PUMA": ("helicopter", 0.86, nil),
        "H64": ("apache", 0.84, nil),
        "EH10": ("eh101", 0.89, nil),
        "CHINOOK": ("chinook", 0.94, nil),

        // Everything else
        "DRONE": ("drone", 0.82, nil),
        "RECEIVER": ("tower", 0.82, nil),
        "VEHICLE": ("vehicle", 0.70, nil),
        "SANTA": ("star", 0.84, nil),
        "TRIANGLE": ("generic", 0.88, nil),

        // Fields. Their own colours: the pins are read against the traffic
        // rather than as part of it, and a staffed field is the one worth
        // picking out.
        "AIRPORT_LARGE": ("airportPin", 0.72, Palette.controlledField),
        "AIRPORT_SMALL": ("airportPin", 0.60, Palette.field),
    ]
}

private extension UIColor {

    /// This colour as one integer, for use in a cache key.
    ///
    /// Rounded to the nearest 1/255 on purpose: colours arrive here from a
    /// `Color` round-tripped through user defaults, and two that are a
    /// floating-point hair apart are the same colour to look at. Without the
    /// rounding a slider drag would mint a new cache entry per frame.
    var packed: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            // A pattern or an unconvertible space, which none of the palette
            // is. Distinct from every real colour, and stable.
            return .max
        }
        let channel = { (value: CGFloat) in
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return channel(red) << 24 | channel(green) << 16 | channel(blue) << 8 | channel(alpha)
    }
}
