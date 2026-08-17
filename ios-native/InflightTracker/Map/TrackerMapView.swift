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

    /// Where the replay has got to, when one is running. The map draws a
    /// second aircraft at this position, riding the track the selected flight
    /// has already flown.
    var replayFrame: FlightReplay.Frame?

    /// Whether the map should stay with the open aircraft as it flies.
    ///
    /// Distinct from the centre button beside it, which is a single move: this
    /// is a mode, and it keeps acting on every packet for as long as it is on.
    var isFollowing = false

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

        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.replayReuseIdentifier
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(flights: flights, on: mapView)
        context.coordinator.syncSelection(selection, on: mapView)
        context.coordinator.syncRoute(on: mapView)
        context.coordinator.syncReplay(on: mapView)
        // Before the command, so a camera move asked for on this same tick is
        // the one that lands rather than being pulled back by the follow.
        context.coordinator.followSelection(on: mapView)
        context.coordinator.handle(command, on: mapView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {

        static let reuseIdentifier = "flight"
        static let replayReuseIdentifier = "replay"

        var parent: TrackerMapView

        private var annotations: [String: FlightAnnotation] = [:]

        /// When each drawn aircraft was last in a packet, so one the feed skips
        /// for a moment can be held rather than removed and re-added.
        private var lastSeen: [String: Date] = [:]

        /// Throttle for the re-cull that runs *during* a drag.
        private var lastLiveCull = Date.distantPast

        /// Set while MapKit's own selection callbacks are being handled, so we
        /// don't bounce the change straight back into the map.
        private var isApplyingSelection = false

        /// Debounced viewport re-cull, cancelled if the map keeps moving.
        private var pendingCull: DispatchWorkItem?

        /// What the drawn route currently represents, so overlays are only
        /// rebuilt when the trail actually grows.
        private var renderedRouteKey: String?
        private var routeOverlays: [MKPolyline] = []

        /// The replay's aircraft, while one is playing.
        private var replayAnnotation: ReplayAnnotation?

        private var handledCommand: UUID?

        init(_ parent: TrackerMapView) {
            self.parent = parent
        }

        // MARK: Annotation syncing

        func sync(flights: [Flight], on mapView: MKMapView) {
            let now = Date()
            let visible = cull(flights: flights, to: mapView)
            var seen = Set<String>()
            var additions: [FlightAnnotation] = []

            for flight in visible {
                seen.insert(flight.id)
                lastSeen[flight.id] = now

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

            // An aircraft still in the packet but outside the keep margin has
            // been culled deliberately: it is off screen, so dropping it now
            // costs nothing to look at. One that has vanished from the packet
            // altogether is a different case — the feed skips an aircraft for a
            // packet or two and has it back, and removing it in the gap is
            // exactly the blink this is here to stop. Those keep their last
            // position until the grace period is up.
            let selectedId = parent.selection?.id
            let reported = Set(flights.map(\.id))

            var removals: [FlightAnnotation] = []

            for (id, annotation) in annotations {
                guard id != selectedId, !seen.contains(id) else { continue }

                if !reported.contains(id),
                   now.timeIntervalSince(lastSeen[id] ?? .distantPast) < AppConfig.flightGracePeriod {
                    continue
                }

                removals.append(annotation)
            }

            if !removals.isEmpty {
                mapView.removeAnnotations(removals)
                for annotation in removals {
                    annotations.removeValue(forKey: annotation.flightId)
                    lastSeen.removeValue(forKey: annotation.flightId)
                }
            }

            if !additions.isEmpty {
                mapView.addAnnotations(additions)
            }
        }

        /// Everything within reach of the viewport — all of it.
        ///
        /// There is no ceiling on how many aircraft the map will draw: if the
        /// server has two thousand aeroplanes in view, the map has two thousand
        /// aeroplanes on it. Culling is by position only, and it exists to keep
        /// MapKit from holding annotations for traffic on the other side of the
        /// world rather than to ration what you can see.
        ///
        /// The boundary is hysteretic: an aircraft has to come well inside the
        /// view to be added, and travel well outside it to be dropped, so
        /// nothing sitting on the edge can flip between the two on consecutive
        /// passes.
        private func cull(flights: [Flight], to mapView: MKMapView) -> [Flight] {
            let region = mapView.region
            guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else {
                return flights
            }

            let center = region.center
            let addLatitude = region.span.latitudeDelta * AppConfig.flightAddMargin
            let addLongitude = region.span.longitudeDelta * AppConfig.flightAddMargin
            let keepLatitude = region.span.latitudeDelta * AppConfig.flightKeepMargin
            let keepLongitude = region.span.longitudeDelta * AppConfig.flightKeepMargin

            return flights.filter { flight in
                let deltaLatitude = abs(flight.latitude - center.latitude)
                let deltaLongitude = Self.longitudeDelta(flight.longitude, center.longitude)

                // Already on the map, so it is held to the wider boundary.
                let isDrawn = annotations[flight.id] != nil

                return deltaLatitude <= (isDrawn ? keepLatitude : addLatitude)
                    && deltaLongitude <= (isDrawn ? keepLongitude : addLongitude)
            }
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

        // MARK: Replay

        /// The aircraft the replay is currently drawing, moved rather than
        /// replaced on each frame — `coordinate` is KVO-observed by MapKit, so
        /// assigning it slides the view instead of removing and re-adding an
        /// annotation twenty times a second.
        func syncReplay(on mapView: MKMapView) {
            guard let frame = parent.replayFrame else {
                if let existing = replayAnnotation {
                    mapView.removeAnnotation(existing)
                    replayAnnotation = nil
                }
                return
            }

            // The replayed aircraft is the open one; its key is held on the
            // annotation so the sprite survives the flight dropping out of the
            // feed part way through a playback.
            let spriteKey = selectedFlight()?.spriteKey

            if let existing = replayAnnotation {
                existing.coordinate = frame.coordinate
                existing.heading = frame.heading
                if let spriteKey = spriteKey { existing.spriteKey = spriteKey }

                if let view = mapView.view(for: existing) {
                    apply(replay: existing, to: view)
                }
            } else {
                let annotation = ReplayAnnotation(
                    coordinate: frame.coordinate,
                    heading: frame.heading,
                    spriteKey: spriteKey ?? ""
                )
                replayAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            keepInView(frame.coordinate, on: mapView)
        }

        // MARK: Following

        /// Keeps the open aircraft on screen as the feed moves it, while the
        /// follow mode is on.
        ///
        /// The same rule the replay follows, and for the same reason: an
        /// aircraft at cruise crosses the middle half of a zoomed-out map in
        /// minutes, so this is a nudge every few packets rather than a camera
        /// glued to the aeroplane. A map the user has just dragged stays where
        /// they put it until the aircraft genuinely leaves it.
        func followSelection(on mapView: MKMapView) {
            guard parent.isFollowing, let flight = selectedFlight() else { return }
            keepInView(flight.coordinate, on: mapView)
        }

        /// Pans to bring a moving aircraft back, but only once it has left the
        /// middle of the map. Re-centring on every frame would take the map
        /// away from wherever the user had just dragged it.
        private func keepInView(_ coordinate: CLLocationCoordinate2D, on mapView: MKMapView) {
            let point = MKMapPoint(coordinate)
            let visible = mapView.visibleMapRect

            // The middle half. Inside it, the aircraft is comfortably on
            // screen and the map is left alone.
            let comfortable = visible.insetBy(
                dx: visible.width * 0.25,
                dy: visible.height * 0.25
            )

            guard !comfortable.contains(point) else { return }

            let rect = MKMapRect(
                x: point.x - visible.width / 2,
                y: point.y - visible.height / 2,
                width: visible.width,
                height: visible.height
            )

            mapView.setVisibleMapRect(rect, edgePadding: edgeInsets(), animated: true)
        }

        private func apply(replay annotation: ReplayAnnotation, to view: MKAnnotationView) {
            view.image = PlaneSprites.shared.icon(forKey: annotation.spriteKey, selected: true)
            view.transform = CGAffineTransform(rotationAngle: CGFloat(annotation.heading) * .pi / 180)
        }

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
            if let replay = annotation as? ReplayAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.replayReuseIdentifier,
                    for: replay
                )
                view.canShowCallout = false
                view.displayPriority = .required
                // Never hidden behind live traffic: the replay is the thing
                // being watched.
                view.zPriority = .max
                view.isEnabled = false

                apply(replay: replay, to: view)
                return view
            }

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

        /// Fires continuously through a drag or a pinch, which is the point:
        /// waiting for the gesture to end meant aircraft arrived in a batch
        /// once the map settled, and a pan into empty sky stayed empty until
        /// you let go. Throttled, since this can fire every frame.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let now = Date()
            guard now.timeIntervalSince(lastLiveCull) >= Self.liveCullInterval else { return }
            lastLiveCull = now

            sync(flights: parent.flights, on: mapView)
        }

        private static let liveCullInterval: TimeInterval = 0.25

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
