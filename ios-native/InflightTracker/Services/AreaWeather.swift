import CoreLocation
import Foundation

/// The weather where the map is looking, for the pill in the top left while
/// nothing is open.
///
/// Only once the map is zoomed in far enough to be looking at a *place*. Over
/// a continent, "the weather" is a hundred different answers and the pill would
/// be naming one of them at random, so it fades away until the map is close
/// enough for one forecast to mean something — the way Maps does it.
///
/// Fed from the map's settle rather than from the gesture, the same as the real
/// traffic sweep: nothing here is worth a request per frame of a pan.
@MainActor
final class AreaWeather: ObservableObject {

    /// One place's weather: what to call it, and the forecast for it.
    struct Reading {
        let key: String
        let name: String?
        let coordinate: CLLocationCoordinate2D
        let snapshot: ForecastService.Snapshot
    }

    /// Degrees of latitude on screen under which the pill comes up, and over
    /// which it goes again. Two numbers rather than one, so a map resting on
    /// the line does not flicker the pill in and out on every small zoom.
    static let showSpan: Double = 4
    static let hideSpan: Double = 6

    /// The grid the centre is snapped to, in degrees: about eleven kilometres,
    /// which is finer than the forecast model's own cells. A pan across town
    /// does not cost a request; a pan to the next town does.
    private static let grid: Double = 0.1

    /// Waited out after a settle before anything is asked for, so a run of
    /// quick pans costs one request rather than one each.
    private static let debounce: UInt64 = 350_000_000

    @Published private(set) var isZoomedIn = false
    @Published private(set) var reading: Reading?

    private var task: Task<Void, Never>?
    private var pendingKey: String?

    /// Where the map has come to rest: its centre, and how many degrees of
    /// latitude are on screen.
    func report(centre: CLLocationCoordinate2D, spanDegrees span: Double) {
        let zoomed = isZoomedIn ? span < Self.hideSpan : span < Self.showSpan
        if zoomed != isZoomedIn { isZoomedIn = zoomed }

        guard zoomed, CLLocationCoordinate2DIsValid(centre) else {
            task?.cancel()
            pendingKey = nil
            return
        }

        let latitude = (centre.latitude / Self.grid).rounded() * Self.grid
        let longitude = (centre.longitude / Self.grid).rounded() * Self.grid
        let key = String(format: "area:%.1f,%.1f", latitude, longitude)

        // Already showing it, or already on the way — unless what is showing
        // has gone stale, which `snapshot(for:)` stops answering for.
        let isFresh = reading?.key == key && ForecastService.shared.snapshot(for: key) != nil
        guard !isFresh, pendingKey != key else { return }

        task?.cancel()
        pendingKey = key
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled else { return }

            async let name = Self.placeName(for: coordinate)
            let snapshot = await ForecastService.shared.snapshot(loading: key, at: coordinate)
            let resolvedName = await name

            guard !Task.isCancelled, let self else { return }
            if self.pendingKey == key { self.pendingKey = nil }
            guard let snapshot else { return }
            self.reading = Reading(key: key, name: resolvedName, coordinate: coordinate, snapshot: snapshot)
        }
    }

    /// Asks again for the place showing, if its forecast has gone stale — for
    /// a card opened on a map that has not moved in an hour.
    func refreshIfStale() {
        guard let reading, ForecastService.shared.snapshot(for: reading.key) == nil else { return }
        report(centre: reading.coordinate, spanDegrees: 0)
    }

    /// What somebody standing there would call the place: the town, or failing
    /// that the county, the region, or the water.
    private nonisolated static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        return placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.inlandWater
            ?? placemark.ocean
            ?? placemark.name
    }
}
