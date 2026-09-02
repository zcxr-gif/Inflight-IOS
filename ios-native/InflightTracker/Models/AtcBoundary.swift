import CoreLocation
import Foundation

/// One controlled airspace: where its edge is, and where it writes its name.
///
/// The VATSIM FIR/UIR boundary set, which is what the web tracker drew from
/// (`old/www/Boundaries.geojson`, via `old/www/atcHighlights.js`) and what the
/// build tool in `tools/atc-boundaries/` turns into the blob this reads.
struct AtcSector {

    /// The boundary's own identifier — `KZLA`, `EGTT`, `BIRD-E`. Not always a
    /// station name, which is the whole reason the store keeps an alias table.
    let id: String

    /// Where the sector writes its name. The dataset's own cartographic label
    /// point where it has one, which is better than a centroid: an airspace
    /// shaped like a crescent has its centroid in somebody else's.
    let label: CLLocationCoordinate2D

    /// The edge, as one or more closed rings. Several when a sector's airspace
    /// is in disjoint lumps, which a handful of them are.
    let rings: [[CLLocationCoordinate2D]]

    /// The box the whole sector fits in, so a map that cannot see it rejects it
    /// in four comparisons rather than by walking a thousand points.
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    /// Whether any of this sector is inside the region given, to within the
    /// bounding box. Deliberately generous — it is a rejection test, not a
    /// clip.
    func intersects(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double
    ) -> Bool {
        self.minLatitude <= maxLatitude
            && self.maxLatitude >= minLatitude
            && self.minLongitude <= maxLongitude
            && self.maxLongitude >= minLongitude
    }
}

/// A sector with somebody working it.
struct AtcActiveSector: Identifiable {

    let sector: AtcSector

    /// The station as the feed named it, which is what the pilot sees written
    /// on the ATC panel — not the boundary id, which is a fact about the
    /// dataset and would be a different word for the same airspace.
    let station: String

    /// Who is on. Usually one; a split sector can have several.
    let controllers: [String]

    var id: String { sector.id }

    /// What the label on the map says: the station, and who is working it.
    var label: String {
        guard let first = controllers.first else { return station }
        guard controllers.count == 1 else { return "\(station) · \(controllers.count) on" }
        return "\(station) · \(first)"
    }
}

/// The boundary set, read once from the bundle.
///
/// ## Why it is not loaded at launch
///
/// The layer is off by default and behind Pro, so on most launches nothing
/// here is ever wanted. Reading it eagerly would put a fifty-thousand-point
/// decode on every cold start to serve a map layer nobody had asked for. It is
/// therefore loaded the first time somebody actually turns it on, and kept
/// after that — the file is fixed, so the answer cannot go stale.
///
/// ## Why the alias table exists
///
/// This is the part the web build never got right, and the reason its
/// highlighting was unreliable. It matched a controller to a sector by
/// `controller.fir_id` — a field the feed does not send — and otherwise by
/// sweeping every polygon for the controller's own coordinates, which the feed
/// does not send either. What is actually in a packet is a *station name*, and
/// a station name is not a boundary id: Infinite Flight names a centre after a
/// FIR (`BIRD`) or after an airport inside it (`KLAX`), and the boundary set
/// calls those `BIRD` and `KZLA`.
///
/// So the mapping is resolved at build time out of `VATSpy.dat` — the same file
/// the web build shipped and never used for this — and arrives here as a flat
/// table. `KLAX` resolves to Los Angeles Centre; `EGLL` to London; `BIKF` to
/// Reykjavik. No polygon sweeping at all, and nothing to get wrong at runtime.
final class AtcBoundaryStore {

    static let shared = AtcBoundaryStore()

    private let lock = NSLock()
    private var loaded = false
    private var sectors: [AtcSector] = []

    /// Station name, upper-cased, to the sectors it lights. A list because a
    /// FIR split into a north and a south is two boundaries one controller
    /// covers, and lighting both is right.
    private var aliases: [String: [Int]] = [:]

    private init() {}

