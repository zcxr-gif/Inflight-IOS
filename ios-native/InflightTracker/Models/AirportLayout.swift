import CoreLocation
import Foundation

/// A field's pavement: what it is made of and what each piece is called.
///
/// Apple's basemap draws some of this and names none of it, and imagery shows
/// the concrete without telling you which runway you are looking at. This is
/// the part that carries the names — which is the whole reason to draw a field
/// rather than photograph it.
struct AirportLayout {

    struct Piece: Identifiable {

        enum Kind: String {
            case runway
            case taxiway
            case apron
            case terminal

            /// The painted bar across a taxiway where it meets a runway.
            ///
            /// OpenStreetMap calls it `holding_position` and usually records it
            /// as a single node — a point on the taxiway, with no extent and no
            /// direction. What a chart shows is a bar *across* the taxiway, so
            /// the store works the geometry out from the pavement it sits on;
            /// see `AirportLayoutStore.holdShort`.
            case holdShort = "holding_position"

            /// Areas are filled; the rest are drawn as lines down their centre.
            var isArea: Bool { self == .apron || self == .terminal }
        }

        let kind: Kind

        /// `09L/27R`, `A`, `Terminal 5`. Nil for the plenty of pavement nobody
        /// has named.
        let ref: String?

        let coordinates: [CLLocationCoordinate2D]

        /// How wide this pavement really is, in metres, where OpenStreetMap
        /// says so. Nil falls back to what the type usually is — see
        /// `AirportGroundStyle.defaultWidth`.
        let widthMetres: Double?

        let id: String
    }

    let icao: String
    let pieces: [Piece]

    var isEmpty: Bool { pieces.isEmpty }

    var runways: [Piece] { pieces.filter { $0.kind == .runway } }

    var taxiways: [Piece] { pieces.filter { $0.kind == .taxiway } }

    /// Drawn in this order, so a taxiway sits on its apron rather than under
    /// it and a runway sits on top of everything.
    ///
    /// Hold bars come last of all. They are painted on the taxiway in the real
    /// world and they are the one piece of a ground chart you are looking for
    /// under pressure, so nothing gets to cover them.
    static let drawingOrder: [Piece.Kind] = [.apron, .terminal, .taxiway, .runway, .holdShort]
}
