import CoreLocation
import MapKit

/// A rectangle of model weather, on a regular grid.
///
/// ## Why the barbs grew a field underneath them
///
/// The winds layer used to be a list of twenty arrows and nothing else — twenty
/// points fetched, twenty annotations drawn, and no notion anywhere of "the
/// wind at a place the model was not asked about". That is all a chart of barbs
/// needs, and it is not enough for anything that moves: a particle drifting
/// between two arrows has to be told what the air is doing where it actually
/// is, and a coloured field has to answer for every pixel.
///
/// So the fetch produces this instead, and the barbs are drawn *from* it by
/// taking every second point. That ordering matters more than it looks: an
/// arrow pointing one way while a particle beside it drifts another is the
/// layer arguing with itself, and the only way to guarantee it cannot happen is
/// for both to be reading the same numbers.
///
/// ## The grid is in degrees, not in map points
///
/// This is what the model published, held as the model published it. Everything
/// that draws wants it in some other frame — the particles want map points per
/// second, the heat map wants a bitmap — and each of those is a conversion done
/// once, on arrival, by the thing that needs it. See `WindVelocityGrid` and
/// `WeatherHeatOverlay`.
struct WeatherField {

    /// The south-west sample. Not the corner of a cell — the grid is a lattice
    /// of *points*, and this is one of them.
    let south: CLLocationDegrees
    let west: CLLocationDegrees

    /// The spacing between samples. Longitude step is the one on the ground at
    /// the grid's own latitude, so the lattice is roughly square on screen
    /// rather than square in degrees.
    let latitudeStep: CLLocationDegrees
    let longitudeStep: CLLocationDegrees

    let columns: Int
    let rows: Int

    /// Wind as components rather than as a bearing and a speed.
    ///
    /// Bearings do not interpolate. Halfway between 350° and 010° is 000° going
    /// one way round and 180° going the other, and a bilinear filter has no
    /// idea which was meant — so a field held as degrees develops a seam of
    /// wind blowing backwards wherever it crosses north. Components have no
    /// such problem and are what the particles want anyway.
    ///
    /// Metres per second, eastward and northward, row-major from the south-west.
    let u: [Double]
    let v: [Double]

    /// Whatever else was asked for on the same request, by the layer that wants
    /// it. Same layout as `u` and `v`.
    let scalars: [WeatherHeat: [Double]]

    var isEmpty: Bool { columns < 2 || rows < 2 || u.count != columns * rows }

    var north: CLLocationDegrees { south + latitudeStep * Double(rows - 1) }
    var east: CLLocationDegrees { west + longitudeStep * Double(columns - 1) }

    // MARK: - Reading it

    /// Where a coordinate falls on the lattice, in fractional cells, or nil if
    /// it is outside.
    ///
    /// The longitude is brought into the grid's own frame first. A field
    /// fetched across the antimeridian has a west edge of, say, 176° and an
    /// east edge of 190°, because a lattice that wrapped at the seam would not
    /// be a lattice — and a query at −178° is inside it, once you have added
    /// the turn back on.
    private func cell(at coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double)? {
        guard !isEmpty, latitudeStep > 0, longitudeStep > 0 else { return nil }

        var longitude = coordinate.longitude
        while longitude < west - 180 { longitude += 360 }
        while longitude > west + 180 { longitude -= 360 }

        let x = (longitude - west) / longitudeStep
        let y = (coordinate.latitude - south) / latitudeStep
        guard x >= 0, y >= 0, x <= Double(columns - 1), y <= Double(rows - 1) else { return nil }
        return (x, y)
    }

