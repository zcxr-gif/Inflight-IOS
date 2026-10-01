import CoreLocation
import UIKit

/// How a field's pavement is drawn.
///
/// ## Why this stopped being a line width in points
///
/// Runways and taxiways were strokes of a fixed number of points — seven and
/// two and a half — which meant a runway was the same thickness on screen at
/// the threshold as it was from the next county. The note that used to sit
/// here defended it: a runway drawn to scale is a hairline from the edge of
/// the field, and this layer has to be readable at both ends.
///
/// That is true and it is not a reason to draw a fixed width, it is a reason
/// to draw a *floor*. Pavement has a real width — a runway is forty-five
/// metres of concrete and a taxiway is twenty-three — and at the zooms where
/// this layer is on at all, that is most of what makes it look like an
/// aerodrome rather than a diagram of one. So it is drawn to scale, and the
/// scale is clamped so it never falls below something you can see.
///
/// On the map that is a zoom expression evaluated on the GPU for every frame
/// of a pinch — see `MapLayerStyle.groundWidth` — so the runway grows with the
/// fingers rather than on the settle.
///
/// ## And why it asks what the map is made of
///
/// Grey pavement on grey cartography is a drawing. Grey pavement on a
/// photograph of the same pavement is a smear over the thing it is describing.
/// Imagery already contains the concrete, in the right place and the right
/// shape, so over imagery this draws almost nothing: an edge to catch the
/// light and the markings that a photograph cannot give you — the designators,
/// the letters, the hold bars.
enum AirportGroundStyle {

    // MARK: Widths

    /// What a piece of pavement is, in metres, when OpenStreetMap does not say.
    ///
    /// A code-E runway is forty-five metres and a code-C taxiway twenty-three,
    /// which is what the great majority of the fields anybody watches are built
    /// to. Where OSM carries a `width` it is used instead and this is not
    /// consulted.
    static func defaultWidth(for kind: AirportLayout.Piece.Kind) -> CLLocationDistance {
        switch kind {
        case .runway: return 45
        case .taxiway: return 23
        case .holdShort: return 1.5
        case .apron, .terminal: return 0
        }
    }

    /// The narrowest a piece may be drawn on screen, in points.
    ///
    /// The floor under the scale. Pulled back far enough, true width goes to
    /// nothing and the field would disappear before the map stopped drawing
    /// it — so past that point these stop being scale drawings and become
    /// marks, which is the same bargain a paper chart makes.
    static func minimumPoints(for kind: AirportLayout.Piece.Kind) -> CGFloat {
        switch kind {
        case .runway: return 3
        case .taxiway: return 1.4
        case .holdShort: return 2.2
        case .apron, .terminal: return 0
        }
    }

    // MARK: Looks

    /// What the map underneath is made of, as far as this layer cares.
    ///
    /// Three cases rather than one per palette, because pavement only has
    /// three questions to answer: am I drawing on light paper, on dark paper,
    /// or on a photograph of the ground itself.
    enum Ground {
        case light
        case dark
        case imagery

        init(_ look: MapLook, isLight: Bool) {
            if look.resolvedPalette.usesImagery {
                self = .imagery
            } else {
                self = isLight ? .light : .dark
            }
        }

        /// Whether the concrete is already on the map and only wants marking
        /// rather than painting.
        var isPhotographic: Bool { self == .imagery }
    }

    /// The body of a runway or taxiway.
    static func fill(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isRunway = kind == .runway

        switch ground {
        case .light:
            return UIColor(white: 0.36, alpha: isRunway ? 0.55 : 0.34)
        case .dark:
            return UIColor(white: 0.78, alpha: isRunway ? 0.34 : 0.22)
        case .imagery:
            // Nothing over the photograph. The pavement in the picture is the
            // pavement, and a wash across it only takes the detail off it.
            return .clear
        }
    }

    /// The line round the edge of it.
    ///
    /// On cartography this is what keeps a runway from bleeding into the
    /// taxiway beside it. On imagery it is the whole of the drawing: a thin
    /// bright edge that says *this* strip of the photograph is the runway,
    /// without covering any of it.
    static func edge(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isRunway = kind == .runway

        switch ground {
        case .light:
            return UIColor(white: 0.20, alpha: isRunway ? 0.42 : 0.24)
        case .dark:
            return UIColor(white: 0.96, alpha: isRunway ? 0.34 : 0.20)
        case .imagery:
            return UIColor(white: 1, alpha: isRunway ? 0.72 : 0.42)
        }
    }

    /// How thick that edge is, in points. Screen-constant: an outline is a
    /// mark on the map rather than a thing on the ground with a size.
    static func edgePoints(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> CGFloat {
        guard kind == .runway || kind == .taxiway else { return 0 }
        if ground.isPhotographic { return kind == .runway ? 1.1 : 0.7 }
        return kind == .runway ? 0.8 : 0.5
    }

    /// The dashed stripe down the middle of a runway.
    ///
    /// The one piece of real runway marking worth drawing, and the thing that
    /// makes a grey slab read as a runway at a glance. Skipped on taxiways —
    /// their centreline is yellow and continuous in life, and at these sizes
    /// it would only be a second line inside a line two points wide.
    static func centreline(on ground: Ground) -> UIColor {
        switch ground {
        case .light: return UIColor(white: 1, alpha: 0.60)
        case .dark: return UIColor(white: 1, alpha: 0.45)
        case .imagery: return UIColor(white: 1, alpha: 0.55)
        }
    }

    /// Aprons and terminals, which are areas rather than runs.
    static func area(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isTerminal = kind == .terminal

        switch ground {
        case .light:
            return UIColor(white: 0.30, alpha: isTerminal ? 0.20 : 0.12)
        case .dark:
            return UIColor(white: 0.92, alpha: isTerminal ? 0.18 : 0.10)
        case .imagery:
            // A terminal is a building and reads as one from above; an apron is
            // just more concrete. Only the building is worth outlining, and
            // even that faintly.
            return isTerminal ? UIColor(white: 1, alpha: 0.10) : .clear
        }
    }

    /// The bar across a taxiway where it meets a runway.
    ///
    /// Yellow on every one of the three grounds. It is the one thing on this
    /// layer that is not describing where the concrete is but what you are
    /// told to do on it, and it is yellow in life for exactly that reason.
    static let holdBar = UIColor(red: 0.98, green: 0.78, blue: 0.16, alpha: 0.95)
}
