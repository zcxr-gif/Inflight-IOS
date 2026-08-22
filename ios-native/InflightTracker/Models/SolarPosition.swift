import CoreLocation
import Foundation

/// Whether the sun is up at a place and time.
///
/// NOAA's solar position approximation, which is a few lines of arithmetic and
/// accurate to well within a minute — far more than enough to decide between a
/// sun and a moon on a weather chip, and it works offline anywhere on earth.
enum SolarPosition {

    static func isDaylight(at coordinate: CLLocationCoordinate2D, date: Date = Date()) -> Bool {
        elevationDegrees(at: coordinate, date: date) > -0.833
    }

    /// Where the sun is, as the only two numbers anything here needs.
    ///
    /// Everything about daylight follows from these: the elevation at a place
    /// is one line of spherical trigonometry given them, and so is the ring of
    /// places where the sun sits at any chosen height — which is what draws a
    /// terminator.
    struct Sun {

        /// How far north or south the sun is standing overhead, in radians.
        /// Swings between about ±23.44° over a year.
        let declination: Double

        /// The longitude the sun is overhead, in degrees. Sweeps west at
        /// fifteen degrees an hour.
        let subsolarLongitude: Double
    }

    /// The sun's position at a moment. NOAA's approximation throughout.
    static func sun(at date: Date = Date()) -> Sun {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        // `Calendar.Component.dayOfYear` is iOS 18, and this ships to 16, so
        // the day of the year comes from `ordinality` instead.
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1

        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        // Fractional year, in radians.
        let gamma = 2 * .pi / 365 * (Double(dayOfYear) - 1 + (hour - 12) / 24)

        let equationOfTime = 229.18 * (0.000075
            + 0.001868 * cos(gamma)
            - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma)
            - 0.040849 * sin(2 * gamma))

        let declination = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma)
            + 0.001480 * sin(3 * gamma)

        // Minutes past midnight UTC. Solar noon at a longitude is where the
        // hour angle is zero, and rearranging that for longitude is the
        // subsolar point.
        let minutesUTC = hour * 60 + minute + second / 60

        return Sun(
            declination: declination,
            subsolarLongitude: (720 - minutesUTC - equationOfTime) / 4
        )
    }

    /// Sun elevation in degrees above the horizon. The -0.833 threshold used
    /// above is the standard sunrise/sunset allowance for refraction and the
    /// sun's own radius.
    static func elevationDegrees(at coordinate: CLLocationCoordinate2D, date: Date = Date()) -> Double {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return 0 }
        return elevationDegrees(at: coordinate, sun: sun(at: date))
    }

    /// The same, for a sun already worked out — so drawing a terminator does
    /// not recompute the date arithmetic once per point of it.
    static func elevationDegrees(
        at coordinate: CLLocationCoordinate2D,
        sun: Sun
    ) -> Double {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return 0 }

        let degrees = Double.pi / 180
        let hourAngle = (coordinate.longitude - sun.subsolarLongitude) * degrees
        let latitude = coordinate.latitude * degrees

        let cosZenith = sin(latitude) * sin(sun.declination)
            + cos(latitude) * cos(sun.declination) * cos(hourAngle)

        return 90 - acos(min(max(cosZenith, -1), 1)) / degrees
    }

    /// The latitude, at one longitude, where the sun sits exactly `elevation`
    /// degrees above the horizon.
    ///
    /// Solved rather than searched. The elevation equation is
    ///
    ///     sin(h) = sin(φ)sin(δ) + cos(φ)cos(δ)cos(H)
    ///
    /// which for a fixed longitude — and therefore a fixed hour angle H — is
    /// `A·sin(φ) + B·cos(φ) = sin(h)`, and that collapses to a single sine of
    /// `φ` plus a phase. Bisecting on `elevationDegrees` would have been easier
    /// to write and wrong near the solstices, where elevation stops being
    /// monotonic in latitude and a search can settle on the wrong root.
    ///
    /// Nil where there is no such latitude at all: over the summer pole in
    /// midsummer the sun never gets as low as the terminator, and the honest
    /// answer is that this meridian has no crossing.
    static func terminatorLatitude(
        atLongitude longitude: Double,
        elevationDegrees elevation: Double,
        sun: Sun
    ) -> Double? {
        let degrees = Double.pi / 180
        let hourAngle = (longitude - sun.subsolarLongitude) * degrees

        let a = sin(sun.declination)
        let b = cos(sun.declination) * cos(hourAngle)

        let amplitude = (a * a + b * b).squareRoot()
        guard amplitude > 1e-9 else { return nil }

        let ratio = sin(elevation * degrees) / amplitude
        guard abs(ratio) <= 1 else { return nil }

        let phase = atan2(b, a)
        let latitude = (asin(ratio) - phase) / degrees

        // The other root of the sine is the antipodal crossing, which belongs
        // to a different meridian; anything outside the globe here means this
        // one is the wrong root.
        guard latitude >= -90, latitude <= 90 else { return nil }
        return latitude
    }
}
