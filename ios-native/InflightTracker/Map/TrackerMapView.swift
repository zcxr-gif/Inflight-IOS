import MapKit
import SwiftUI
import UIKit

/// The live map. A thin SwiftUI wrapper over `MKMapView` — MapKit gives us a
/// fully native map with no API key, tile budget, or web view involved.
struct TrackerMapView: UIViewRepresentable {

    let flights: [Flight]
    @Binding var selection: SelectedFlight?

    /// One-shot camera moves from the buttons beside the info window. Carries a
    /// token so the same request isn't replayed on every feed tick.
    var command: MapCommand?

    /// How much of the bottom of the map the info window is covering, so a
    /// framed route isn't hidden behind it.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll

        // Heading is applied as a plain rotation on each annotation view, which
        // only lines up with the world while the map itself is north-up.
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        // MapKit's controls and callouts default to the system blue; the
        // tracker's chrome is white on carbon and stays that way.
        mapView.tintColor = .white

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.emphasisStyle = .muted
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration

        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.reuseIdentifier
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(flights: flights, on: mapView)
        context.coordinator.syncSelection(selection, on: mapView)
        context.coordinator.syncRoute(on: mapView)
        context.coordinator.handle(command, on: mapView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        static let reuseIdentifier = "flight"

        var parent: TrackerMapView

        private var annotations: [String: FlightAnnotation] = [:]

        /// Set while MapKit's own selection callbacks are being handled, so we
        /// don't bounce the change straight back into the map.
        private var isApplyingSelection = false

        /// Debounced viewport re-cull, cancelled if the map keeps moving.
        private var pendingCull: DispatchWorkItem?

        /// What the drawn route currently represents, so overlays are only
        /// rebuilt when the trail actually grows.
        private var renderedRouteKey: String?
        private var routeOverlays: [MKPolyline] = []

        private var handledCommand: UUID?

        init(_ parent: TrackerMapView) {
            self.parent = parent
        }

        // MARK: Annotation syncing

        func sync(flights: [Flight], on mapView: MKMapView) {
            let visible = Self.cull(flights: flights, to: mapView)
            var seen = Set<String>()
            var additions: [FlightAnnotation] = []

            for flight in visible {
                seen.insert(flight.id)

                if let existing = annotations[flight.id] {
                    if existing.update(with: flight) {
                        refresh(annotation: existing, on: mapView)
                    }
                } else {
                    let annotation = FlightAnnotation(flight: flight)
                    annotations[flight.id] = annotation
                    additions.append(annotation)
                }
            }

            // Anything that left the viewport, went stale, or is the aircraft
            // the user is currently reading about (kept so the sheet's target
            // doesn't vanish underneath them).
            let selectedId = parent.selection?.id
            let removals = annotations.filter { !seen.contains($0.key) && $0.key != selectedId }

            if !removals.isEmpty {
                mapView.removeAnnotations(Array(removals.values))
                for key in removals.keys { annotations.removeValue(forKey: key) }
            }

            if !additions.isEmpty {
                mapView.addAnnotations(additions)
            }
        }

        /// Keeps MapKit's workload bounded: viewport first, then the aircraft
        /// nearest the centre of the map.
        private static func cull(flights: [Flight], to mapView: MKMapView) -> [Flight] {
            let region = mapView.region
            guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else {
                return Array(flights.prefix(AppConfig.maxRenderedFlights))
            }

            // A little margin so aircraft don't pop in at the very edge.
            let latitudeMargin = region.span.latitudeDelta * 0.6
            let longitudeMargin = region.span.longitudeDelta * 0.6
            let center = region.center

            let inView = flights.filter { flight in
                abs(flight.latitude - center.latitude) <= latitudeMargin
                    && longitudeDelta(flight.longitude, center.longitude) <= longitudeMargin
            }

            guard inView.count > AppConfig.maxRenderedFlights else { return inView }

            return inView.sorted { first, second in
                Self.squaredDistance(first, center) < Self.squaredDistance(second, center)
            }
            .prefix(AppConfig.maxRenderedFlights)
            .map { $0 }
        }

        private static func squaredDistance(_ flight: Flight, _ center: CLLocationCoordinate2D) -> Double {
            let deltaLat = flight.latitude - center.latitude
            let deltaLon = longitudeDelta(flight.longitude, center.longitude)
            return deltaLat * deltaLat + deltaLon * deltaLon
        }

        /// Shortest angular distance between two longitudes, so traffic either
        /// side of the antimeridian isn't treated as half a world away.
        private static func longitudeDelta(_ lhs: Double, _ rhs: Double) -> Double {
            let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
            return delta > 180 ? 360 - delta : delta
        }

        private func refresh(annotation: FlightAnnotation, on mapView: MKMapView) {
            guard let view = mapView.view(for: annotation) else { return }
            apply(annotation: annotation, to: view, selected: annotation.flightId == parent.selection?.id)
        }

        private func apply(annotation: FlightAnnotation, to view: MKAnnotationView, selected: Bool) {
            let key = annotation.flight.spriteKey
            view.image = PlaneSprites.shared.icon(forKey: key, selected: selected)
            view.transform = CGAffineTransform(rotationAngle: CGFloat(annotation.flight.heading) * .pi / 180)

            annotation.renderedSpriteKey = key
            annotation.renderedHeading = annotation.flight.heading
        }

        // MARK: Selection

        func syncSelection(_ selection: SelectedFlight?, on mapView: MKMapView) {
            guard !isApplyingSelection else { return }

            // Sheet dismissed — drop MapKit's selection too.
            if selection == nil {
                for annotation in mapView.selectedAnnotations {
                    mapView.deselectAnnotation(annotation, animated: true)
                }
            }
        }

        // MARK: Route overlays

        private func selectedFlight() -> Flight? {
            guard let id = parent.selection?.id else { return nil }
            return parent.flights.first { $0.id == id }
        }

        /// Draws the selected aircraft's path: the track we have actually
        /// watched it fly, plus dashed legs for the parts we can only infer —
        /// what happened before the app first saw it, and what is still ahead.
        func syncRoute(on mapView: MKMapView) {
            guard let flight = selectedFlight() else {
                clearRoute(on: mapView)
                return
            }

            let trail = FlightTrailStore.shared.points(for: flight.id)
            let key = [
                flight.id,
                String(trail.count),
                flight.departureIcao ?? "",
                flight.arrivalIcao ?? ""
            ].joined(separator: "|")

            guard key != renderedRouteKey else { return }
            renderedRouteKey = key

            if !routeOverlays.isEmpty {
                mapView.removeOverlays(routeOverlays)
                routeOverlays.removeAll(keepingCapacity: true)
            }

            var flown = trail
            // The aircraft's live position is the head of its own track.
            let livePoint = TrackPoint(
                coordinate: flight.coordinate,
                altitudeFeet: flight.altitudeFeet,
                groundSpeedKnots: flight.groundSpeedKnots,
                date: Date()
            )
            if flown.last.map({ FlightProgress.distanceNM(from: $0.coordinate, to: flight.coordinate) > 0.1 }) ?? true {
                flown.append(livePoint)
            }

            // Split into runs of constant altitude band so the track is
            // coloured by height the way the web tracker draws it, without one
            // overlay per sample.
            routeOverlays.append(contentsOf: Self.altitudeSegments(of: flown))

            // Before we were watching: departure to the first point we have.
            if let departure = AirportStore.shared.airport(flight.departureIcao),
               let first = flown.first,
               FlightProgress.distanceNM(from: departure.coordinate, to: first.coordinate) > 1 {
                routeOverlays.append(dashed(from: departure.coordinate, to: first.coordinate))
            }

            // Still to come.
            if let arrival = AirportStore.shared.airport(flight.arrivalIcao) {
                routeOverlays.append(dashed(from: flight.coordinate, to: arrival.coordinate))
            }

            if !routeOverlays.isEmpty {
                mapView.addOverlays(routeOverlays, level: .aboveRoads)
            }
        }

        private func dashed(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> MKPolyline {
            let line = MKGeodesicPolyline(coordinates: [from, to], count: 2)
            line.title = Self.plannedTitle
            return line
        }

        /// One polyline per run of samples sharing an altitude band. A real
        /// flight climbs and descends through them once each, so this is a
        /// handful of overlays rather than one per point.
        private static func altitudeSegments(of points: [TrackPoint]) -> [MKPolyline] {
            guard points.count >= 2 else { return [] }

            var lines: [MKPolyline] = []
            var run: [CLLocationCoordinate2D] = [points[0].coordinate]
            var band = AltitudeBand.band(forFeet: points[0].altitudeFeet)

            for point in points.dropFirst() {
                let next = AltitudeBand.band(forFeet: point.altitudeFeet)
                run.append(point.coordinate)

                if next != band {
                    if run.count >= 2 {
                        let line = MKGeodesicPolyline(coordinates: run, count: run.count)
                        line.title = "\(Self.flownTitle):\(band)"
                        lines.append(line)
                    }
                    // The shared point keeps the runs joined.
                    run = [point.coordinate]
                    band = next
                }
            }

            if run.count >= 2 {
                let line = MKGeodesicPolyline(coordinates: run, count: run.count)
                line.title = "\(Self.flownTitle):\(band)"
                lines.append(line)
            }

            return lines
        }

        private func clearRoute(on mapView: MKMapView) {
            guard !routeOverlays.isEmpty else {
                renderedRouteKey = nil
                return
            }
            mapView.removeOverlays(routeOverlays)
            routeOverlays.removeAll(keepingCapacity: true)
            renderedRouteKey = nil
        }

        static let flownTitle = "flown"
        static let plannedTitle = "planned"

        // MARK: Camera

        func handle(_ command: MapCommand?, on mapView: MKMapView) {
            guard let command = command, command.id != handledCommand else { return }
            handledCommand = command.id

            switch command.kind {
            case .centerOnFlight:
                center(on: mapView)
            case .fitRoute:
                fitRoute(on: mapView)
            case .focus(let latitude, let longitude, let spanMeters):
                focus(
                    on: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    spanMeters: spanMeters,
                    on: mapView
                )
            }
        }

        /// Takes the map to somewhere it isn't currently looking — a search
        /// result, a field with a tower open. Unlike `center`, this sets the
        /// zoom as well as the position: the whole point is that whatever was
        /// picked may be nowhere near the current view.
        private func focus(
            on coordinate: CLLocationCoordinate2D,
            spanMeters: Double,
            on mapView: MKMapView
        ) {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }

            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: spanMeters,
                longitudinalMeters: spanMeters
            )

            // Via a map rect rather than `setRegion`, which takes no edge
            // padding — and the chrome over the bottom of the map is exactly
            // what the target must not land behind.
            mapView.setVisibleMapRect(
                Self.mapRect(for: region),
                edgePadding: edgeInsets(),
                animated: true
            )
        }

