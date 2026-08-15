import UIKit

/// Single place for the values the tracker depends on.
///
/// The live feed is the same ACARS backend the web tracker talks to
/// (see `old/www/flight.js` -> `ACARS_SOCKET_URL`), so the native app sees
/// exactly the same traffic as the old build.
enum AppConfig {

    /// Socket.IO endpoint broadcasting `all_flights_update`.
    static let socketURLString = "https://site--acars-backend--6dmjph8ltlhv.code.run"

    /// REST backend behind the community aircraft photos.
    static let apiBaseURLString = "https://site--indgo-backend--6dmjph8ltlhv.code.run"

    /// Breadcrumb history for one flight — the path it has already flown.
    /// Same endpoint the Capacitor build fetches (`old/www/flight.js`, where
    /// `LIVE_FLIGHTS_API_URL` has `/flights` swapped for `/api/flights`).
    static func flightHistoryURL(flightId: String) -> URL? {
        guard let encoded = flightId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(socketURLString)/api/flights/\(encoded)/history")
    }

    /// Rooms the backend broadcasts on, joined via `join_server_room`.
    static let servers = ["Expert Server", "Training Server", "Casual Server"]

    static let defaultServer = "Expert Server"

    /// Key used to remember the last picked server between launches.
    static let serverDefaultsKey = "preferredServer"

    /// Upper bound on how many aircraft are handed to MapKit at once. Traffic
    /// is culled to the visible region first, then trimmed to the aircraft
    /// closest to the centre of the map, so a zoomed-out view stays smooth.
    static let maxRenderedFlights = 500

    /// On-screen size of a plane sprite, in points. The web tracker draws its
    /// icons at a uniform ~19px (every sprite is normalised to 128 logical px
    /// and then drawn at `icon-size: 0.15`), so a single size for all types
    /// matches the old look.
    static let iconPointSize: CGFloat = 26

    /// Transparent padding around each sprite. The plane itself stays small,
    /// but the annotation view is big enough to be tapped comfortably.
    static let iconCanvasSize: CGFloat = 44

    /// How long an aircraft that has stopped appearing in the feed keeps its
    /// place on the map.
    ///
    /// The backend drops an aircraft from the odd packet and has it back in the
    /// next one. Removing it the moment it goes missing and adding it again a
    /// few seconds later is the blink that made traffic look like it was
    /// popping in and out; holding its last position for a few packets costs
    /// nothing and covers the gap. Long enough to ride out a stutter, short
    /// enough that an aircraft which has actually landed doesn't hang about.
    static let flightGracePeriod: TimeInterval = 30

    /// Fraction of the visible span, beyond the edge of the screen, within
    /// which an aircraft is added to the map.
    ///
    /// Generous on purpose: the map is loaded well past what it is showing, so
    /// a pan reveals aircraft that are already drawn instead of waiting for the
    /// next cull to put them there.
    static let flightAddMargin: Double = 0.9

    /// The same boundary for *keeping* an aircraft that is already drawn.
    ///
    /// Wider than the add margin, and that gap is the point: with one shared
    /// boundary, an aircraft sitting on it — or the map's own region jittering
    /// across it — flips between added and removed on consecutive passes.
    static let flightKeepMargin: Double = 1.35
}
