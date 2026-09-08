import CoreLocation
import MapKit
import UIKit

/// The colour a scalar field is drawn in.
///
/// ## Why the ramps carry their own alpha
///
/// This is a wash over cartography that people are also using as a map. A ramp
/// that is opaque at both ends hides the coastline under the half of the field
/// where nothing is happening — and the half where nothing is happening is most
/// of it. So the alpha climbs with the value: calm air is invisible, and the
/// only places that take ink are the places worth looking at.
///
/// Temperature is the one that diverges rather than climbs, because it is drawn
/// as a departure from the standard atmosphere and the interesting thing about
/// zero is that it is *ordinary*. Blue below, red above, nothing at all in the
/// middle.
enum WeatherRamp {

    struct Stop {
        let value: Double
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    static func stops(for product: WeatherHeat) -> [Stop] {
        switch product {
        case .off:
            return []

        // Knots. The top of it is a strong winter jet — 200 kt is a good day
        // over the Atlantic and 250 happens, so the scale does not saturate at
        // exactly the moment it becomes interesting.
        case .wind:
            return [
                Stop(value: 0, red: 0.20, green: 0.55, blue: 0.75, alpha: 0.00),
                Stop(value: 25, red: 0.18, green: 0.58, blue: 0.78, alpha: 0.12),
                Stop(value: 55, red: 0.16, green: 0.72, blue: 0.56, alpha: 0.30),
                Stop(value: 85, red: 0.58, green: 0.78, blue: 0.24, alpha: 0.42),
                Stop(value: 115, red: 0.95, green: 0.76, blue: 0.16, alpha: 0.50),
                Stop(value: 145, red: 0.96, green: 0.46, blue: 0.13, alpha: 0.56),
                Stop(value: 185, red: 0.88, green: 0.20, blue: 0.34, alpha: 0.62),
                Stop(value: 230, red: 0.70, green: 0.25, blue: 0.85, alpha: 0.66)
            ]

        // Degrees from standard, either way.
        case .temperature:
            return [
                Stop(value: -26, red: 0.36, green: 0.30, blue: 0.86, alpha: 0.52),
                Stop(value: -13, red: 0.20, green: 0.55, blue: 0.90, alpha: 0.34),
                Stop(value: -5, red: 0.32, green: 0.74, blue: 0.86, alpha: 0.15),
                Stop(value: 0, red: 0.60, green: 0.60, blue: 0.60, alpha: 0.00),
                Stop(value: 5, red: 0.96, green: 0.80, blue: 0.36, alpha: 0.15),
                Stop(value: 13, red: 0.96, green: 0.52, blue: 0.18, alpha: 0.34),
                Stop(value: 26, red: 0.86, green: 0.20, blue: 0.26, alpha: 0.52)
            ]

        // Knots per thousand feet. Six is worth knowing about, ten is where
        // reports start, and past fifteen is where the seatbelt sign goes on.
        case .shear:
            return [
                Stop(value: 0, red: 0.30, green: 0.70, blue: 0.62, alpha: 0.00),
                Stop(value: 3, red: 0.32, green: 0.72, blue: 0.60, alpha: 0.10),
                Stop(value: 6, red: 0.95, green: 0.80, blue: 0.26, alpha: 0.32),
                Stop(value: 10, red: 0.96, green: 0.50, blue: 0.15, alpha: 0.48),
                Stop(value: 15, red: 0.88, green: 0.20, blue: 0.28, alpha: 0.60),
                Stop(value: 22, red: 0.72, green: 0.15, blue: 0.55, alpha: 0.66)
            ]
        }
    }

    /// Straight linear interpolation between the stops either side, clamped at
    /// both ends.
    ///
    /// In premultiplied form, because that is what the bitmap wants and because
    /// interpolating an unpremultiplied colour towards a transparent stop
    /// drags its *hue* towards whatever that stop happens to name — which is
    /// how a ramp that fades out at zero ends up with a grey fringe along
    /// every contour.
    static func colour(_ value: Double, in stops: [Stop]) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        if value <= first.value { return premultiplied(first) }
        if value >= last.value { return premultiplied(last) }

