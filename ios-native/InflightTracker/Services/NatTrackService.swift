import Combine
import CoreLocation
import Foundation

/// The North Atlantic track system, from the same backend the feed comes from.
///
/// `/api/live/tracks` is what the web tracker read (`old/www/natTracksLayer.js`),
/// and it answers `{ ok, tracks: [{ name, type, path, eastLevels, westLevels }] }`
/// with the path as the published string of fixes.
///
/// The set changes twice a day, so this is fetched once when the layer is
/// switched on and then left alone for an hour. Nothing about it is worth a
/// request on the packet clock.
final class NatTrackService: ObservableObject {

    static let shared = NatTrackService()

    @Published private(set) var tracks: [NatTrack] = []

    /// Set once a fetch has come back, whatever it came back with — so the map
    /// can tell "no tracks published" apart from "not asked yet", and the panel
    /// can say the right one.
    @Published private(set) var hasAnswered = false

    /// Two publications a day, and a track set that is valid for hours. An
    /// hour between asks is still far more often than the data changes.
    private static let lifetime: TimeInterval = 60 * 60

    private var lastFetch: Date?
    private var isFetching = false

    private init() {}

    /// Fetch if stale. Safe to call on every packet — a date comparison until
    /// the hour is up.
    func refresh(force: Bool = false) {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < Self.lifetime {
            return
        }
        guard !isFetching, let url = AppConfig.natTracksURL else { return }

        isFetching = true

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            let parsed = Self.parse(data)

            DispatchQueue.main.async {
                self.isFetching = false
                self.lastFetch = Date()
                self.hasAnswered = true
                // A failed fetch keeps whatever is drawn: the track set is
                // valid for hours, so yesterday's answer beats an empty map.
                guard let parsed = parsed else { return }
                self.tracks = parsed
            }
        }.resume()
    }

    // MARK: - Which track an aircraft is flying

    /// The track an aircraft is flying, if it is flying one.
    ///
    /// Four things together, because any one of them alone is common over the
    /// Atlantic without the aircraft being on a track: within `lateralLimitNM`
    /// of the track's line, heading along it rather than across or against
    /// it, in the flight levels, and inside the track's published band of
    /// levels when it has one. The lateral limit is well under the spacing
    /// between neighbouring tracks, so an aircraft is never on two at once.
    func track(for flight: Flight) -> NatTrack? {
        guard flight.origin == .infiniteFlight, flight.altitudeFeet >= 25_000 else { return nil }
        let position = flight.coordinate
        for track in tracks where Self.isFlying(track, at: position, heading: flight.heading, altitudeFeet: flight.altitudeFeet) {
            return track
        }
        return nil
    }

    /// Whether a position is somewhere the track system could apply at all —
    /// worth fetching it for, when the map layer is off and nothing else has.
    static func covers(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (30...72).contains(coordinate.latitude) && (-80...0).contains(coordinate.longitude)
    }

    private static let lateralLimitNM = 12.0
    private static let headingLimitDegrees = 30.0
    private static let earthRadiusNM = 3440.065

    private static func isFlying(
        _ track: NatTrack,
        at position: CLLocationCoordinate2D,
        heading: Double,
        altitudeFeet: Double
    ) -> Bool {
        let levels = (track.eastLevels.isEmpty ? track.westLevels : track.eastLevels)
            .map { $0 < 1000 ? $0 * 100 : $0 }
        if let low = levels.min(), let high = levels.max(),
           altitudeFeet < Double(low) - 1000 || altitudeFeet > Double(high) + 1000 {
            return false
        }

        let fixes = track.coordinatesInFlightOrder
        for (start, end) in zip(fixes, fixes.dropFirst()) {
            let legBearing = FlightProgress.bearingDegrees(from: start, to: end)
            let offset = abs((heading - legBearing + 540).truncatingRemainder(dividingBy: 360) - 180)
            guard offset <= headingLimitDegrees else { continue }

            // Cross-track and along-track distance on the sphere: how far off
            // the leg's great circle the aircraft is, and how far along it.
            let legLength = angularDistance(start, end)
            let toAircraft = angularDistance(start, position)
            let toAircraftBearing = FlightProgress.bearingDegrees(from: start, to: position)
            let delta = (toAircraftBearing - legBearing) * .pi / 180
            let crossTrack = asin(sin(toAircraft) * sin(delta))
            guard abs(crossTrack) * earthRadiusNM <= lateralLimitNM, cos(delta) >= 0 || toAircraft < 1e-6 else { continue }
            let alongTrack = acos(min(max(cos(toAircraft) / max(cos(crossTrack), 1e-9), -1), 1))
            if alongTrack <= legLength { return true }
        }
        return false
    }

    /// The angle between two points at the centre of the earth, in radians.
    private static func angularDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Nil for a response that could not be read at all, which is held apart
    /// from an empty list — the track system genuinely has quiet periods
    /// between publications, and that is not a failure.
    private static func parse(_ data: Data?) -> [NatTrack]? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // `ok: false` is the backend saying it has nothing, not a broken
        // response — so it reads as an empty set.
        if let ok = root["ok"] as? Bool, !ok { return [] }

        guard let raw = root["tracks"] as? [[String: Any]] else { return nil }

        var out: [NatTrack] = []
        for item in raw {
            guard let name = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }

            let fixes = (item["path"] as? [String]) ?? []
            let coordinates = fixes.compactMap(NatTrack.coordinate(fromPathPoint:))
            // One point is not a line. A track whose whole path is named fixes
            // this app cannot resolve is a track it cannot draw.
            guard coordinates.count >= 2 else { continue }

            out.append(
                NatTrack(
                    name: name.uppercased(),
                    kind: item["type"] as? String,
                    coordinates: coordinates,
                    eastLevels: levels(item["eastLevels"]),
                    westLevels: levels(item["westLevels"]),
                    fixes: fixes
                )
            )
        }

        return out
    }

    /// Levels have arrived as numbers and as strings from this backend before,
    /// which is why they are not simply cast.
    private static func levels(_ raw: Any?) -> [Int] {
        guard let items = raw as? [Any] else { return [] }
        return items.compactMap { value in
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
    }
}
