import CoreLocation
import Foundation

/// The sky's own timetable for a place: the sun, the twilight either side of
/// it, and the moon.
///
/// ## Why this is arithmetic rather than a request
///
/// It used to come down with the forecast, because the forecast happened to be
/// WeatherKit's and WeatherKit puts sun and moon events in its daily records.
/// That is the only reason it was ever a network answer. None of it is weather:
/// where the sun is at a given moment over a given patch of ground is a
/// question about orbits, and the orbits are known.
///
/// So it is worked out here. It costs a few hundred trigonometric evaluations
/// per field, it is the same answer every provider would have given, and —
/// which is the point — it works with the aeroplane over the middle of an ocean
/// and the phone on a cellular connection that has stopped answering.
///
/// ## How accurate
///
/// The sun is NOAA's approximation, already in `SolarPosition` and good to well
/// under a minute. The moon is the standard low-precision series — mean
/// longitude, the leading equation of the centre, one latitude term — which
/// puts its position within about a tenth of a degree and its rise and set
/// within a few minutes. A panel that writes "Up 04:12" is not a panel where
/// three minutes matters; an ephemeris that needed a network call would be.
enum SkyAlmanac {

    // MARK: - What a day looks like

    /// The four times the sun makes, for one day at one place.
    ///
    /// Any of them can be missing, and at high latitudes several will be: north
    /// of the Arctic circle in June the sun does not rise because it never set,
    /// and there is no honest time to print. The panel draws an em dash, which
    /// is the truth.
    struct SunDay {
        let sunrise: Date?
        let sunset: Date?
        /// When there is enough light to see the horizon, and when there stops
        /// being — the times a night rating is written around, which is not the
        /// moment the sun crosses the horizon.
        let civilDawn: Date?
        let civilDusk: Date?
    }

    /// The moon's day: what shape it is, and when it is up.
    struct MoonDay {
        let phase: MoonPhase
        let moonrise: Date?
        let moonset: Date?
    }

    /// The eight phases anybody names.
    ///
    /// Its own type rather than a fraction, because the two things drawn from it
    /// — a word and an SF Symbol — are both one of eight. The fraction is right
    /// there in `phaseFraction` for anything that ever wants to draw the shape
    /// properly.
    enum MoonPhase: String {
        case new
        case waxingCrescent
        case firstQuarter
        case waxingGibbous
        case full
        case waningGibbous
        case lastQuarter
        case waningCrescent
    }

    // MARK: - The sun

    /// The sun's four times for the day containing `date` at the field.
    ///
    /// The window is the *field's* own day rather than the reader's, which is
    /// what makes "sunset" mean the one at the end of the day the panel is
    /// showing. The zone comes down with the forecast — Open-Meteo answers with
    /// the field's offset — so this is one parameter rather than a second thing
    /// to fetch.
    static func sun(
        at coordinate: CLLocationCoordinate2D,
        on date: Date = Date(),
        in timeZone: TimeZone = .current
    ) -> SunDay {
        let start = startOfDay(date, in: timeZone)

        func elevation(_ moment: Date) -> Double {
            SolarPosition.elevationDegrees(at: coordinate, date: moment)
        }

        // The standard allowance for refraction and the sun's own disc, and the
        // international definition of civil twilight.
        let horizon = -0.833
        let civil = -6.0

        return SunDay(
            sunrise: crossing(from: start, of: elevation, through: horizon, rising: true),
            sunset: crossing(from: start, of: elevation, through: horizon, rising: false),
            civilDawn: crossing(from: start, of: elevation, through: civil, rising: true),
            civilDusk: crossing(from: start, of: elevation, through: civil, rising: false)
        )
    }

    // MARK: - The moon

    /// The moon's phase and times for the day containing `date` at the field.
    static func moon(
        at coordinate: CLLocationCoordinate2D,
        on date: Date = Date(),
        in timeZone: TimeZone = .current
    ) -> MoonDay {
        let start = startOfDay(date, in: timeZone)

        func altitude(_ moment: Date) -> Double {
            moonAltitudeDegrees(at: coordinate, date: moment)
        }

        // The moon's own allowance: its mean horizontal parallax is a little
        // under a degree and refraction lifts it a little further, which nets
        // out to the centre sitting a touch above the geometric horizon at the
        // moment the limb appears.
        let horizon = 0.125

        return MoonDay(
            phase: phase(at: date),
            moonrise: crossing(from: start, of: altitude, through: horizon, rising: true),
            moonset: crossing(from: start, of: altitude, through: horizon, rising: false)
        )
    }

    /// Where the moon is in its cycle, 0 at new and 0.5 at full.
    ///
    /// The synodic month against a known new moon, which is the cheap answer and
    /// drifts by a few hours over a century — well inside the eighth of a cycle
    /// a phase name covers.
    static func phaseFraction(at date: Date = Date()) -> Double {
        // 2000-01-06 18:14 UTC, the first new moon of the century.
        let newMoon = Date(timeIntervalSince1970: 947_182_440)
        let synodic: Double = 29.530_588_853 * 86_400

        let elapsed = date.timeIntervalSince(newMoon).truncatingRemainder(dividingBy: synodic)
        return (elapsed < 0 ? elapsed + synodic : elapsed) / synodic
    }

