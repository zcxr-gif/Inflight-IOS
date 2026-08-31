import CoreLocation
import SwiftUI
import simd

/// The whole world at once, drawn rather than photographed.
///
/// The map has always been able to show a globe — `MapProjection.globe` — and
/// it has always been MapKit's globe: imagery over real elevation, which is a
/// photograph of the planet. A photograph is the wrong picture for a traffic
/// map. Cloud, coastline, city light and desert all compete with the sprites
/// for exactly the attention the sprites want, and no palette fixes it because
/// the detail is in the imagery.
///
/// So this one is a drawing: an unlit disc, every country as a hairline, a
/// graticule you have to look for, and nothing written on it anywhere. The
/// aircraft are then the only things on the planet with any colour in them,
/// which is what the view is for.
///
/// Its own screen rather than a third `MapProjection`, and that is a deliberate
/// limit rather than a shortcut. `TrackerMapView` is three thousand lines of
/// MapKit — weather tiles, the terminator, NAT tracks, gate layouts, measuring,
/// replay — and none of it is reachable from a renderer that is not MapKit.
/// Offering this as a projection would mean silently turning a dozen features
/// off when somebody picked it. As a screen of its own, alongside the sky view,
/// it is honestly what it is: a way of seeing where everybody is, which you
/// leave to go back to the map.
struct PlanetView: View {

    @EnvironmentObject private var feed: LiveFeed
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared

    /// Fields worth marking, worked out by the map and handed in rather than
    /// recomputed: ranking them walks the whole server twice, and the map has
    /// already done it for this packet.
    let airports: [MapAirport]

    /// Opening one of them, and opening an aircraft. Both hand back to the map,
    /// which owns every window in this app.
    let onSelectAirport: (Airport) -> Void
    let onSelectFlight: (Flight) -> Void

    /// Where the planet starts. The map's own centre, so opening this is a
    /// change of projection rather than a change of subject.
    let start: CLLocationCoordinate2D

    @State private var camera = GlobeCamera()
    @State private var size: CGSize = .zero

    /// The camera as it was when the current gesture began. Gestures report
    /// their whole translation each update, not the change since the last one,
    /// so applying them incrementally would compound.
    @State private var gestureStart: GlobeCamera?
    @State private var zoomStart: CGFloat?

    /// How far zoomed in, as a multiple of the radius that fits the viewport.
    @State private var scale: CGFloat = 1

    /// Whether the camera has been put where it was asked to start. Once, on
    /// the first layout — after that the camera is wherever it has been turned
    /// to, and a rotation must not fly it back to where the map was.
    @State private var isReady = false

    private var theme: FlightInfoTheme { appearance.theme }
    private var palette: GlobePalette { GlobePalette(theme: theme) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.windowFill.ignoresSafeArea()

                GlobeCanvas(
                    camera: camera,
                    palette: palette,
                    traffic: trafficDots
                )
                .ignoresSafeArea()

                markers

                chrome
            }
            .onAppear { layout(in: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in layout(in: newSize) }
            .contentShape(Rectangle())
            .gesture(turn)
            .simultaneousGesture(zoom)
        }
        .background(theme.windowFill)
        .environment(\.colorScheme, theme.colorScheme)
        .statusBarHidden()
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
                if gestureStart == nil { gestureStart = camera }

                var moved = base
                moved.turn(by: value.translation)
                camera = moved
            }
            .onEnded { value in
                let travelled = abs(value.translation.width) + abs(value.translation.height)
                if travelled < 6, let flight = flight(near: value.startLocation) {
                    onSelectFlight(flight)
                    dismiss()
                }
                gestureStart = nil
            }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomStart ?? scale
                if zoomStart == nil { zoomStart = scale }

                scale = min(
                    GlobeCamera.maximumScale,
                    max(GlobeCamera.minimumScale, base * value.magnification)
                )
                camera.radius = fittedRadius(in: size) * scale
            }
            .onEnded { _ in zoomStart = nil }
    }

    // MARK: - What is on it

    /// Every aircraft the filters would draw, as a direction and a colour.
    ///
    /// Rebuilt per packet rather than held: it is one pass over the packet
    /// doing three multiplies apiece, which is cheaper than the diffing that
    /// keeping it in state would need.
    private var trafficDots: [GlobeTrafficDot] {
        let highlighting = PilotHighlighting.current()

        return visible.map { flight in
            GlobeTrafficDot(
                position: GlobeGeometry.vector(flight.coordinate),
                tint: highlighting.tint(for: flight.username),
                isOpen: false
            )
        }
    }

    /// The packet as the filters leave it. Read three times a redraw — the
    /// dots, the count, and the tap — so it is worked out once.
    private var visible: [Flight] {
        filters.apply(to: feed.flights)
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
        let reach: CGFloat = 22

        var best: Flight?
        var bestDistance = reach * reach

        for flight in visible {
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

    /// The fields, as SwiftUI so they can carry a label and a tap.
    ///
    /// Only the ones on the near side, and faded as they approach the limb: a
    /// marker at the edge of the disc is on ground turning away from you, and
    /// drawing it at full strength makes the planet look flat.
    private var markers: some View {
        let basis = camera.basis

        return ZStack(alignment: .topLeading) {
            ForEach(airports) { field in
                let projected = camera.project(
                    GlobeGeometry.vector(field.airport.coordinate),
                    using: basis
                )

                if projected.depth > 0.02 {
                    GlobeAirportMarker(
                        field: field,
                        theme: theme,
                        // Full strength across most of the near side, falling
                        // away only in the last stretch before the limb.
                        opacity: min(1, Double(projected.depth) / 0.28)
                    ) {
                        onSelectAirport(field.airport)
                        dismiss()
                    }
                    .position(projected.point)
                }
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("THE PLANET")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(theme.textDim)

                    Text(feed.server)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 12)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 34, height: 34)
                        .flightInfoSurface(theme, in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the planet")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer(minLength: 0)

            HintStrip(placement: .map)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
        }
    }

    private var subtitle: String {
        let aircraft = visible.count
        let fields = airports.count
        return "\(Format.number(Double(aircraft))) aircraft · \(fields) field\(fields == 1 ? "" : "s")"
    }
}

/// One field on the planet: a ring, the code beside it, and nothing else.
///
/// The ring rather than a pin, because a pin has a point and a point implies a
/// direction — on a sphere that is a lie everywhere but the middle of the
/// screen. A ring is the same shape from every angle.
private struct GlobeAirportMarker: View {

    let field: MapAirport
    let theme: FlightInfoTheme
    let opacity: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .strokeBorder(theme.textPrimary.opacity(0.55), lineWidth: 1)
                        .frame(width: 13, height: 13)

                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                }

                Text(field.airport.icao)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        // A marker on ground turning away is not something to tap by accident.
        .allowsHitTesting(opacity > 0.6)
        .accessibilityLabel(accessibility)
    }

    /// Green where somebody is working the field, plain where nobody is. The
    /// one piece of colour a marker carries, and it is the one thing about a
    /// field you cannot work out by looking at the traffic.
    private var dot: Color {
        field.isControlled ? Color(red: 0.42, green: 0.85, blue: 0.45) : theme.accent
    }

    private var accessibility: String {
        let staffed = field.isControlled
            ? "controlled, \(field.atcPositions.joined(separator: ", "))"
            : "uncontrolled"
        return "\(field.airport.icao), \(field.airport.name), \(staffed)"
    }
}
