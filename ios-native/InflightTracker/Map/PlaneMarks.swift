import CoreGraphics

/// The marks that are not aircraft.
///
/// Drawn here rather than taken from the marker packs: an airport pin has to
/// sit exactly on its field and read at 20 points next to an ICAO code, and the
/// packs' own ground marks are a green disc and a placeholder swatch. Same path
/// format as the generated artwork, so they render through the same pipeline.
enum PlaneMarks {

    static let parts: [String: [PlaneArtwork.Part]] = [

        // Map pin with the point at the bottom, and a hole punched through it
        // so it reads as a marker rather than a blob at a glance.
        "airportPin": [
            PlaneArtwork.Part(path: """
            M50 96 C42 82 18 62 18 40 C18 22.3 32.3 8 50 8 C67.7 8 82 22.3 82 40 \
            C82 62 58 82 50 96 Z \
            M38 40 C38 33.4 43.4 28 50 28 C56.6 28 62 33.4 62 40 C62 46.6 56.6 52 50 52 \
            C43.4 52 38 46.6 38 40 Z
            """),
        ],

        // A vehicle from above: a car, with the glass punched out. Drawn
        // rather than taken from the pack, whose ground marker is a
        // placeholder swatch.
        "vehicle": [
            PlaneArtwork.Part(path: """
            M50 2 C64 2 75 10 77 22 L81 58 C82 76 79 92 71 97 L29 97 C21 92 18 76 19 58 \
            L23 22 C25 10 36 2 50 2 Z \
            M36 21 C42 17 58 17 64 21 L68 35 L32 35 Z \
            M32 62 H68 L71 78 H29 Z
            """),
        ],

        // Christmas. A star turns with its heading without ever looking like it
        // is flying sideways, which is more than a sleigh drawn from the side
        // manages on a map that rotates its icons.
        "star": [
            PlaneArtwork.Part(path: """
            M50 0 L62.34 33.01 L97.55 34.55 L69.97 56.49 L79.39 90.45 L50 71 \
            L20.61 90.45 L30.03 56.49 L2.45 34.55 L37.66 33.01 Z
            """),
        ],
    ]
}