    static func phase(at date: Date = Date()) -> MoonPhase {
        // Eighths of the cycle, offset by a sixteenth so that "new" is the
        // eighth *centred* on new rather than the one starting at it. Without
        // the offset the moon is called new for the two days after it is
        // visibly a crescent.
        let eighth = ((phaseFraction(at: date) * 8) + 0.5).truncatingRemainder(dividingBy: 8)

        switch Int(eighth) {
        case 0: return .new
        case 1: return .waxingCrescent
        case 2: return .firstQuarter
        case 3: return .waxingGibbous
        case 4: return .full
        case 5: return .waningGibbous
        case 6: return .lastQuarter
        default: return .waningCrescent
        }
    }

    /// How far above the horizon the moon is, in degrees.
    ///
    /// The low-precision lunar series: mean longitude, the leading term of the
    /// equation of the centre, and one term of latitude. Everything dropped from
    /// the full expansion moves the moon by less than a tenth of a degree, which
    /// is a rise time wrong by under two minutes.
    static func moonAltitudeDegrees(
        at coordinate: CLLocationCoordinate2D,
        date: Date
    ) -> Double {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return 0 }

        let days = julianDays(since: date)
        let radians = Double.pi / 180

        // Mean longitude, mean anomaly, and the argument of latitude.
        let meanLongitude = 218.316 + 13.176396 * days
        let meanAnomaly = (134.963 + 13.064993 * days) * radians
        let argument = (93.272 + 13.229350 * days) * radians

        // Ecliptic coordinates.
        let longitude = (meanLongitude + 6.289 * sin(meanAnomaly)) * radians
        let latitude = 5.128 * sin(argument) * radians

        // Onto the equator. The obliquity's own drift is a ten-thousandth of a
        // degree a year, so the J2000 value stands.
        let obliquity = 23.4397 * radians

        let rightAscension = atan2(
            sin(longitude) * cos(obliquity) - tan(latitude) * sin(obliquity),
            cos(longitude)
        )
        let declination = asin(
            sin(latitude) * cos(obliquity)
                + cos(latitude) * sin(obliquity) * sin(longitude)
        )

        // Greenwich mean sidereal time, and from it the hour angle at this
        // longitude — the one number that turns a position in the sky into a
        // position over a place.
        let sidereal = (280.16 + 360.9856235 * days) * radians
        let hourAngle = sidereal + coordinate.longitude * radians - rightAscension

        let phi = coordinate.latitude * radians
        let sine = sin(phi) * sin(declination)
            + cos(phi) * cos(declination) * cos(hourAngle)

        return asin(max(-1, min(1, sine))) / radians
    }

    // MARK: - Finding the moment something crosses the horizon

    /// The first time in the twenty-four hours after `start` that `height`
    /// crosses `threshold` in the given direction.
    ///
    /// A coarse sweep to find the interval the crossing is in, then bisection
    /// inside it. Ten-minute steps are fine for the sweep because neither body
    /// changes height fast enough to cross and re-cross inside one — the sun
    /// moves a quarter of a degree a minute at its quickest, so a ten-minute
    /// window it enters below the horizon and leaves below the horizon did not
    /// contain a sunrise.
    ///
    /// Nil where there is no crossing at all, which is the honest answer for a
    /// polar summer and for a moon that stays up all day.
    private static func crossing(
        from start: Date,
        of height: (Date) -> Double,
        through threshold: Double,
        rising: Bool
    ) -> Date? {
        let step: TimeInterval = 600
        let steps = Int(86_400 / step)

        var previousTime = start
        var previous = height(start) - threshold

        for index in 1...steps {
            let time = start.addingTimeInterval(Double(index) * step)
            let current = height(time) - threshold

            let crossed = rising ? (previous < 0 && current >= 0) : (previous >= 0 && current < 0)

            if crossed {
                return bisect(
                    from: previousTime,
                    to: time,
                    of: height,
                    through: threshold,
                    rising: rising
                )
            }

            previousTime = time
            previous = current
        }

        return nil
    }

    /// Sixteen halvings of a ten-minute window, which lands inside a hundredth
    /// of a second — far past what is printed, and cheap enough not to think
    /// about.
    private static func bisect(
        from start: Date,
        to end: Date,
        of height: (Date) -> Double,
        through threshold: Double,
        rising: Bool
    ) -> Date {
        var low = start
        var high = end

        for _ in 0..<16 {
            let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            let value = height(middle) - threshold

            if (value >= 0) == rising {
                high = middle
            } else {
                low = middle
            }
        }

        return low.addingTimeInterval(high.timeIntervalSince(low) / 2)
    }

    /// Midnight at the field, for whatever day `date` falls on there.
    private static func startOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    /// Days since J2000.0, which is what every series above is written against.
    private static func julianDays(since date: Date) -> Double {
        // 2000-01-01 12:00 UTC as a Unix time.
        date.timeIntervalSince1970 / 86_400 - 10_957.5
    }
}