        for index in 1..<stops.count where value <= stops[index].value {
            let low = stops[index - 1], high = stops[index]
            let span = high.value - low.value
            let t = CGFloat(span > 0 ? (value - low.value) / span : 0)
            let a = premultiplied(low), b = premultiplied(high)
            return (
                a.r + (b.r - a.r) * t,
                a.g + (b.g - a.g) * t,
                a.b + (b.b - a.b) * t,
                a.a + (b.a - a.a) * t
            )
        }
        return premultiplied(last)
    }

    private static func premultiplied(_ stop: Stop) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        (stop.red * stop.alpha, stop.green * stop.alpha, stop.blue * stop.alpha, stop.alpha)
    }

    /// The same ramp as a run of UIColors, for a legend to draw.
    ///
    /// At full strength, which is deliberately not how the map draws it: on the
    /// map the low end of every ramp is nearly transparent, and a key rendered
    /// that way would be a bar that fades into the panel it is printed on.
    /// What a legend has to show is which hue means which number.
    ///
    /// Interpolated on the *unpremultiplied* stops for the same reason. The
    /// drawing path premultiplies because that is what a bitmap wants and
    /// because it keeps a hue from drifting as it fades; run the same maths for
    /// a swatch and a stop at zero alpha comes back as black, which is how a
    /// temperature key ends up with a bar of soot through the middle of it
    /// where the air is perfectly ordinary.
    static func legend(for product: WeatherHeat, steps: Int = 24) -> [UIColor] {
        let stops = stops(for: product)
        guard let first = stops.first, let last = stops.last, steps > 1 else { return [] }

        return (0..<steps).map { index in
            let value = first.value + (last.value - first.value) * Double(index) / Double(steps - 1)
            let hue = plain(value, in: stops)
            return UIColor(red: hue.r, green: hue.g, blue: hue.b, alpha: 1)
        }
    }

    /// The ramp's hue at a value, with the alpha left out of it.
    private static func plain(_ value: Double, in stops: [Stop]) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0) }
        if value <= first.value { return (first.red, first.green, first.blue) }
        if value >= last.value { return (last.red, last.green, last.blue) }

        for index in 1..<stops.count where value <= stops[index].value {
            let low = stops[index - 1], high = stops[index]
            let span = high.value - low.value
            let t = CGFloat(span > 0 ? (value - low.value) / span : 0)
            return (
                low.red + (high.red - low.red) * t,
                low.green + (high.green - low.green) * t,
                low.blue + (high.blue - low.blue) * t
            )
        }
        return (last.red, last.green, last.blue)
    }
}

// ---------------------------------------------------------------------------

/// A scalar field, rasterised once and drawn as a picture.
///
/// ## Why a bitmap rather than contours or a mesh
///
/// The source is a lattice of a few dozen model points. Contouring it would
/// draw hard lines through a field whose own resolution is a hundred miles —
/// lines that look like fronts and are not — and a coloured mesh would show
/// its own triangles. A small image stretched under `interpolationQuality =
/// .high` is honest about what it is: a smooth thing, smoothly drawn, with no
/// edge in it that the model did not put there.
///
/// It is also the cheap answer. The image is built once when the grid lands and
/// then costs one blit per frame, where sampling the field per pixel per draw
/// would be a hundred thousand interpolations every time the map moved.
final class WeatherHeatOverlay: NSObject, MKOverlay {

    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    let product: WeatherHeat
    let image: CGImage

    /// The longest side of the raster.
    ///
    /// Deliberately small. The field underneath is a dozen samples across, so
    /// anything past a few hundred pixels is interpolation stored at
    /// resolution rather than detail — and the renderer's own smoothing does a
    /// better job of it than more pixels would, for none of the memory.
    private static let maximumSide = 384

