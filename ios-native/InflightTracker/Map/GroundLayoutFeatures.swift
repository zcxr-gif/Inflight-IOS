import CoreLocation
import MapboxMaps
import UIKit

/// A field's pavement as GeoJSON: aprons and terminals as areas, the runs of
/// pavement as lines carrying their real width, and the runway designators and
/// taxiway letters as points.
///
/// Shared by the main map and the gate picker, which draw the same field the
/// same way — the picker over imagery, where the concrete is outlined rather
/// than painted. See `MapLayerStyle` for the layers these feed.
enum GroundLayoutFeatures {

    /// A field's pavement as features: aprons and terminals as areas, the
    /// runs of pavement as lines carrying their real width, and the
    /// runway designators and taxiway letters as points.
    static func features(
        for layout: AirportLayout,
        on ground: AirportGroundStyle.Ground,
        latitude: Double
    ) -> [Feature] {
        // Pixels one metre covers at zoom zero, at this field. The layer
        // multiplies it up by the zoom on the GPU.
        let scale = 512 / (40_075_016.686 * max(cos(latitude * .pi / 180), 0.01))

        var features: [Feature] = []

        // Aprons first, runways last, so the pieces stack the way the
        // concrete does.
        for kind in AirportLayout.drawingOrder {
            for piece in layout.pieces where piece.kind == kind {
                let coordinates = piece.coordinates
                if kind.isArea {
                    guard coordinates.count >= 3 else { continue }
                    features.append(polygon([coordinates], [
                        "kind": .string(kind.rawValue),
                        "fill": .string(MapLayerStyle.rgba(AirportGroundStyle.area(for: kind, on: ground))),
                    ]))
                    continue
                }

                guard coordinates.count >= 2 else { continue }
                let width = piece.widthMetres ?? AirportGroundStyle.defaultWidth(for: kind)
                features.append(line(coordinates, [
                    "kind": .string(kind.rawValue),
                    "width": .number(width),
                    "scale": .number(scale),
                    "minimum": .number(Double(AirportGroundStyle.minimumPoints(for: kind))),
                    "fill": .string(MapLayerStyle.rgba(AirportGroundStyle.fill(for: kind, on: ground))),
                    "edge": .string(MapLayerStyle.rgba(AirportGroundStyle.edge(for: kind, on: ground))),
                    "edgeWidth": .number(Double(AirportGroundStyle.edgePoints(for: kind, on: ground))),
                    "centre": .string(MapLayerStyle.rgba(AirportGroundStyle.centreline(on: ground))),
                ]))
            }
        }

        for runway in layout.runways {
            guard let ref = runway.ref, let centre = midpoint(of: runway.coordinates) else { continue }
            features.append(groundLabel(GroundLabel(coordinate: centre, text: ref, kind: .runway)))
        }

        // And the alphabet between them, one letter per way, which puts it
        // along the taxiway rather than once in the middle of it. Short
        // stubs are skipped: a ten-metre link between two stands is not a
        // piece of taxiway anybody navigates by.
        var lettered = 0
        for taxiway in layout.taxiways {
            guard lettered < maximumTaxiwayLabels else { break }
            guard let ref = taxiway.ref,
                  let centre = midpoint(of: taxiway.coordinates),
                  length(of: taxiway.coordinates) >= shortestLetteredTaxiway
            else { continue }
            features.append(groundLabel(GroundLabel(coordinate: centre, text: ref, kind: .taxiway)))
            lettered += 1
        }

        return features
    }

    private static func groundLabel(_ label: GroundLabel) -> Feature {
        let isRunway = label.kind == .runway
        return point(label.coordinate, [
            "text": .string(label.text),
            // A chart letters its taxiways quietly between runways it
            // numbers loudly — and the letters give way first.
            "size": .number(isRunway ? 10.5 : 9),
            "alpha": .number(isRunway ? 1 : 0.85),
            "rank": .number(isRunway ? 0 : 1),
        ])
    }

    /// How short a taxiway can be and still be worth a letter, in nautical
    /// miles. About a hundred metres.
    private static let shortestLetteredTaxiway: Double = 0.054

    /// And how many letters a field gets at most — a guard against a
    /// mis-tagged import, not a target.
    private static let maximumTaxiwayLabels = 240

    private static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<coordinates.count {
            total += FlightProgress.distanceNM(from: coordinates[index - 1], to: coordinates[index])
        }
        return total
    }

    /// The point halfway *along* the way rather than the average of its
    /// nodes: a runway mapped with a cluster of nodes at one end would
    /// otherwise carry its label off-centre.
    private static func midpoint(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return coordinates.first }

        var lengths: [Double] = []
        var total = 0.0
        for index in 1..<coordinates.count {
            total += FlightProgress.distanceNM(from: coordinates[index - 1], to: coordinates[index])
            lengths.append(total)
        }
        guard total > 0 else { return coordinates.first }

        let half = total / 2
        for (index, run) in lengths.enumerated() where run >= half {
            let previous = index == 0 ? 0 : lengths[index - 1]
            let segment = run - previous
            let fraction = segment > 0 ? (half - previous) / segment : 0
            let from = coordinates[index]
            let to = coordinates[index + 1]
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                longitude: from.longitude + (to.longitude - from.longitude) * fraction
            )
        }
        return coordinates.last
    }

    private static func point(_ coordinate: CLLocationCoordinate2D, _ properties: JSONObject) -> Feature {
        var feature = Feature(geometry: .point(Point(coordinate)))
        feature.properties = properties
        return feature
    }

    private static func line(_ coordinates: [CLLocationCoordinate2D], _ properties: JSONObject) -> Feature {
        var feature = Feature(geometry: .lineString(LineString(coordinates)))
        feature.properties = properties
        return feature
    }

    private static func polygon(_ rings: [[CLLocationCoordinate2D]], _ properties: JSONObject) -> Feature {
        let closed = rings.map { ring -> [CLLocationCoordinate2D] in
            guard let first = ring.first, let last = ring.last,
                  first.latitude != last.latitude || first.longitude != last.longitude
            else { return ring }
            return ring + [first]
        }
        var feature = Feature(geometry: .polygon(Polygon(closed)))
        feature.properties = properties
        return feature
    }
}
