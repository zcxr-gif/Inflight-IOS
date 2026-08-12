import UIKit

/// Single place for the values the tracker depends on.
///
/// The live feed is the same ACARS backend the web tracker talks to
/// (see `old/www/flight.js` -> `ACARS_SOCKET_URL`), so the native app sees
/// exactly the same traffic as the old build.
enum AppConfig {

    /// Socket.IO endpoint broadcasting `all_flights_update`.
    static let socketURLString = "https://site--acars-backend--6dmjph8ltlhv.code.run"

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

    /// Aircraft older than this are dropped from the map.
    static let staleFlightInterval: TimeInterval = 300
}
