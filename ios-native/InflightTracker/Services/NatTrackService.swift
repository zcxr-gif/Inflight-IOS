import Combine
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
