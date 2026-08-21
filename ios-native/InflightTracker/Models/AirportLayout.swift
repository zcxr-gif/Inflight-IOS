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

            /// Areas are filled; the rest are drawn as lines down their centre.
            var isArea: Bool { self == .apron || self == .terminal }
        }

        let kind: Kind

        /// `09L/27R`, `A`, `Terminal 5`. Nil for the plenty of pavement nobody
        /// has named.
        let ref: String?

        let coordinates: [CLLocationCoordinate2D]

        let id: String
    }

    let icao: String
    let pieces: [Piece]

    var isEmpty: Bool { pieces.isEmpty }

    var runways: [Piece] { pieces.filter { $0.kind == .runway } }

    /// Drawn in this order, so a taxiway sits on its apron rather than under
    /// it and a runway sits on top of everything.
    static let drawingOrder: [Piece.Kind] = [.apron, .terminal, .taxiway, .runway]
}
