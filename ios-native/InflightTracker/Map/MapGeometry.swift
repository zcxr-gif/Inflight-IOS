import CoreLocation
import Foundation

/// Spherical Mercator, as plain arithmetic.
///
/// ## Why the app carries its own
///
/// MapKit used to supply this — `MKMapPoint`, `MKMapRect` and
/// `MKMapPointsPerMeterAtLatitude` — and most of the weather code was written
/// against them, because it was the one space in which a map's transform is a
/// scale and a translate. The map is Mapbox now and MapKit is gone from the
/// app, but the geometry is not MapKit's to begin with: it is Web Mercator,
/// which is two lines of trigonometry and the same projection Mapbox draws in.
///
/// So the types are kept, under names of their own, with the same units
/// MapKit used — a world `2^28` points across — so every constant the weather
/// layers were tuned against means exactly what it meant before.
struct MercatorPoint: Equatable {

    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Projects a coordinate. Latitudes past Mercator's edge are clamped to
    /// it, which is where every map stops drawing anyway.
    init(_ coordinate: CLLocationCoordinate2D) {
        let world = MercatorRect.worldSide
        let latitude = min(max(coordinate.latitude, -MercatorRect.maximumLatitude), MercatorRect.maximumLatitude)
        let radians = latitude * .pi / 180

        x = (coordinate.longitude + 180) / 360 * world
        y = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * world
    }