    /// Bilinear, which is the right amount of cleverness for this.
    ///
    /// The samples are tens of kilometres apart and the thing between them is a
    /// smooth field, so anything higher order would be inventing structure the
    /// model never resolved — and anything lower would put a visible cell edge
    /// through the middle of a jet stream.
    private func interpolate(_ values: [Double], at cell: (x: Double, y: Double)) -> Double? {
        guard values.count == columns * rows else { return nil }

        let x0 = min(Int(cell.x), columns - 2)
        let y0 = min(Int(cell.y), rows - 2)
        let fx = cell.x - Double(x0)
        let fy = cell.y - Double(y0)

        let a = values[y0 * columns + x0]
        let b = values[y0 * columns + x0 + 1]
        let c = values[(y0 + 1) * columns + x0]
        let d = values[(y0 + 1) * columns + x0 + 1]

        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Eastward and northward wind at a coordinate, in metres per second.
    func wind(at coordinate: CLLocationCoordinate2D) -> (u: Double, v: Double)? {
        guard let cell = cell(at: coordinate),
              let eastward = interpolate(u, at: cell),
              let northward = interpolate(v, at: cell) else { return nil }
        return (eastward, northward)
    }

    func scalar(_ product: WeatherHeat, at coordinate: CLLocationCoordinate2D) -> Double? {
        guard let values = scalars[product], let cell = cell(at: coordinate) else { return nil }
        return interpolate(values, at: cell)
    }

    // MARK: - The barbs

    /// Every `stride`th sample as a barb, for the arrows drawn over the field.
    ///
    /// Derived rather than fetched. The arrows and everything else on this
    /// layer are then the same numbers by construction, and the sparse grid the
    /// barbs used to ask for separately is one request that no longer happens.
    func barbs(stride: Int) -> [WindsAloftStore.Barb] {
        guard !isEmpty, stride >= 1 else { return [] }

        var out: [WindsAloftStore.Barb] = []
        var row = 0
        while row < rows {
            var column = 0
            while column < columns {
                let index = row * columns + column
                let eastward = u[index]
                let northward = v[index]
                let speed = (eastward * eastward + northward * northward).squareRoot()

                // Back to a bearing, and back to the direction the wind is
                // coming *from*, which is the only direction anybody in
                // aviation means by "the wind".
                var from = atan2(-eastward, -northward) * 180 / .pi
                if from < 0 { from += 360 }

                out.append(
                    WindsAloftStore.Barb(
                        coordinate: CLLocationCoordinate2D(
                            latitude: south + Double(row) * latitudeStep,
                            longitude: Self.wrapped(west + Double(column) * longitudeStep)
                        ),
                        directionDegrees: from,
                        speedKnots: speed * Self.knotsPerMetrePerSecond
                    )
                )
                column += stride
            }
            row += stride
        }
        return out
    }

    static let knotsPerMetrePerSecond = 1.943_844

    static func wrapped(_ degrees: CLLocationDegrees) -> CLLocationDegrees {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    // MARK: - Where it is

    /// The field's extent in the map's own projection.
    ///
    /// Built from two opposite corners rather than by projecting every sample:
    /// Mercator is monotonic in both axes, so the north-west sample is the
    /// minimum of both and the south-east sample is the maximum, and there is
    /// nothing in between that can be outside them.
    var mapRect: MKMapRect {
        let topLeft = MKMapPoint(
            CLLocationCoordinate2D(latitude: north, longitude: Self.wrapped(west))
        )
        var bottomRight = MKMapPoint(
            CLLocationCoordinate2D(latitude: south, longitude: Self.wrapped(east))
        )

        // A field that crosses the antimeridian comes back with its east edge
        // projected to the far side of the map. One world width puts it back
        // where the geometry says it is — off the edge, which is exactly where
        // MapKit expects an overlay that spans the seam to be.
        if bottomRight.x < topLeft.x {
            bottomRight = MKMapPoint(x: bottomRight.x + MKMapRect.world.size.width, y: bottomRight.y)
        }

        return MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
}

// ---------------------------------------------------------------------------

/// The wind field resampled into the map's own frame, as velocities.
///
/// ## Why this exists rather than sampling the field directly
///
/// The particles live in `MKMapPoint`s — that is the only space in which the
/// map's transform is a scale and a translate, and the whole reason a thousand
/// of them can be drawn on a frame clock. Advecting them from a lat/lon field
/// would mean inverting Mercator once per particle per frame, which is a
/// logarithm and an arctangent apiece, sixty times a second.
///
/// So the conversion is done once, here, onto a regular lattice in map points.
/// Sampling is then a bilinear read with no trigonometry in it at all.
///
/// ## Metres per second becomes map points per second
///
/// Mercator is conformal: at any one place it scales east and north by the same
/// factor, which is exactly what `MKMapPointsPerMeterAtLatitude` returns. So a
/// wind vector converts by one multiply — and the factor is baked in per cell,
/// which is also what makes the field correct at both ends of a grid spanning
/// thirty degrees of latitude.
///
/// The sign of the northward component flips, because map points count
/// downwards from the north pole and the wind does not.
struct WindVelocityGrid {

    let rect: MKMapRect
    let columns: Int
    let rows: Int

    /// Map points per second, row-major from the rect's north-west corner.
    private let dx: [Double]
    private let dy: [Double]

    /// How fine the resampled lattice is.
    ///
    /// Finer than the model grid on purpose, and not by much. The source is a
    /// handful of samples across a continent; this is smooth interpolation of
    /// it, not detail it never had. Sixty-four across is enough that no cell
    /// edge is ever visible in a streamline and small enough to build in a
    /// millisecond.
    private static let side = 64

    init?(field: WeatherField) {
        guard !field.isEmpty else { return nil }

        let rect = field.mapRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }

        // Kept roughly square in map points, so the lattice is as fine along
        // the short axis as it is along the long one.
        let aspect = rect.size.height / rect.size.width
        let columns = Self.side
        let rows = max(2, min(Self.side * 2, Int((Double(Self.side) * aspect).rounded())))

        var dx = [Double](repeating: 0, count: columns * rows)
        var dy = [Double](repeating: 0, count: columns * rows)
        var any = false

        for row in 0..<rows {
            let y = rect.minY + (Double(row) + 0.5) / Double(rows) * rect.size.height
            for column in 0..<columns {
                let x = rect.minX + (Double(column) + 0.5) / Double(columns) * rect.size.width
                let coordinate = MKMapPoint(x: x, y: y).coordinate
                guard let wind = field.wind(at: coordinate) else { continue }

                let scale = MKMapPointsPerMeterAtLatitude(coordinate.latitude)
                dx[row * columns + column] = wind.u * scale
                dy[row * columns + column] = -wind.v * scale
                any = true
            }
        }

        guard any else { return nil }

        self.rect = rect
        self.columns = columns
        self.rows = rows
        self.dx = dx
        self.dy = dy
    }

    func contains(_ point: MKMapPoint) -> Bool { rect.contains(point) }

    /// Map points per second at a position, or nil outside the field.
    func velocity(at point: MKMapPoint) -> (dx: Double, dy: Double)? {
        let fx = (point.x - rect.minX) / rect.size.width * Double(columns) - 0.5
        let fy = (point.y - rect.minY) / rect.size.height * Double(rows) - 0.5
        guard fx.isFinite, fy.isFinite else { return nil }
        guard fx >= -0.5, fy >= -0.5,
              fx <= Double(columns) - 0.5, fy <= Double(rows) - 0.5 else { return nil }

        // Clamped rather than wrapped at the edges: half a cell of the field's
        // own border is held constant, which is a truer statement about a
        // model boundary than folding it round to the other side.
        let x0 = min(max(Int(fx.rounded(.down)), 0), columns - 1)
        let y0 = min(max(Int(fy.rounded(.down)), 0), rows - 1)
        let x1 = min(x0 + 1, columns - 1)
        let y1 = min(y0 + 1, rows - 1)
        let tx = min(max(fx - Double(x0), 0), 1)
        let ty = min(max(fy - Double(y0), 0), 1)

        func read(_ values: [Double]) -> Double {
            let a = values[y0 * columns + x0]
            let b = values[y0 * columns + x1]
            let c = values[y1 * columns + x0]
            let d = values[y1 * columns + x1]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        return (read(dx), read(dy))
    }
}