    /// Every sector with somebody on it, resolved from the ATC panel's own
    /// stations.
    ///
    /// Only centres: a tower works a field, not an airspace, and drawing an
    /// FIR because somebody is on the tower inside it would be a claim nobody
    /// made. The same rule the web build applied (`type === 6`).
    func activeSectors(for stations: [AtcStation]) -> [AtcActiveSector] {
        let centres = stations.filter(\.isCenter)
        guard !centres.isEmpty else { return [] }

        load()

        lock.lock()
        let sectors = self.sectors
        let aliases = self.aliases
        lock.unlock()

        guard !sectors.isEmpty else { return [] }

        // Keyed by sector so two stations resolving to one airspace — which
        // happens on a split FIR — is one highlighted sector with both names on
        // it rather than the same polygon drawn twice.
        var found: [Int: AtcActiveSector] = [:]

        for station in centres {
            let key = station.identifier.uppercased()
            guard let indices = aliases[key] else { continue }

            let controllers = station.facilities
                .filter(\.isCenter)
                .map(\.controller)

            for index in indices where index < sectors.count && !sectors[index].rings.isEmpty {
                if let existing = found[index] {
                    found[index] = AtcActiveSector(
                        sector: existing.sector,
                        station: existing.station,
                        controllers: existing.controllers + controllers
                    )
                } else {
                    found[index] = AtcActiveSector(
                        sector: sectors[index],
                        station: station.identifier,
                        controllers: controllers
                    )
                }
            }
        }

        return found
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// Whether the boundary set is there at all, for a settings row that should
    /// not offer a layer the bundle cannot draw.
    ///
    /// The bundle is asked for the file rather than the store for its contents,
    /// which is the whole point: opening the filters panel must not be what
    /// pays for the decode. A free account browsing the panel would otherwise
    /// read 388 KB and build fifty thousand coordinates to answer a question
    /// about whether a row should be drawn, and never turn the layer on.
    ///
    /// So this answers the cheaper question — is the resource in the app at
    /// all — and a present-but-damaged file is left to `decode`, which reads
    /// short rather than off the end and simply draws fewer sectors. A file
    /// that never made it into the target is the failure worth catching here,
    /// and `codemagic.yaml` now refuses to build one.
    ///
    /// `Bundle.url(forResource:)` hits the bundle's cached resource map, not
    /// the disk, so this is fine to read from a view body.
    var isBundled: Bool {
        Bundle.main.url(forResource: "atc-boundaries", withExtension: "bin") != nil
    }

    // MARK: - Reading the blob

    private func load() {
        lock.lock()
        let alreadyLoaded = loaded
        loaded = true
        lock.unlock()

        guard !alreadyLoaded else { return }

        guard let url = Bundle.main.url(forResource: "atc-boundaries", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            // A missing resource is a build problem. The layer draws nothing
            // and the rest of the map is untouched, which is the right way for
            // one absent file to fail.
            print("[atc] atc-boundaries.bin is missing from the bundle")
            return
        }

        let decoded = Self.decode(data)

        lock.lock()
        sectors = decoded.sectors
        aliases = decoded.aliases
        lock.unlock()
    }

    private static let lonScale = 180.0 / 32767.0
    private static let latScale = 90.0 / 32767.0

    /// See `tools/atc-boundaries/build.py`, which is the other half of this
    /// format. Every length is checked against what is actually in the buffer
    /// rather than trusted: a truncated resource should draw fewer sectors,
    /// never read off the end.
    private static func decode(
        _ data: Data
    ) -> (sectors: [AtcSector], aliases: [String: [Int]]) {
        var sectors: [AtcSector] = []
        var aliases: [String: [Int]] = [:]

        data.withUnsafeBytes { raw in
            guard raw.count >= 8 else { return }
            guard raw[0] == 0x49, raw[1] == 0x46, raw[2] == 0x41, raw[3] == 0x42 else {
                print("[atc] atc-boundaries.bin does not start with IFAB")
                return
            }
            guard raw[4] == 1 else {
                print("[atc] atc-boundaries.bin is version \(raw[4]), which this build cannot read")
                return
            }

            let sectorCount = Int(raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
            var offset = 8

            // Pass one: the directory. Ids, label points and ring lengths, in
            // order — the points themselves are one block at the end.
            var identifiers: [String] = []
            var labels: [(Double, Double)] = []
            var ringLengths: [[Int]] = []
            identifiers.reserveCapacity(sectorCount)
            labels.reserveCapacity(sectorCount)
            ringLengths.reserveCapacity(sectorCount)

            for _ in 0..<sectorCount {
                guard offset < raw.count else { return }
                let nameLength = Int(raw[offset])
                offset += 1
                guard offset + nameLength + 6 <= raw.count else { return }

                var bytes: [UInt8] = []
                bytes.reserveCapacity(nameLength)
                for index in 0..<nameLength { bytes.append(raw[offset + index]) }
                offset += nameLength

                let lon = Double(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)) * lonScale
                let lat = Double(raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)) * latScale
                let ringCount = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt16.self))
                offset += 6

                guard offset + ringCount * 2 <= raw.count else { return }
                var lengths: [Int] = []
                lengths.reserveCapacity(ringCount)
                for index in 0..<ringCount {
                    lengths.append(Int(raw.loadUnaligned(
                        fromByteOffset: offset + index * 2,
                        as: UInt16.self
                    )))
                }
                offset += ringCount * 2

                identifiers.append(String(decoding: bytes, as: UTF8.self))
                labels.append((lat, lon))
                ringLengths.append(lengths)
            }