        private static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
            let north = min(region.center.latitude + region.span.latitudeDelta / 2, 85)
            let south = max(region.center.latitude - region.span.latitudeDelta / 2, -85)
            let west = region.center.longitude - region.span.longitudeDelta / 2
            let east = region.center.longitude + region.span.longitudeDelta / 2

            let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
            let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))

            return MKMapRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
        }

        /// Keeps the current zoom and puts the aircraft in the part of the map
        /// the info window isn't covering.
        private func center(on mapView: MKMapView) {
            guard let flight = selectedFlight() else { return }

            let visible = mapView.visibleMapRect
            let point = MKMapPoint(flight.coordinate)
            let rect = MKMapRect(
                x: point.x - visible.width / 2,
                y: point.y - visible.height / 2,
                width: visible.width,
                height: visible.height
            )

            mapView.setVisibleMapRect(rect, edgePadding: edgeInsets(), animated: true)
        }

        /// Frames everything the route touches: the flown track, both
        /// endpoints, and where the aircraft is now.
        private func fitRoute(on mapView: MKMapView) {
            guard let flight = selectedFlight() else { return }

            var rect = MKMapRect.null

            func include(_ coordinate: CLLocationCoordinate2D) {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0.01, height: 0.01))
            }

            include(flight.coordinate)
            for point in FlightTrailStore.shared.points(for: flight.id) { include(point.coordinate) }
            if let departure = AirportStore.shared.airport(flight.departureIcao) {
                include(departure.coordinate)
            }
            if let arrival = AirportStore.shared.airport(flight.arrivalIcao) {
                include(arrival.coordinate)
            }

            guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return }

            mapView.setVisibleMapRect(rect, edgePadding: edgeInsets(), animated: true)
        }

        private func edgeInsets() -> UIEdgeInsets {
            UIEdgeInsets(top: 96, left: 44, bottom: parent.bottomInset + 28, right: 44)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            if line.title == Self.plannedTitle {
                // Inferred, so it reads as an assumption rather than as track.
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.34)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [2, 7]
            } else {
                let band = line.title.flatMap { title -> Int? in
                    guard let raw = title.split(separator: ":").last else { return nil }
                    return Int(String(raw))
                }
                renderer.strokeColor = AltitudeBand.color(for: band ?? 0)
                renderer.lineWidth = 3.5
            }

            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let flightAnnotation = annotation as? FlightAnnotation else { return nil }

            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Coordinator.reuseIdentifier,
                for: flightAnnotation
            )
            view.canShowCallout = false
            view.displayPriority = .required
            view.collisionMode = .circle

            apply(
                annotation: flightAnnotation,
                to: view,
                selected: flightAnnotation.flightId == parent.selection?.id
            )

            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? FlightAnnotation else { return }

            apply(annotation: annotation, to: view, selected: true)

            isApplyingSelection = true
            parent.selection = SelectedFlight(id: annotation.flightId)
            isApplyingSelection = false
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation as? FlightAnnotation else { return }

            apply(annotation: annotation, to: view, selected: false)

            guard parent.selection?.id == annotation.flightId else { return }

            isApplyingSelection = true
            parent.selection = nil
            isApplyingSelection = false
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Re-cull for the new viewport using the traffic we already have.
            // Coalesced because this fires repeatedly through a pan or a
            // pinch, and each pass walks every aircraft on the server.
            pendingCull?.cancel()

            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self = self, let mapView = mapView else { return }
                self.sync(flights: self.parent.flights, on: mapView)
            }

            pendingCull = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}

/// Identifiable wrapper so a tapped aircraft can drive `.sheet(item:)` while
/// the sheet itself always reads the newest data for that id.
struct SelectedFlight: Identifiable, Equatable {
    let id: String
}

/// A one-shot camera move. The token is what makes it one-shot: SwiftUI hands
/// the same value to `updateUIView` on every feed tick, so the map replays
/// nothing it has already carried out.
struct MapCommand: Equatable {

    enum Kind: Equatable {
        case centerOnFlight
        case fitRoute

        /// Somewhere on the map by position rather than by aircraft — what a
        /// search result or an open tower resolves to. Carried as plain
        /// numbers because `CLLocationCoordinate2D` is not `Equatable`, and
        /// the command has to be comparable to be one-shot.
        case focus(latitude: Double, longitude: Double, spanMeters: Double)
    }

    let kind: Kind
    let id = UUID()
}
