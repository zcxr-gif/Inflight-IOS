import Combine
import CoreLocation
import SwiftUI
import UIKit
import simd

/// The planet, as a thing you can put on a screen.
///
/// Everything the globe *is* lives here — the camera, the gestures, the hit
/// testing, and the settings that decide what colour it comes in. What it
/// deliberately does not have is any chrome: no title, no close button, no
/// toolbar. That is what lets the same view be the whole-world screen you open
/// from the corner of the map and be the map itself, with the app's own chrome
/// standing over it, without either of them being a special case of the other.
struct PlanetSurface: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared

    /// The organised track system, which the planet draws for the same reason
    /// the flat map does: it is the answer to why several hundred aircraft are
    /// flying in parallel lines across an ocean.
    @ObservedObject private var natTracks = NatTrackService.shared

    /// The traffic, the fields and the route, rebuilt when a packet lands
    /// rather than when the planet turns. See `GlobeScene`.
    @StateObject private var scene = GlobeScene()

    /// The traffic to draw, already narrowed by the filters by whoever owns
    /// them — the same array the flat map is given.
    let flights: [Flight]

    /// Fields worth marking, worked out by the map and handed in rather than
    /// recomputed: ranking them walks the whole server twice, and the map has
    /// already done it for this packet.
    let airports: [MapAirport]

    /// A stamp of everything the scene is built from. The scene is rebuilt when
    /// this moves and at no other time.
    let signature: Int

    /// The aircraft whose window is open, drawn larger and with its route on
    /// the planet.
    var openFlightId: String? = nil
    var route: GlobeScene.GlobeRoute? = nil

    /// Where the planet is turned to when it first appears.
    let start: CLLocationCoordinate2D

    /// Camera moves asked for by the chrome — a search result, a tower, the
    /// "show me this flight" button. The same one-shot command the flat map
    /// takes, so the two answer the same instructions.
    var command: MapCommand? = nil

    /// A running playback of the open aircraft's own track, which puts it
    /// somewhere other than where the feed last saw it.
    var replayFrame: FlightReplay.Frame? = nil

    var onSelectFlight: (Flight) -> Void = { _ in }
    var onSelectAirport: (Airport) -> Void = { _ in }

    @State private var camera = GlobeCamera()
    @State private var size: CGSize = .zero

    /// The camera as it was when the current gesture began. Gestures report
    /// their whole translation each update, not the change since the last one,
    /// so applying them incrementally would compound.
    @State private var gestureStart: GlobeCamera?
    @State private var zoomStart: CGFloat?

    /// How far zoomed in, as a multiple of the radius that fits the viewport.
    @State private var scale: CGFloat = 1

    /// Whether a finger is on the planet. Handed to the canvas, which spends it
    /// on cartography detail.
    @State private var isInteracting = false

    /// Whether the camera has been put where it was asked to start. Once, on
    /// the first layout — after that the camera is wherever it has been turned
    /// to, and a rotation must not fly it back to where the map was.
    @State private var isReady = false

    /// Which command has already been carried out, so the same one arriving
    /// again with the next packet does not move the camera a second time.
    @State private var lastCommand: UUID?

    /// Where the sun is overhead. Refreshed on a slow timer rather than per
    /// frame: the terminator moves a quarter of a degree a minute.
    @State private var sun: SIMD3<Float>?

    /// Static, so the timer belongs to the type rather than to a `View` value
    /// that SwiftUI rebuilds whenever anything on screen changes. A stored
    /// `Timer.publish` on the struct would start a fresh one per body.
    private static let clock = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    private var theme: FlightInfoTheme { appearance.theme }
    private var skin: GlobeSkin { appearance.globeSkin }
    private var palette: GlobePalette { skin.palette(scheme: appearance.resolvedScheme) }

    private var backdrop: GlobeBackdropStyle {
        appearance.globeBackdrop.style(
            skin: skin,
            scheme: appearance.resolvedScheme,
            windowFill: UIColor(theme.windowFill)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            GlobeCanvas(
                camera: camera,
                palette: palette,
                backdrop: backdrop,
                scene: scene,
                revision: scene.revision,
                showsPlanes: appearance.globeShowsPlanes,
                showsFields: filters.showsAirports,
                sun: filters.showsTerminator ? sun : nil,
                replay: replayMark,
                isInteracting: isInteracting
            )
            // The canvas is a `UIView` that redraws itself the instant it is
            // told to. Anything animating the value handed to it would put the
            // planet a frame or two behind the finger turning it, which is
            // precisely the wobble this view exists to not have.
            .transaction { $0.animation = nil }
            .contentShape(Rectangle())
            .gesture(turn)
            .simultaneousGesture(zoom)
            .onAppear {
                layout(in: geometry.size)
                sun = Self.sunVector()
                rebuild()
            }
            .onChange(of: geometry.size) { _, newSize in layout(in: newSize) }
        }
        .onReceive(Self.clock) { _ in sun = Self.sunVector() }
        .onChange(of: sceneSignature) { _, _ in rebuild() }
        .onChange(of: command) { _, newValue in apply(newValue) }
    }

    // MARK: - What is on it

    /// A stamp of everything the scene is made of.
    ///
    /// The caller's own signature covers the packet and the filters; the rest
    /// is what this view adds on top of it. The skin is in here because the
    /// route is drawn in the palette's colour, so a change of skin is a change
    /// to something the scene is holding.
    private var sceneSignature: Int {
        var hasher = Hasher()
        hasher.combine(signature)
        hasher.combine(openFlightId)
        hasher.combine(appearance.globeSkin)
        hasher.combine(route?.position.latitude)
        hasher.combine(route?.position.longitude)
        hasher.combine(route?.departure?.latitude)
        hasher.combine(route?.departure?.longitude)
        hasher.combine(route?.arrival?.latitude)
        hasher.combine(route?.arrival?.longitude)
        hasher.combine(filters.showsNatTracks ? natTracks.tracks.count : 0)
        hasher.combine(filters.showsFlownPath)
        return hasher.finalize()
    }

    /// Where the open aircraft has actually been.
    ///
    /// Read out of the shared store at rebuild time rather than observed. The
    /// store publishes only when a history is seeded, and the path grows with
    /// every packet — which the caller's own signature already covers, since
    /// it is stamped with the packet the path grew from.
    private var flownPath: [CLLocationCoordinate2D] {
        guard filters.showsFlownPath, let id = openFlightId else { return [] }
        return FlightTrailStore.shared.points(for: id).map(\.coordinate)
    }

    /// Hands the scene everything it is built from, and lets it decide whether
    /// any of it has moved.
    private func rebuild() {
        // The map does this from its own sync pass, which is not running when
        // the planet is what the map is. Safe on every packet: a date
        // comparison until the hour is up.
        if filters.showsNatTracks { natTracks.refresh() }

        scene.rebuild(
            signature: sceneSignature,
            flights: flights,
            fields: airports,
            openFlightId: openFlightId,
            highlighting: PilotHighlighting.current(),
            route: route,
            flownPath: flownPath,
            natTracks: filters.showsNatTracks ? natTracks.tracks.map(\.coordinates) : [],
            palette: palette
        )
    }

    /// The playback's aeroplane, as directions on the sphere.
    ///
    /// Worked out in the body rather than in the scene, because a frame lands
    /// several times a second and the scene is the thing that must not be
    /// rebuilt at that rate. It is three trigonometric calls.
    private var replayMark: GlobeReplayMark? {
        guard let frame = replayFrame else { return nil }
        return GlobeReplayMark(
            position: GlobeGeometry.vector(frame.coordinate),
            heading: GlobeGeometry.headingVector(
                latitude: frame.coordinate.latitude,
                longitude: frame.coordinate.longitude,
                headingDegrees: frame.heading
            ),
            spriteKey: openFlight?.spriteKey ?? "TRIANGLE"
        )
    }

    private static func sunVector() -> SIMD3<Float> {
        let sun = SolarPosition.sun()
        return GlobeGeometry.vector(
            latitude: sun.declination * 180 / .pi,
            longitude: sun.subsolarLongitude
        )
    }

    // MARK: - Laying it out

    /// Sizes the planet to the viewport and puts it in the middle.
    ///
    /// Re-run on every size change, which is a rotation or a split view. The
    /// zoom is kept as a *multiple* rather than as a radius precisely so that
    /// survives: turning the phone sideways keeps you as close to the ground as
    /// you were, rather than as many points from the middle as you were.
    private func layout(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        self.size = size

        camera.center = CGPoint(x: size.width / 2, y: size.height / 2)
        camera.radius = fittedRadius(in: size) * scale

        if !isReady {
            camera.latitude = start.latitude
            camera.longitude = GlobeCamera.wrapped(start.longitude)
            isReady = true
        }
    }

    /// The radius at which the whole planet sits inside the screen with room
    /// for the chrome over it.
    private func fittedRadius(in size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.42
    }

    // MARK: - Turning it

    /// Turning the planet — and, when the finger did not actually go anywhere,
    /// opening whatever was under it.
    ///
    /// One gesture doing both because it has to: a `DragGesture` with no
    /// minimum distance swallows every tap in its area, so a separate
    /// `TapGesture` underneath it would never fire. The threshold is in points
    /// and generous, because a tap on a phone is rarely perfectly still.
    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = gestureStart ?? camera
                if gestureStart == nil {
                    gestureStart = camera
                    isInteracting = true
                }

                var moved = base
                moved.turn(by: value.translation)
                camera = moved
            }
            .onEnded { value in
                let travelled = abs(value.translation.width) + abs(value.translation.height)
                if travelled < 6 { tap(at: value.startLocation) }
                gestureStart = nil
                isInteracting = false
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomStart ?? scale
                if zoomStart == nil {
                    zoomStart = scale
                    isInteracting = true
                }

                scale = min(
                    GlobeCamera.maximumScale,
                    max(GlobeCamera.minimumScale, base * value.magnification)
                )
                camera.radius = fittedRadius(in: size) * scale
            }
            .onEnded { _ in
                zoomStart = nil
                isInteracting = false
            }
    }

    /// What was under the finger. Fields before aircraft: a field carries a
    /// label, so it is the larger target and the one somebody aiming at a
    /// cluster meant.
    private func tap(at point: CGPoint) {
        if filters.showsAirports, let field = field(near: point) {
            onSelectAirport(field.airport)
            return
        }
        if let flight = flight(near: point) {
            onSelectFlight(flight)
        }
    }

    /// The aircraft nearest a tap, if one is near enough to have been meant.
    ///
    /// Traffic is drawn into the canvas rather than as views, so there is
    /// nothing to attach a gesture to and the hit test is done here. Against
    /// the projected position rather than the coordinate, because "near" means
    /// near on the screen: two aircraft a hundred miles apart at the limb are a
    /// couple of points apart, and the one that looks closest to the finger is
    /// the one that was aimed at.
    private func flight(near point: CGPoint) -> Flight? {
        let basis = camera.basis
        let reach = GlobeMarkMetrics.touchRadius

        var best: Flight?
        var bestDistance = reach * reach

        for flight in flights {
            let projected = camera.project(GlobeGeometry.vector(flight.coordinate), using: basis)
            guard projected.isVisible else { continue }

            let dx = projected.point.x - point.x
            let dy = projected.point.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = flight
            }
        }
        return best
    }

    /// The field nearest a tap. Only the ones far enough onto the near side to
    /// have been drawn at something like full strength — a marker on ground
    /// turning away is not something to open by accident.
    private func field(near point: CGPoint) -> MapAirport? {
        let basis = camera.basis
        let reach = GlobeMarkMetrics.touchRadius

        var best: MapAirport?
        var bestDistance = reach * reach

        for field in airports {
            let projected = camera.project(
                GlobeGeometry.vector(field.airport.coordinate),
                using: basis
            )
            guard projected.depth > GlobeMarkMetrics.tappableDepth else { continue }

            // Biased towards the label, which sits to the right of the ring and
            // is most of what there is to aim at.
            let dx = projected.point.x + GlobeMarkMetrics.fieldRingRadius - point.x
            let dy = projected.point.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = field
            }
        }
        return best
    }

    // MARK: - Being told where to look

    /// Carries out a camera move asked for by the chrome.
    ///
    /// The same `MapCommand` the flat map takes, so a search result or an open
    /// tower moves the world whichever shape it is in — which is the whole
    /// point of the planet being a map rather than a screen you visit.
    private func apply(_ command: MapCommand?) {
        guard let command = command, command.id != lastCommand else { return }
        lastCommand = command.id

        switch command.kind {
        case .centerOnFlight:
            guard let flight = openFlight else { return }
            aim(at: flight.coordinate)

        case .fitRoute, .fitFlownPath:
            guard let flight = openFlight else { return }
            // A whole route on a globe is a matter of standing far enough back
            // to see both ends of it, and the planet has exactly one answer for
            // that: all of it.
            aim(at: flight.coordinate, scale: 1)

        case let .focus(latitude, longitude, spanMeters):
            aim(
                at: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                scale: zoomScale(forSpan: spanMeters)
            )
        }
    }

    private var openFlight: Flight? {
        guard let id = openFlightId else { return nil }
        return flights.first { $0.id == id }
    }

    private func aim(at coordinate: CLLocationCoordinate2D, scale newScale: CGFloat? = nil) {
        camera.latitude = min(90, max(-90, coordinate.latitude))
        camera.longitude = GlobeCamera.wrapped(coordinate.longitude)

        if let newScale = newScale {
            scale = min(GlobeCamera.maximumScale, max(GlobeCamera.minimumScale, newScale))
            camera.radius = fittedRadius(in: size) * scale
        }
    }

    /// The zoom that puts a span of ground across most of the screen.
    ///
    /// At the middle of an orthographic globe a point of screen is the sphere's
    /// radius in metres divided by its radius in points, so the arithmetic is
    /// one division — and it is only ever right in the middle, which is where
    /// the thing being focused on is about to be.
    private func zoomScale(forSpan meters: Double) -> CGFloat {
        let earthRadius: Double = 6_371_000
        let across = Double(min(size.width, size.height)) * 0.8
        guard meters > 1, across > 1 else { return scale }

        let wanted = earthRadius * across / meters
        let fitted = Double(fittedRadius(in: size))
        guard fitted > 0 else { return scale }

        return CGFloat(wanted / fitted)
    }
}
