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

    /// Sun elevation in degrees above the horizon. The -0.833 threshold used
    /// above is the standard sunrise/sunset allowance for refraction and the
    /// sun's own radius.
    static func elevationDegrees(at coordinate: CLLocationCoordinate2D, date: Date = Date()) -> Double {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return 0 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        // `Calendar.Component.dayOfYear` is iOS 18, and this ships to 16, so
        // the day of the year comes from `ordinality` instead.
        guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) else { return 0 }

        let components = calendar.dateComponents([.hour, .minute, .second], from: date)

        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        let degrees = Double.pi / 180

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

        // Minutes past midnight UTC, corrected to local solar time.
        let minutesUTC = hour * 60 + minute + second / 60
        let trueSolarTime = minutesUTC + equationOfTime + 4 * coordinate.longitude
        let hourAngle = (trueSolarTime / 4) - 180

        let latitude = coordinate.latitude * degrees
        let cosZenith = sin(latitude) * sin(declination)
            + cos(latitude) * cos(declination) * cos(hourAngle * degrees)

        return 90 - acos(min(max(cosZenith, -1), 1)) / degrees
    }
}
