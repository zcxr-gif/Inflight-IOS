import CoreLocation
import Foundation

/// One sample on a flight's path.
///
/// Both sources produce these: the backend's breadcrumb history, and the live
/// feed as it ticks, so the map and the window don't care which part of a path
/// they are looking at.
struct TrackPoint {
    let coordinate: CLLocationCoordinate2D
    let altitudeFeet: Double
    let groundSpeedKnots: Double
    let date: Date?
}