    /// Back to a coordinate.
    var coordinate: CLLocationCoordinate2D {
        let world = MercatorRect.worldSide
        let longitude = x / world * 360 - 180
        let n = Double.pi - 2 * Double.pi * y / world
        let latitude = atan(sinh(n)) * 180 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Ground distance in metres, along the great circle between the two
    /// coordinates — the same answer `MKMapPoint.distance(to:)` gave.
    func distance(to other: MercatorPoint) -> CLLocationDistance {
        let a = coordinate
        let b = other.coordinate
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * GreatCircle.earthRadius * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// How many projected points one metre on the ground covers at a latitude.
    static func perMetre(atLatitude latitude: CLLocationDegrees) -> Double {
        let clamped = min(max(latitude, -MercatorRect.maximumLatitude), MercatorRect.maximumLatitude)
        let circumference = 2 * Double.pi * 6_378_137 * cos(clamped * .pi / 180)
        guard circumference > 0 else { return 0 }
        return MercatorRect.worldSide / circumference
    }
}

struct MercatorSize: Equatable {
    var width: Double
    var height: Double
}

/// A rectangle in projected points.
struct MercatorRect: Equatable {

    /// The width and height of the whole world, in projected points. MapKit's
    /// figure, so everything tuned against MapKit's units still holds.
    static let worldSide: Double = 268_435_456

    /// Where Mercator gives up on latitude.
    static let maximumLatitude: Double = 85.051_128_78

    var origin: MercatorPoint
    var size: MercatorSize

    init(origin: MercatorPoint, size: MercatorSize) {
        self.origin = origin
        self.size = size
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = MercatorPoint(x: x, y: y)
        self.size = MercatorSize(width: width, height: height)
    }

    static let world = MercatorRect(x: 0, y: 0, width: worldSide, height: worldSide)

    /// The empty rectangle, which `union` treats as nothing at all.
    static let null = MercatorRect(x: .infinity, y: .infinity, width: 0, height: 0)

    var isNull: Bool { origin.x.isInfinite || origin.y.isInfinite }

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    var midX: Double { origin.x + size.width / 2 }
    var midY: Double { origin.y + size.height / 2 }
    var width: Double { size.width }
    var height: Double { size.height }

    func contains(_ point: MercatorPoint) -> Bool {
        guard !isNull else { return false }
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func intersects(_ other: MercatorRect) -> Bool {
        guard !isNull, !other.isNull else { return false }
        return minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    func intersection(_ other: MercatorRect) -> MercatorRect {
        guard intersects(other) else { return .null }
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        return MercatorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func union(_ other: MercatorRect) -> MercatorRect {
        if isNull { return other }
        if other.isNull { return self }
        let x0 = min(minX, other.minX)
        let y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX)
        let y1 = max(maxY, other.maxY)
        return MercatorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func insetBy(dx: Double, dy: Double) -> MercatorRect {
        guard !isNull else { return self }
        return MercatorRect(x: minX + dx, y: minY + dy, width: width - dx * 2, height: height - dy * 2)
    }
}

// MARK: - A region on the map

/// How much of the world is on screen, in degrees.
struct GeoSpan: Equatable {
    var latitudeDelta: CLLocationDegrees
    var longitudeDelta: CLLocationDegrees
}

/// A centre and a span — what MapKit called a coordinate region, and what the
/// layers that work in degrees (the wind lattice, the culling, the fields)
/// still ask about the camera.
struct GeoRegion: Equatable {
    var center: CLLocationCoordinate2D
    var span: GeoSpan

    init(center: CLLocationCoordinate2D, span: GeoSpan) {
        self.center = center
        self.span = span
    }

    static func == (lhs: GeoRegion, rhs: GeoRegion) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.span == rhs.span
    }

    var isUsable: Bool {
        span.latitudeDelta.isFinite && span.longitudeDelta.isFinite && span.latitudeDelta > 0
    }
}

// MARK: - Great-circle lines

extension GreatCircle {

    /// The great circle between two points as a run of coordinates, close
    /// enough together that a renderer joining them with straight segments
    /// draws the curve.
    ///
    /// What `MKGeodesicPolyline` used to do for the routes, the ruler and the
    /// organised tracks. The longitudes are left *continuous* rather than
    /// wrapped — a leg from 170°E to 170°W comes out ending at 190° — because
    /// that is how a line is told to cross the antimeridian the short way
    /// round instead of being drawn back across the whole planet.
    static func arc(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        stepMetres: CLLocationDistance = 60_000
    ) -> [CLLocationCoordinate2D] {
        guard CLLocationCoordinate2DIsValid(start), CLLocationCoordinate2DIsValid(end) else {
            return [start, end]
        }

        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let lon2 = end.longitude * .pi / 180

        let h = sin((lat2 - lat1) / 2) * sin((lat2 - lat1) / 2)
            + cos(lat1) * cos(lat2) * sin((lon2 - lon1) / 2) * sin((lon2 - lon1) / 2)
        let angular = 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
        let metres = angular * earthRadius

        guard angular > 1e-9, metres > stepMetres else {
            return [start, Self.unwrapped(end, after: start)]
        }

        let steps = min(Int((metres / stepMetres).rounded(.up)), 512)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(steps + 1)

        let sinAngular = sin(angular)
        var previous = start
        for index in 0...steps {
            let fraction = Double(index) / Double(steps)
            let a = sin((1 - fraction) * angular) / sinAngular
            let b = sin(fraction * angular) / sinAngular
            let x = a * cos(lat1) * cos(lon1) + b * cos(lat2) * cos(lon2)
            let y = a * cos(lat1) * sin(lon1) + b * cos(lat2) * sin(lon2)
            let z = a * sin(lat1) + b * sin(lat2)
            let point = CLLocationCoordinate2D(
                latitude: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
                longitude: atan2(y, x) * 180 / .pi
            )
            let continuous = index == 0 ? start : Self.unwrapped(point, after: previous)
            out.append(continuous)
            previous = continuous
        }
        return out
    }

    /// A run of points joined by great circles, with longitudes kept
    /// continuous along the whole of it.
    static func path(through points: [CLLocationCoordinate2D], stepMetres: CLLocationDistance = 60_000) -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }
        var out: [CLLocationCoordinate2D] = [points[0]]
        for index in 1..<points.count {
            let from = out[out.count - 1]
            // The next fix, brought onto the same continuous line as the one
            // before it, so the arc starts where the last one finished.
            let to = unwrapped(points[index], after: from)
            let leg = arc(from: from, to: to, stepMetres: stepMetres)
            out.append(contentsOf: leg.dropFirst())
        }
        return out
    }

    /// `coordinate`, with its longitude moved by whole turns to sit within
    /// half a turn of `previous`.
    static func unwrapped(
        _ coordinate: CLLocationCoordinate2D,
        after previous: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        var longitude = coordinate.longitude
        while longitude - previous.longitude > 180 { longitude -= 360 }
        while longitude - previous.longitude < -180 { longitude += 360 }
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: longitude)
    }
}
