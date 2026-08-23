import Foundation

/// One frame of a weather layer: when it is for, and what identifies it.
///
/// Shared by both sources. RainViewer's frames carry a path the service handed
/// out; the satellite's carry a date. Neither is a URL — building one is the
/// tile overlay's job, and it is the only thing that knows the shape each
/// service wants.
struct WeatherFrame: Equatable, Identifiable {

    let time: Date

    /// Whatever the source needs to name this frame again: RainViewer's own
    /// path, or a day.
    let path: String

    var id: String { path }
}

/// Cloud, from NASA.
///
/// The cloud layer used to be RainViewer's infrared, which their published
/// schedule withdrew from the free tier — leaving a switch that drew nothing.
/// This is the replacement, and it is free in the way that matters: NASA's
/// Global Imagery Browse Services are public, need no key and no account, and
/// have no quota to blow through.
///
/// What it is honestly *not* is a live infrared feed. GIBS serves the polar
/// orbiters' daily global composite — true colour, built up swath by swath as
/// the satellite crosses, complete for a given day within hours of the last
/// pass. So this is "where the weather systems are today" rather than "where
/// that squall line is this minute", and the layer says so. The radar is the
/// one that answers the second question.
enum SatelliteImagery {

    static let host = "https://gibs.earthdata.nasa.gov"

    /// The imagery product.
    ///
    /// VIIRS on NOAA-20 rather than MODIS on Terra: the same picture, from an
    /// instrument that is not two decades past its design life. Swapping
    /// products is this one line — the rest of the URL is the same for every
    /// corrected-reflectance layer GIBS serves.
    static let product = "VIIRS_NOAA20_CorrectedReflectance_TrueColor"

    /// GIBS names a matrix set for how many zoom levels it holds, so `Level9`
    /// is zooms 0 through 8. Asking past the top gets a 404 and draws nothing;
    /// stopping short of it lets `MKTileOverlay` scale the last one up, which
    /// costs sharpness and nothing else.
    static let tileMatrixSet = "GoogleMapsCompatible_Level9"
    static let maximumZoom = 8

    /// How many days of imagery the scrubber can reach back through.
    ///
    /// Today's is still being assembled while the satellite is still flying it,
    /// so the day before is the one that is certainly whole — which is exactly
    /// what having more than one frame is for.
    private static let dayCount = 3

    /// The days available, oldest first, so the strip runs forwards through
    /// time the way the radar's frames do.
    static func frames(now: Date = Date()) -> [WeatherFrame] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        let today = calendar.startOfDay(for: now)

        return (0..<dayCount).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return WeatherFrame(time: day, path: Self.date(day, in: calendar))
        }
    }

    /// The `YYYY-MM-DD` GIBS wants in the path.
    private static func date(_ day: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 1970,
            parts.month ?? 1,
            parts.day ?? 1
        )
    }

    /// `{host}/wmts/epsg3857/best/{product}/default/{time}/{set}/{z}/{y}/{x}.jpg`
    ///
    /// The row before the column, which is GIBS's order and the opposite of
    /// every other tile service in this app.
    static func url(frame: WeatherFrame, z: Int, x: Int, y: Int) -> URL? {
        URL(string: """
        \(host)/wmts/epsg3857/best/\(product)/default/\(frame.path)\
        /\(tileMatrixSet)/\(z)/\(y)/\(x).jpg
        """)
    }
}

/// Where each weather layer comes from.
///
/// The two are nothing alike — one is a commercial radar mosaic with an index
/// of ten-minute frames, the other is a public archive of daily satellite
/// composites — and this is the one place that knows which is which, so
/// everything downstream can ask the same four questions of either.
enum MapWeatherSource {

    static func host(for layer: MapWeatherLayer) -> String? {
        switch layer {
        case .off: return nil
        case .radar: return RainViewerService.shared.host
        case .satellite: return SatelliteImagery.host
        }
    }

    static func frames(for layer: MapWeatherLayer) -> [WeatherFrame] {
        switch layer {
        case .off: return []
        case .radar: return RainViewerService.shared.radarFrames
        case .satellite: return SatelliteImagery.frames()
        }
    }

    /// Whether a layer has anything to draw at all.
    ///
    /// "Not known to be withdrawn" rather than "known to be there": until the
    /// radar index has been read, radar is offered. The satellite archive needs
    /// no index — the days exist because the calendar says so — so it is always
    /// on offer.
    static func isAvailable(_ layer: MapWeatherLayer) -> Bool {
        switch layer {
        case .off, .satellite: return true
        case .radar: return RainViewerService.shared.isAvailable(.radar)
        }
    }

    /// How deep the radar's free tier serves.
    ///
    /// RainViewer's published schedule takes free users to zoom 7 from January
    /// 2026, having been 10 since September 2025. Set to the lower of the two
    /// deliberately: `MKTileOverlay` scales a coarse tile up to fill a closer
    /// zoom, so asking too shallow costs sharpness, while asking too deep gets
    /// a 404 and draws *nothing* — and a weather layer that vanishes when you
    /// zoom in is a bug report, where a soft one is a known limit.
    static let radarMaximumZoom = 7

    /// How deep each service serves.
    static func maximumZoom(for layer: MapWeatherLayer) -> Int {
        switch layer {
        case .off, .radar: return radarMaximumZoom
        case .satellite: return SatelliteImagery.maximumZoom
        }
    }
}
