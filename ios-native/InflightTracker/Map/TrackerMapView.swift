import MapKit
import SwiftUI

/// The live map. A thin SwiftUI wrapper over `MKMapView` — MapKit gives us a
/// fully native map with no API key, tile budget, or web view involved.
struct TrackerMapView: UIViewRepresentable {

    let flights: [Flight]
    @Binding var selection: SelectedFlight?

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

        if #available(iOS 16.0, *) {
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.emphasisStyle = .muted
            configuration.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = configuration
        }

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
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        static let reuseIdentifier = "flight"

        var parent: TrackerMapView

        private var annotations: [String: FlightAnnotation] = [:]

        /// Set while MapKit's own selection callbacks are being handled, so we
        /// don't bounce the change straight back into the map.
        private var isApplyingSelection = false

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
                abs(flight.position.lat - center.latitude) <= latitudeMargin
                    && longitudeDelta(flight.position.lon, center.longitude) <= longitudeMargin
            }

            guard inView.count > AppConfig.maxRenderedFlights else { return inView }

            return inView.sorted { first, second in
                Self.squaredDistance(first, center) < Self.squaredDistance(second, center)
            }
            .prefix(AppConfig.maxRenderedFlights)
            .map { $0 }
        }

        private static func squaredDistance(_ flight: Flight, _ center: CLLocationCoordinate2D) -> Double {
            let deltaLat = flight.position.lat - center.latitude
            let deltaLon = longitudeDelta(flight.position.lon, center.longitude)
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

        // MARK: MKMapViewDelegate

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
            sync(flights: parent.flights, on: mapView)
        }
    }
}

/// Identifiable wrapper so a tapped aircraft can drive `.sheet(item:)` while
/// the sheet itself always reads the newest data for that id.
struct SelectedFlight: Identifiable, Equatable {
    let id: String
}
