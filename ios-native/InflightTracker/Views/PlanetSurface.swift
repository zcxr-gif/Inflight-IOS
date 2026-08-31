import Combine
import CoreLocation
import SwiftUI
import UIKit
import simd

/// The planet, as a thing you can put on a screen.
///
/// What lives here is everything the planet is *made of* — which packet, which
/// fields, which colours, where the sun is — and nothing about how it is drawn
/// or turned. The camera, the gestures and the hit testing are all inside
/// `GlobeCanvasView`, deliberately: a pan that went through SwiftUI state cost
/// a body evaluation, a fresh representable and an `updateUIView` per frame, to
/// move a value nothing in SwiftUI ever read.
///
/// What it also does not have is any chrome: no title, no close button, no
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

    /// The pavement store, observed so that a layout arriving from the network
    /// after the planet has already settled over the field still gets drawn.
    @ObservedObject private var layouts = AirportLayoutStore.shared

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

    /// Whether the traffic is carried between packets rather than jumping to
    /// each one. The map's own setting, resolved by whoever owns it — the
    /// planet draws what it is told, and Reduce Motion is not its business.
    var smoothsTraffic: Bool = true

    /// How much of the bottom and the right of the view is spoken for by the
    /// chrome standing over it — the toolbar, or the flight window.
    ///
    /// The planet is put in the middle of what is *left*, which is the same
    /// thing MapKit's layout margins do for the flat map. Without it the one
    /// aeroplane you have opened a window on is centred behind that window.
    var bottomInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var onSelectFlight: (Flight) -> Void = { _ in }
    var onSelectAirport: (Airport) -> Void = { _ in }

    /// Where the sun is overhead. Refreshed on a slow timer rather than per
    /// frame: the terminator moves a quarter of a degree a minute.
    @State private var sun: SIMD3<Float>?

    /// Where the planet has settled, reported by the canvas. The camera itself
    /// stays down in the canvas — this is a place, not a camera, and it only
    /// moves when the planet stops.
    @State private var spot: CameraSpot?

    /// Whichever field the planet is currently over, so the arrival of *its*
    /// layout is the thing that redraws.
    @State private var groundIcao: String?

    private struct CameraSpot: Equatable {
        var latitude: Double
        var longitude: Double
        var spanMetres: Double
    }

    /// How much ground has to be on screen before a field's pavement is worth
    /// *fetching*, in metres.
    ///
    /// Deliberately much wider than the zoom it is drawn at — see
    /// `GlobeCanvasView.drawGround` — and that gap is the point. A layout is
    /// an Overpass round trip, so asking for it at the moment it becomes
    /// visible means several seconds of an empty aerodrome first. Asking about
    /// an octave and a half earlier means it is already there.
    ///
    /// The flat map's nine nautical miles is the number for a map that is
    /// already drawing roads under you. Here there is nothing else at that
    /// zoom, and nine miles is the last one per cent of a zoom range that now
    /// runs to two hundred metres — you could pinch ten times without ever
    /// finding out the layer existed.
    private static let groundLoadSpanMetres: Double = 50 * 1852

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
        GlobeCanvas(
            palette: palette,
            backdrop: backdrop,
            scene: scene,
            revision: scene.revision,
            showsPlanes: appearance.globeShowsPlanes,
            showsFields: filters.showsAirports,
            sun: filters.showsTerminator ? sun : nil,
            replay: replayMark,
            smoothsTraffic: smoothsTraffic,
            start: start,
            bottomInset: bottomInset,
            trailingInset: trailingInset,
            command: globeCommand,
            onCameraMoved: { centre, span in
                spot = CameraSpot(
                    latitude: centre.latitude,
                    longitude: centre.longitude,
                    spanMetres: span
                )
            },
            onSelectFlight: { id in
                guard let flight = flights.first(where: { $0.id == id }) else { return }
                onSelectFlight(flight)
            },
            onSelectField: { icao in
                guard let field = airports.first(where: { $0.airport.icao == icao }) else { return }
                onSelectAirport(field.airport)
            }
        )
        // No SwiftUI gesture, and no SwiftUI camera. Turning the planet is a
        // `UIPanGestureRecognizer` on the canvas itself, mutating a struct it
        // owns and redrawing — so a drag costs no body evaluation here at all.
        // It used to cost one per frame, plus a fresh representable and an
        // `updateUIView`, to move a value nothing in SwiftUI ever read.
        .onAppear {
            sun = Self.sunVector()
            rebuild()
        }
        .onReceive(Self.clock) { _ in sun = Self.sunVector() }
        .onChange(of: sceneSignature) { _, _ in rebuild() }
        .onChange(of: spot) { _, _ in syncGround() }
        // The field is asked for the moment the planet settles over it and the
        // answer arrives from the network some time later. This is that later.
        .onChange(of: layouts.state(for: groundIcao ?? "")) { _, _ in syncGround() }
    }

    // MARK: - The ground

    /// Puts the pavement of whichever field the planet is sitting over into
    /// the scene, once it is close enough for pavement to mean anything.
    ///
    /// The same shape as the flat map's `syncGround`, and for the same reason:
    /// resolving which field a place belongs to is a walk over the whole
    /// airport dataset on a cache miss, so it happens when the planet stops
    /// moving rather than while it is moving.
    private func syncGround() {
        guard let spot = spot, spot.spanMetres <= Self.groundLoadSpanMetres else {
            groundIcao = nil
            scene.setGround(nil)
            return
        }

        let centre = CLLocationCoordinate2D(
            latitude: spot.latitude,
            longitude: spot.longitude
        )
        guard let field = AirportStore.shared.nearestAirport(
            to: centre,
            withinNM: 9
        ) else {
            groundIcao = nil
            scene.setGround(nil)
            return
        }

        if groundIcao != field.icao { groundIcao = field.icao }

        if case .idle = layouts.state(for: field.icao) {
            // Off the update, not inside it. `load` publishes, and publishing
            // from inside a SwiftUI update is the warning SwiftUI exists to
            // give.
            DispatchQueue.main.async { layouts.load(field) }
            return
        }

        guard let layout = layouts.layout(for: field.icao) else { return }
        scene.setGround(GlobeGround(layout, at: field.coordinate))
    }

    /// The chrome's camera request, in the terms the canvas takes.
    ///
    /// Worked out here rather than in the canvas because the span-to-zoom
    /// arithmetic needs to know what a screen is, and because `MapCommand` is
    /// MapKit's vocabulary — the renderer should not have to learn it.
    private var globeCommand: GlobeCommand? {
        guard let command = command else { return nil }

        switch command.kind {
        case .centerOnFlight:
            guard let flight = openFlight else { return nil }
            return GlobeCommand(
                latitude: flight.latitude,
                longitude: flight.longitude,
                scale: nil,
                token: command.id
            )

        case .fitRoute, .fitFlownPath:
            guard let flight = openFlight else { return nil }
            // A whole route on a globe is a matter of standing far enough back
            // to see both ends of it, and the planet has exactly one answer for
            // that: all of it.
            return GlobeCommand(
                latitude: flight.latitude,
                longitude: flight.longitude,
                scale: 1,
                token: command.id
            )

        case let .focus(latitude, longitude, spanMeters):
            return GlobeCommand(
                latitude: latitude,
                longitude: longitude,
                scale: zoomScale(forSpan: spanMeters),
                token: command.id
            )
        }
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
        hasher.combine(smoothsTraffic)
        return hasher.finalize()
    }

    /// Where the open aircraft has actually been, with the height it was at
    /// when it was there — which is what the path is coloured by.
    ///
    /// Read out of the shared store at rebuild time rather than observed. The
    /// store publishes only when a history is seeded, and the path grows with
    /// every packet — which the caller's own signature already covers, since
    /// it is stamped with the packet the path grew from.
    ///
    /// The aircraft's own position is deliberately *not* on the end of it. The
    /// track ends at the newest breadcrumb; the piece from there to where the
    /// aeroplane is being drawn is redrawn on the frame clock by the canvas,
    /// so the line stays attached to an aircraft that is moving between
    /// packets rather than catching it up in a jump.
    private var flownPath: [TrackPoint] {
        guard filters.showsFlownPath, let id = openFlightId else { return [] }

        // Where it was before we were watching. Rate-limited inside the
        // service, so asking on every rebuild is a dictionary lookup rather
        // than a request — and asking at all is what the planet did not do:
        // it drew whatever fragment had been recorded since the app opened
        // while the flat map drew the same flight from its departure.
        FlightHistoryService.shared.ensureHistory(for: id)

        return FlightTrailStore.shared.points(for: id)
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
            smoothsTraffic: smoothsTraffic,
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

    private var openFlight: Flight? {
        guard let id = openFlightId else { return nil }
        return flights.first { $0.id == id }
    }

    /// The zoom that puts a span of ground across most of the screen.
    ///
    /// At the middle of an orthographic globe a point of screen is the sphere's
    /// radius in metres divided by its radius in points, so the arithmetic is
    /// one division — and it is only ever right in the middle, which is where
    /// the thing being focused on is about to be.
    ///
    /// The screen cancels out, which is why this needs to know nothing about
    /// it. Both halves are fractions of the same short side — the span is meant
    /// to fill four fifths of it, and the fitted planet is 0.42 of it — so what
    /// is left is a ratio, and the same one on every device. The canvas clamps
    /// it to the zoom range; a span closer than the top of that range simply
    /// arrives at the top of it.
    private static let spanToFitted = 0.8 / 0.42

    private func zoomScale(forSpan meters: Double) -> CGFloat? {
        guard meters > 1 else { return nil }
        return CGFloat(6_371_000 * Self.spanToFitted / meters)
    }
}
