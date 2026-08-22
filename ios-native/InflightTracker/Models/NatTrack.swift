import CoreLocation
import Foundation

/// One of the North Atlantic organised tracks.
///
/// The track system is republished twice a day — a westbound set for the day
/// crossings and an eastbound set for the night ones — and each track is a
/// lettered string of fixes with a band of flight levels assigned to it. It is
/// the single most useful thing to have on a map of the Atlantic, because it
/// explains why several hundred aircraft are flying in parallel lines.
struct NatTrack: Equatable, Identifiable {

    /// The track letter: A, B, C… westbound, and on round again eastbound.
    let name: String

    /// What the backend calls it — the direction it runs.
    let kind: String?

    /// The fixes, in order, already resolved to coordinates.
    let coordinates: [CLLocationCoordinate2D]

    /// The levels the track is valid at, in each direction. Either can be
    /// empty: a westbound track carries no eastbound levels.
    let eastLevels: [Int]
    let westLevels: [Int]

    /// The path as it was published, for the label and the detail line.
    let fixes: [String]

    var id: String { name }

    var isEastbound: Bool { !eastLevels.isEmpty }

    /// Levels written the way a track message writes them: `340 360 380`.
    var levelsLabel: String? {
        let levels = eastLevels.isEmpty ? westLevels : eastLevels
        guard !levels.isEmpty else { return nil }
        return levels.map(String.init).joined(separator: " ")
    }

    static func == (lhs: NatTrack, rhs: NatTrack) -> Bool {
        lhs.name == rhs.name
            && lhs.fixes == rhs.fixes
            && lhs.eastLevels == rhs.eastLevels
            && lhs.westLevels == rhs.westLevels
    }
}

extension NatTrack {

    /// Reads one point of a published track path.
    ///
    /// The system writes positions two ways and the backend passes both
    /// through untouched, so both are read here:
    ///
    ///   - `58/20` — the shorthand a track message uses, and the trap in it is
    ///     that the longitude is degrees *west* with the sign left off. 58/20
    ///     is 58°N 020°W, not 020°E, and reading it the obvious way puts the
    ///     whole North Atlantic in Kazakhstan.
    ///   - `58N020W` — the same thing written out, sign and all.
    ///
    /// Anything else is a named fix — MALOT, DOGAL, the entry and exit points —
    /// which has no coordinate in the message and cannot be resolved without a
    /// navigation database this app does not carry. Those return nil and are
    /// dropped, which shortens the drawn line at its ends and never bends it.
    static func coordinate(fromPathPoint raw: String) -> CLLocationCoordinate2D? {
        let point = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !point.isEmpty else { return nil }

        if point.contains("/") {
            let parts = point.split(separator: "/")
            guard parts.count == 2,
                  let latitude = Double(parts[0]),
                  let west = Double(parts[1]) else { return nil }
            return validated(latitude: latitude, longitude: -west)
        }

        // Degrees only — the track system does not publish minutes in this
        // form — with the hemisphere letter after each.
        var digits = ""
        var latitude: Double?
        var longitude: Double?

        for character in point {
            if character.isNumber {
                digits.append(character)
                continue
            }

            guard let value = Double(digits) else { return nil }
            digits = ""

            switch character {
            case "N": latitude = value
            case "S": latitude = -value
            case "E": longitude = value
            case "W": longitude = -value
            default: return nil
            }
        }

        guard digits.isEmpty, let latitude = latitude, let longitude = longitude else { return nil }
        return validated(latitude: latitude, longitude: longitude)
    }

    private static func validated(
        latitude: Double,
        longitude: Double
    ) -> CLLocationCoordinate2D? {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