    init?(field: WeatherField, product: WeatherHeat, level: WindLevel) {
        guard product != .off, !field.isEmpty else { return nil }

        let rect = field.mapRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }

        let stops = WeatherRamp.stops(for: product)
        guard !stops.isEmpty else { return nil }

        let aspect = rect.size.height / rect.size.width
        let width = aspect > 1
            ? max(24, Int((Double(Self.maximumSide) / aspect).rounded()))
            : Self.maximumSide
        let height = max(24, Int((Double(width) * aspect).rounded()))

        // Mercator separates: every pixel in a row is at the same latitude and
        // every pixel in a column at the same longitude. So the projection is
        // inverted once per row and once per column rather than once per pixel,
        // which takes the logarithms and arctangents out of the inner loop
        // entirely — about a hundred thousand of them on a full-size raster.
        var latitudes = [CLLocationDegrees](repeating: 0, count: height)
        for row in 0..<height {
            let y = rect.minY + (Double(row) + 0.5) / Double(height) * rect.size.height
            latitudes[row] = MKMapPoint(x: rect.minX, y: y).coordinate.latitude
        }
        var longitudes = [CLLocationDegrees](repeating: 0, count: width)
        for column in 0..<width {
            let x = rect.minX + (Double(column) + 0.5) / Double(width) * rect.size.width
            longitudes[column] = MKMapPoint(x: x, y: rect.minY).coordinate.longitude
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var drew = false

        for row in 0..<height {
            let latitude = latitudes[row]
            for column in 0..<width {
                let coordinate = CLLocationCoordinate2D(
                    latitude: latitude,
                    longitude: longitudes[column]
                )
                guard let value = Self.value(of: product, at: coordinate, in: field, level: level)
                else { continue }

                let c = WeatherRamp.colour(value, in: stops)
                let at = (row * width + column) * 4
                pixels[at] = UInt8(min(max(c.r, 0), 1) * 255)
                pixels[at + 1] = UInt8(min(max(c.g, 0), 1) * 255)
                pixels[at + 2] = UInt8(min(max(c.b, 0), 1) * 255)
                pixels[at + 3] = UInt8(min(max(c.a, 0), 1) * 255)
                drew = true
            }
        }

        guard drew else { return nil }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }

        self.boundingMapRect = rect
        self.coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        self.product = product
        self.image = image
        super.init()
    }

    /// What the field says, in the units the ramp is calibrated in.
    private static func value(
        of product: WeatherHeat,
        at coordinate: CLLocationCoordinate2D,
        in field: WeatherField,
        level: WindLevel
    ) -> Double? {
        switch product {
        case .off:
            return nil

        case .wind:
            guard let wind = field.wind(at: coordinate) else { return nil }
            return (wind.u * wind.u + wind.v * wind.v).squareRoot()
                * WeatherField.knotsPerMetrePerSecond

        case .temperature:
            guard let celsius = field.scalar(.temperature, at: coordinate) else { return nil }
            return celsius - level.standardTemperature

        case .shear:
            return field.scalar(.shear, at: coordinate)
        }
    }
}

/// Draws the raster over the piece of world it belongs to.
final class WeatherHeatRenderer: MKOverlayRenderer {

    private var field: WeatherHeatOverlay { overlay as! WeatherHeatOverlay }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let target = rect(for: field.boundingMapRect)
        guard target.width > 0, target.height > 0 else { return }

        // Smoothed hard, and that is the whole visual argument for this layer:
        // the source lattice is coarse enough that nearest-neighbour would draw
        // it as a chessboard, and bilinear blowup of a coarse smooth field is
        // exactly the picture the field is.
        context.interpolationQuality = .high

        // A bitmap's rows run down from its top and this context's y runs down
        // the map, but `CGContext.draw` puts the image the other way up. One
        // flip about the target's own middle puts it back, and is scoped so
        // nothing else in the pass inherits it.
        context.saveGState()
        context.translateBy(x: 0, y: target.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -target.midY)
        context.draw(field.image, in: target)
        context.restoreGState()
    }
}