            // Pass two: the alias table.
            guard offset + 4 <= raw.count else { return }
            let aliasCount = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            offset += 4
            aliases.reserveCapacity(aliasCount)

            for _ in 0..<aliasCount {
                guard offset < raw.count else { return }
                let keyLength = Int(raw[offset])
                offset += 1
                guard offset + keyLength + 2 <= raw.count else { return }

                var bytes: [UInt8] = []
                bytes.reserveCapacity(keyLength)
                for index in 0..<keyLength { bytes.append(raw[offset + index]) }
                offset += keyLength

                let index = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                offset += 2

                aliases[String(decoding: bytes, as: UTF8.self), default: []].append(index)
            }

            // Pass three: every point, one contiguous block in ring order.
            guard offset + 4 <= raw.count else { return }
            let pointCount = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            offset += 4
            guard offset + pointCount * 4 <= raw.count else { return }

            sectors.reserveCapacity(sectorCount)
            var cursor = offset

            for index in 0..<identifiers.count {
                var rings: [[CLLocationCoordinate2D]] = []
                var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0

                for length in ringLengths[index] {
                    var ring: [CLLocationCoordinate2D] = []
                    ring.reserveCapacity(length)
                    for _ in 0..<length {
                        let lon = Double(raw.loadUnaligned(
                            fromByteOffset: cursor,
                            as: Int16.self
                        )) * lonScale
                        let lat = Double(raw.loadUnaligned(
                            fromByteOffset: cursor + 2,
                            as: Int16.self
                        )) * latScale
                        cursor += 4

                        minLat = min(minLat, lat); maxLat = max(maxLat, lat)
                        minLon = min(minLon, lon); maxLon = max(maxLon, lon)
                        ring.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                    if ring.count >= 3 { rings.append(ring) }
                }

                // Appended even when nothing survived, which keeps this array
                // index-aligned with the build tool's numbering — and the alias
                // table is a table of those indices. Dropping a sector here
                // would silently shift every alias after it onto the wrong
                // airspace, which is the kind of wrong that looks like working.
                // A sector with no rings simply draws nothing.
                sectors.append(AtcSector(
                    id: identifiers[index],
                    label: CLLocationCoordinate2D(
                        latitude: labels[index].0,
                        longitude: labels[index].1
                    ),
                    rings: rings,
                    minLatitude: minLat,
                    maxLatitude: maxLat,
                    minLongitude: minLon,
                    maxLongitude: maxLon
                ))
            }
        }

        return (sectors, aliases)
    }
}
