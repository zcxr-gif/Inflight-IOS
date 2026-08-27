import MapKit
import SwiftUI
import UIKit

/// An `MKMapView` that keeps Apple's "Legal" link out from under the app's own
/// chrome.
///
/// MapKit lays its ornaments out inside the view's layout margins, and that is
/// the only supported way to move them. The map here runs edge to edge under a
/// search field, a toolbar, a stats card and the flight window, so left at the
/// default the link — which Apple's terms require to be visible and tappable —
/// spends its whole life behind the bar along the bottom.
///
/// The margins are worked out at layout time rather than being set from
/// `updateUIView`, because they depend on the safe area, which arrives with the
/// window and not with the state that asked for them.
final class ChromeInsetMapView: MKMapView {

    /// How much of the bottom of the map the app is covering, measured from the
    /// top of the bottom safe area — the same units the SwiftUI chrome floating
    /// over the map is laid out in.
    var chromeInset: CGFloat = 0 {
        didSet {
            guard chromeInset != oldValue else { return }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        // The map ignores the safe area so the cartography reaches the corners
        // of the screen; the ornaments still have to sit inside it. Read off the
        // window because that is the one place the real insets survive being
        // ignored.
        let safeArea = window?.safeAreaInsets ?? safeAreaInsets

        let margins = UIEdgeInsets(
            top: safeArea.top,
            left: safeArea.left + 16,
            bottom: safeArea.bottom + chromeInset,
            right: safeArea.right + 16
        )

        // Assigning margins asks for another layout pass, so this only assigns
        // when they have actually moved.
        if layoutMargins != margins { layoutMargins = margins }

        super.layoutSubviews()
    }

    // The safe area is read above rather than inherited, so the two moments it
    // can change under us — being put in a window, and the window turning — are
    // the two that have to ask for another pass.

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
}

/// The live map. A thin SwiftUI wrapper over `MKMapView` — MapKit gives us a
/// fully native map with no API key, tile budget, or web view involved.
struct TrackerMapView: UIViewRepresentable {

    let flights: [Flight]
    @Binding var selection: SelectedFlight?

    /// One-shot camera moves from the buttons beside the info window. Carries a
    /// token so the same request isn't replayed on every feed tick.
    var command: MapCommand?

    /// Bumped when a flight's backend history lands, so the pass that draws the
    /// path happens the moment there is a path rather than on the next packet.
    /// See `FlightTrailStore.seedRevision`.
    var trailRevision: Int = 0

    /// How much of the bottom of the map the info window is covering, so a
    /// framed route isn't hidden behind it.
    var bottomInset: CGFloat = 0

    /// And how much of its right-hand edge, for the same reason.
    ///
    /// Only ever non-zero on a screen wide enough to stand the flight window
    /// down the side of the map instead of across the bottom of it — a sheet
    /// covers the bottom and nothing else, so until there were panes there was
    /// only ever one side of this to answer for.
    var trailingInset: CGFloat = 0

    /// How far up MapKit's own ornaments have to sit — which here means Apple's
    /// "Legal" link, since the compass and the scale are both off.
    ///
    /// Separate from the inset above because the two answer different
    /// questions: that one is how much of the map a camera move should avoid
    /// framing into, this one is how much of it the app is drawing furniture
    /// over. The stats card counts towards this and not towards that.
    var legalInset: CGFloat = 0

    /// Where the replay has got to, when one is running. The map draws a
    /// second aircraft at this position, riding the track the selected flight
    /// has already flown.
    var replayFrame: FlightReplay.Frame?

    /// Whether the map should stay with the open aircraft as it flies.
    ///
    /// Distinct from the centre button beside it, which is a single move: this
    /// is a mode, and it keeps acting on every packet for as long as it is on.
    var isFollowing = false

    /// Which way round the map is drawn: the palette's own answer when it has
    /// one, and the app's appearance setting when it hasn't. Passed in rather
    /// than read from the environment: the map is the one surface underneath
    /// everything else, so it has to be told, not stamped.
    var colorScheme: ColorScheme = .dark

    /// How the map underneath the traffic is drawn — its shape, its palette,
    /// how much detail it carries, and with the globe whether the camera is
    /// free to rotate and tilt.
    var style = MapLook()

    /// A stamp of the packet and the filters behind `flights`.
    ///
    /// SwiftUI hands this view to `updateUIView` every time the screen around
    /// it redraws — a keystroke in the search field, a chip opening, twenty
    /// times a second while a replay runs — and none of those change the
    /// traffic. Diffing several thousand aircraft to discover that is the work
    /// this exists to skip.
    var trafficRevision: Int = 0

    /// Fields worth marking — controlled, or busy. Empty when the filter is
    /// off, which is how the whole feature is switched off.
    var airports: [MapAirport] = []

    /// Bumped when the list above is rebuilt, so the markers are re-diffed on a
    /// new ranking rather than on every redraw.
    var airportsRevision: Int = 0

    /// Whether to draw the pavement of the field the map is over — runways,
    /// taxiways, aprons and terminals, with the runway designators.
    var showsGroundLayout = true
    var showsFlightPlan = false

    /// The weather tiles to draw under the traffic, if any. Nil is the layer
    /// switched off, or switched on and still waiting for the frame index.
    var weatherTiles: MapWeatherTiles?

    /// Told when the weather tiles stop being worth drawing at this zoom, or
    /// start again. The map is the only thing that knows how wide the view is;
    /// the strip over it is where the reason belongs.
    var onWeatherLegibility: (Bool) -> Void = { _ in }

    /// The ruler: whether it is down, and where its two ends are. A binding
    /// because the map is where the taps land, so the map is what moves it.
    @Binding var measurement: MapMeasurement

    /// Whether night is washed over the half of the world that is in it.
    var showsTerminator = false

    /// Whether the North Atlantic organised tracks are drawn.
    var showsNatTracks = false

    /// Whether model wind is drawn across the visible map, and at what height.
    var showsWinds = false
    var windLevel: WindLevel = .fl340

    /// Whether a marked field carries its wind and temperature once the map is
    /// close enough for them to be read.
    var showsFieldConditions = true

    /// Observed so a layout that arrives from the network after the map has
    /// settled is drawn when it lands, rather than waiting for the next pan.
    /// Not private, because one private stored property would make the
    /// memberwise initialiser private along with it.
    @ObservedObject var layouts = AirportLayoutStore.shared

    /// Observed for the same reason: a grid of wind fetched for this region
    /// lands well after the pan that asked for it.
    @ObservedObject var winds = WindsAloftStore.shared

    /// And again: the track set is fetched when the layer is switched on, and
    /// lands a moment later.
    @ObservedObject var natTracks = NatTrackService.shared

    /// Opening a field that was tapped on the map. Separate from `selection`,
    /// which is an aircraft and drives the flight window.
    var onSelectAirport: (String) -> Void = { _ in }

    /// Which aircraft get picked out of the traffic, and in what colour.
    /// Equatable, so the coordinator repaints the sprites only when something
    /// about it actually changed.
    var highlighting = PilotHighlighting()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ChromeInsetMapView {
        let mapView = ChromeInsetMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll

        // The map view works its own margins out, safe area included, so UIKit
        // widening them again on top of that would put Apple's link somewhere
        // neither of us chose.
        mapView.insetsLayoutMarginsFromSafeArea = false

        // Both are driven by the style from `updateUIView`. A sprite's rotation
        // is its true heading, so anything but north-up means correcting every
        // annotation against the camera — which only the globe asks for.
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        // MapKit's controls and callouts default to the system blue; the
        // tracker's chrome is monochrome and stays that way — white on carbon,
        // ink on paper, resolved against whichever style the map is in.
        mapView.tintColor = UIColor { traits in
            traits.userInterfaceStyle == .light ? UIColor(white: 0.10, alpha: 1) : .white
        }

        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.reuseIdentifier
        )

        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.replayReuseIdentifier
        )

        mapView.register(
            GroundLabelView.self,
            forAnnotationViewWithReuseIdentifier: GroundLabelView.reuseIdentifier
        )

        mapView.register(
            AirportAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: AirportAnnotationView.reuseIdentifier
        )

        mapView.register(
            PlanWaypointView.self,
            forAnnotationViewWithReuseIdentifier: PlanWaypointView.reuseIdentifier
        )

        mapView.register(
            WindBarbView.self,
            forAnnotationViewWithReuseIdentifier: WindBarbView.reuseIdentifier
        )

        mapView.register(
            MeasurePointView.self,
            forAnnotationViewWithReuseIdentifier: MeasurePointView.reuseIdentifier
        )

        // Installed once and left there. It does nothing at all unless the
        // ruler is down, and its delegate turns away any touch that landed on
        // an annotation — so tapping an aeroplane still opens the aeroplane,
        // even mid-measurement.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMeasureTap(_:))
        )
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ mapView: ChromeInsetMapView, context: Context) {
        context.coordinator.parent = self

        // Apple's terms require their link to be visible and tappable, and the
        // map runs edge to edge underneath a toolbar, a stats card and the
        // flight window. Told here, applied on the map's own next layout pass,
        // where the safe area is known.
        mapView.chromeInset = legalInset

        // Weather first: the tiles go under everything else the map draws, and
        // adding them at the bottom of the pass keeps that ordering honest.
        context.coordinator.syncTerminator(on: mapView)
        context.coordinator.syncMeasurement(on: mapView)
        context.coordinator.syncWeatherTiles(on: mapView)
        context.coordinator.syncWinds(on: mapView)
        context.coordinator.syncNatTracks(on: mapView)

        // The scheme goes on *after* the style, and is forced whenever the
        // style actually swapped the map's configuration. See `applyScheme`:
        // doing it the other way round is what left the cartography sitting on
        // whatever it was already drawing.
        let swapped = context.coordinator.applyStyle(style, on: mapView)
        context.coordinator.applyScheme(colorScheme, on: mapView, force: swapped)
        context.coordinator.applyHighlighting(highlighting, on: mapView)
        // Both of these diff a list against what is drawn, and both are handed
        // the stamp that says whether the list can have changed. Panning is not
        // covered by the stamp and does not need to be: the map's own region
        // callbacks re-cull directly, on their own throttle.
        context.coordinator.syncIfNeeded(flights: flights, revision: trafficRevision, on: mapView)
        context.coordinator.syncAirports(airports, revision: airportsRevision, on: mapView)
        context.coordinator.syncSelection(selection, on: mapView)
        context.coordinator.syncRoute(on: mapView)
        context.coordinator.syncReplay(on: mapView)
        context.coordinator.syncGround(on: mapView)
        // Before the command, so a camera move asked for on this same tick is
        // the one that lands rather than being pulled back by the follow.
        context.coordinator.followSelection(on: mapView)
        context.coordinator.handle(command, on: mapView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        static let reuseIdentifier = "flight"
        static let replayReuseIdentifier = "replay"

        var parent: TrackerMapView

        private var annotations: [String: FlightAnnotation] = [:]

        /// The flight category each marked field was last drawn in, so a
        /// report that lands after the marker repaints it. Without this the
        /// field diff is the only thing that redraws a marker, and a field
        /// whose traffic has not changed would keep its old colour.
        private var renderedCategories: [String: String] = [:]

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

        /// Flights whose backend history this map has already asked for.
        private var requestedHistory: Set<String> = []

        /// The flown path currently on the map, and the ramp laid along it.
        ///
        /// Held here rather than on the overlay because `MKPolyline` carries
        /// nothing but a title, and there is only ever one flown path — the
        /// open aircraft's. The renderer reads it back when MapKit asks for a
        /// renderer, which is after the overlay has been added.
        private var flownRamp: FlownPath?

        /// How wide that path is drawn, in points.
        ///
        /// Narrower the further back the camera stands. See `FlownPathStyle`:
        /// a fixed width is a line zoomed in and a filled shape zoomed out.
        private var flownWidth: CGFloat = FlownPathStyle.closeWidth

        /// The fix names on the open flight's filed plan. Kept separately from
        /// `groundLabels` so that turning the plan off, or opening another
        /// aircraft, does not take an airport's runway designators with it.
        private var planLabels: [MKAnnotation] = []

        /// The field whose pavement is currently drawn, and what was drawn for
        /// it. One field at a time: two are never both close enough to matter,
        /// and a layout is a few hundred overlays.
        private var renderedGroundIcao: String?
        private var groundOverlays: [MKOverlay] = []
        private var groundLabels: [MKAnnotation] = []

        /// The replay's aircraft, while one is playing.
        private var replayAnnotation: ReplayAnnotation?

        private var handledCommand: UUID?

        /// The style currently applied to the map view, so the configuration is
        /// only swapped when it actually changes — assigning
        /// `preferredConfiguration` reloads the map's tiles.
        private var appliedStyle: MapLook?

        /// The scheme the cartography was last told to draw in.
        ///
        /// Tracked here rather than read back off `overrideUserInterfaceStyle`,
        /// because that property reports whatever it was assigned whether or
        /// not the map ever acted on it — which is exactly the failure the
        /// forcing below exists to survive.
        private var appliedScheme: ColorScheme?

        /// The black wash under the traffic, while a palette asks for one.
        private var dimmingOverlay: MapDimming.Overlay?

        /// Field markers currently on the map, by ICAO.
        private var airportAnnotations: [String: AirportAnnotation] = [:]

        /// The highlighting the drawn sprites were painted with.
        private var appliedHighlighting = PilotHighlighting()

        /// The camera bearing every drawn sprite is currently corrected
        /// against.
        ///
        /// North-up styles hold this at zero and the correction is a no-op. On
        /// the globe it is whatever the camera has been spun to, and a sprite's
        /// rotation is its true heading *minus* this — otherwise turning the
        /// planet turns every aircraft on it, and they all point the wrong way.
        private var appliedCameraHeading: CLLocationDirection = 0

        /// How far ahead of an aircraft the heading probe is put, in metres.
        /// Refreshed with the camera — see `headingProbe(for:)`.
        private var headingProbe: CLLocationDistance = 20_000

        /// Where the camera was standing when the sprites were last squared up.
        ///
        /// The bearing alone used to be enough, because the bearing was the
        /// only thing the old correction read. A measured angle depends on
        /// where the aircraft has ended up in the projection, so panning a
        /// globe changes it with the bearing never moving — hence all four
        /// figures.
        private var alignedCamera: MKMapCamera?

        init(_ parent: TrackerMapView) {
            self.parent = parent
        }

        // MARK: Style

        /// Which way round the cartography is drawn.
        ///
        /// This used to be done inline in `updateUIView`, *before* the style
        /// was applied, and only when `overrideUserInterfaceStyle` did not
        /// already read the value being set. Both halves of that were wrong,
        /// and together they are why picking a palette could leave the map
        /// exactly as it was.
        ///
        /// Assigning `preferredConfiguration` tears the map's renderer down and
        /// rebuilds it. Setting the scheme first and swapping the configuration
        /// immediately afterwards means the rebuild can come back carrying the
        /// trait the map had *before* the change — and because
        /// `overrideUserInterfaceStyle` reads back whatever it was assigned,
        /// whether or not the cartography ever acted on it, the "has it
        /// changed" guard then guaranteed nothing would ever tell it again. The
        /// map sat on the old cartography until something else happened to move
        /// the trait, which from the outside is a setting that does nothing.
        ///
        /// So: after the configuration rather than before, forced whenever the
        /// configuration was swapped, and asserted once more when the swap has
        /// actually landed.
        func applyScheme(_ scheme: ColorScheme, on mapView: MKMapView, force: Bool) {
            guard force || appliedScheme != scheme else { return }
            appliedScheme = scheme

            mapView.overrideUserInterfaceStyle = scheme == .light ? .light : .dark

            // A renderer resolves its dynamic stroke colour once and keeps the
            // resolved one, so the route drawn before the switch would stay the
            // old theme's until it was rebuilt. Asking each one to redraw is
            // cheaper than tearing the overlays down and re-adding them.
            for overlay in mapView.overlays {
                mapView.renderer(for: overlay)?.setNeedsDisplay()
            }
        }

        /// Applies a look to the map, and says whether it actually swapped the
        /// map's configuration — which is what the scheme above needs to know,
        /// because a swap is the thing that can lose it.
        @discardableResult
        func applyStyle(_ style: MapLook, on mapView: MKMapView) -> Bool {
            guard appliedStyle != style else { return false }
            let previous = appliedStyle
            appliedStyle = style

            // Where the camera was standing before the map underneath it was
            // swapped. Assigning `preferredConfiguration` tears the map down and
            // rebuilds it, and the camera does not reliably survive that: on the
            // globe it comes back somewhere flat and close in, which is why
            // recolouring the planet looked like it had flattened it.
            let before = mapView.camera
            let heldDistance = before.centerCoordinateDistance
            let heldPitch = before.pitch
            let heldHeading = before.heading
            // The *camera's* centre, not the map view's.
            //
            // `mapView.centerCoordinate` is derived from `region`, and MapKit
            // documents `region` as undefined whenever the map is not showing a
            // flat rectangular area — which is every globe, and anything
            // pitched. Reading it while the planet is on screen hands back a
            // coordinate for a rectangle that does not exist, and putting the
            // camera back at it is how a globe ends up somewhere else entirely.
            let heldCentre = before.centerCoordinate

            mapView.preferredConfiguration = style.configuration()
            mapView.isRotateEnabled = style.isFreeCamera
            // Pitch is the terrain's, not the globe's: elevation you cannot
            // lean over is elevation you cannot see. Rotation stays the globe's
            // alone — the flat map is north-up on purpose.
            mapView.isPitchEnabled = style.isPitchEnabled

            // The swap does not finish on the line that starts it. Whatever
            // scheme this pass settles on is put back once the rebuilt map has
            // landed, so the cartography cannot come back in the old one.
            let scheme = parent.colorScheme
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self = self, let mapView = mapView else { return }
                guard self.appliedStyle == style else { return }
                self.applyScheme(scheme, on: mapView, force: true)
            }

            syncDimming(style, on: mapView)

            let isNewProjection = previous?.projection != style.projection

            // Same shape of world, different paint. The camera should not have
            // moved at all, so it is put back exactly where it was rather than
            // left wherever the reload dropped it — and without animation,
            // because as far as anyone watching is concerned it never left.
            guard isNewProjection else {
                guard heldDistance.isFinite, heldDistance > 0 else { return true }

                let held = MKMapCamera(
                    lookingAtCenter: heldCentre,
                    fromDistance: heldDistance,
                    pitch: heldPitch,
                    heading: heldHeading
                )

                mapView.setCamera(held, animated: false)

                // ...and again once the swap has actually landed.
                //
                // Assigning `preferredConfiguration` does not finish on the
                // line that assigns it: the map tears its renderer down and
                // rebuilds it, and when that lands MapKit re-establishes a
                // camera of its own — over the top of the one restored above,
                // which is why restoring it synchronously was not enough. On
                // the globe what it re-establishes is close in and flat, so
                // recolouring the planet flattened it.
                //
                // Guarded on the style still being the one this call applied,
                // so a second change made in between wins rather than being
                // undone by the first one's echo.
                let applied = style
                DispatchQueue.main.async { [weak self, weak mapView] in
                    guard let self = self, let mapView = mapView else { return }
                    guard self.appliedStyle == applied else { return }
                    mapView.setCamera(held, animated: false)
                }
                return true
            }

            if style.isFreeCamera {
                // Only when the projection actually changes — which the guard
                // above has established — and never on a redraw, or the globe
                // would yank itself back out to arm's length each time a packet
                // landed. A stored globe gets this on launch too, which is
                // right: it is the whole reason the style was saved.
                if let distance = style.projection.openingDistance {
                    let camera = MKMapCamera(
                        lookingAtCenter: heldCentre,
                        fromDistance: distance,
                        pitch: 0,
                        heading: 0
                    )
                    mapView.setCamera(camera, animated: previous != nil)
                }
            } else {
                // Leaving the globe with the camera spun would leave every
                // sprite crooked on a map that can no longer be straightened,
                // so north-up is restored on the way out — from where the
                // camera was standing before the swap rather than from wherever
                // the reload left it. Built fresh rather than mutated:
                // `mapView.camera` hands back the map's own object, and editing
                // it in place is not how it is meant to be driven.
                if heldHeading != 0 || heldPitch != 0, heldDistance.isFinite, heldDistance > 0 {
                    let camera = MKMapCamera(
                        lookingAtCenter: heldCentre,
                        fromDistance: heldDistance,
                        pitch: 0,
                        heading: 0
                    )
                    mapView.setCamera(camera, animated: true)
                }
                realign(on: mapView, heading: 0)
            }

            return true
        }

        /// The black palette's wash, put on or taken off.
        ///
        /// Inserted at the bottom of its level rather than added to the top of
        /// it, so it dims the cartography and not the weather tiles, the night
        /// or the routes — all of which are added to the same level and would
        /// otherwise end up underneath it.
        private func syncDimming(_ style: MapLook, on mapView: MKMapView) {
            guard style.dimming > 0 else {
                if let overlay = dimmingOverlay {
                    mapView.removeOverlay(overlay)
                    dimmingOverlay = nil
                }
                return
            }

            guard let overlay = dimmingOverlay else {
                let overlay = MapDimming.overlay()
                dimmingOverlay = overlay
                mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
                return
            }

            // Already up, so this is a change of depth rather than of state —
            // which today only happens on the way in and out of black, but the
            // renderer repaints for it either way rather than holding whatever
            // it was built with.
            (mapView.renderer(for: overlay) as? MapDimming.Renderer)?.dimming = style.dimming
        }

        /// Whether the camera has moved enough since the last pass to be worth
        /// squaring the sprites up again.
        ///
        /// Not an optimisation for the gesture — through a drag this is true on
        /// every frame, which is the point — but for everything else that
        /// happens to land in the region callback without the view actually
        /// having moved.
        private func hasCameraMoved(on mapView: MKMapView) -> Bool {
            let camera = mapView.camera
            guard let last = alignedCamera else { return true }

            if abs(camera.heading - last.heading) > 0.5 { return true }
            if abs(camera.pitch - last.pitch) > 0.5 { return true }

            let centre = camera.centerCoordinate
            let was = last.centerCoordinate
            // In degrees, and deliberately crude: a tenth of a degree of pan is
            // several pixels of swing at the limb and nothing at all in the
            // middle, so the threshold is set by the worse of the two.
            if abs(centre.latitude - was.latitude) > 0.02 { return true }
            if abs(centre.longitude - was.longitude) > 0.02 { return true }

            let distance = camera.centerCoordinateDistance
            let held = last.centerCoordinateDistance
            guard held > 0 else { return true }
            return abs(distance - held) / held > 0.02
        }

        /// Re-applies every drawn sprite's angle for wherever the camera now
        /// stands.
        ///
        /// Cheap enough to run from the live gesture callback: it walks the
        /// annotations that currently have views — the ones on screen — and
        /// sets a transform on each. It used to be gated on the *bearing*
        /// having moved, which was right when the angle was derived from the
        /// bearing; it is gated on the camera having moved at all now, because
        /// a measured angle changes with a pan the bearing never notices.
        private func realign(on mapView: MKMapView, heading: CLLocationDirection) {
            appliedCameraHeading = heading
            headingProbe = Self.headingProbe(for: mapView)
            alignedCamera = mapView.camera

            for annotation in mapView.annotations {
                guard let view = mapView.view(for: annotation) else { continue }

                if let flight = annotation as? FlightAnnotation {
                    view.transform = rotation(
                        for: flight.flight.heading,
                        at: flight.coordinate,
                        on: mapView
                    )
                } else if let replay = annotation as? ReplayAnnotation {
                    view.transform = rotation(
                        for: replay.heading,
                        at: replay.coordinate,
                        on: mapView
                    )
                }
            }
        }

        /// A sprite's transform: which way the aeroplane is actually pointing
        /// on the screen you are looking at.
        ///
        /// ## Why this is not `heading - cameraHeading`
        ///
        /// That subtraction is exactly right on a flat north-up map, and it is
        /// right in the middle of a globe. It is wrong everywhere else on a
        /// globe, and increasingly wrong the further out you go, because it
        /// assumes north points the same way on screen wherever you are — and
        /// on a sphere it does not. Meridians converge. An aircraft out on the
        /// limb has its local north running across the screen at an angle the
        /// camera's bearing knows nothing about, so a sprite rotated by the
        /// camera's bearing sits crooked against the coastline underneath it.
        /// Which is the report this came from: aeroplanes on the edge of the
        /// planet not lying flat on it.
        ///
        /// So the angle is measured rather than derived. Project the aircraft's
        /// position, project a point a short way ahead of it along its true
        /// track, and take the angle between the two on screen. That is correct
        /// under any projection, any bearing and any tilt, for free, because it
        /// asks the thing that is actually doing the projecting.
        ///
        /// It falls back to the subtraction whenever the projection cannot
        /// answer — an aircraft round the back of the planet, a probe that
        /// lands on the same pixel — which is the old behaviour, and no worse
        /// than it ever was.
        private func rotation(
            for heading: Double,
            at coordinate: CLLocationCoordinate2D,
            on mapView: MKMapView
        ) -> CGAffineTransform {
            CGAffineTransform(
                rotationAngle: screenAngle(for: heading, at: coordinate, on: mapView)
            )
        }

        private func screenAngle(
            for heading: Double,
            at coordinate: CLLocationCoordinate2D,
            on mapView: MKMapView
        ) -> CGFloat {
            let derived = CGFloat(heading - appliedCameraHeading) * .pi / 180

            // The flat map is north-up and cannot tilt, so the derived angle is
            // the measured one and the projection would be pure cost — on every
            // aircraft on screen, on every frame of a pan.
            guard parent.style.usesScreenAngles else { return derived }
            guard CLLocationCoordinate2DIsValid(coordinate) else { return derived }

            let ahead = Self.coordinate(from: coordinate, bearing: heading, metres: headingProbe)
            guard CLLocationCoordinate2DIsValid(ahead) else { return derived }

            let origin = mapView.convert(coordinate, toPointTo: mapView)
            let tip = mapView.convert(ahead, toPointTo: mapView)

            let dx = tip.x - origin.x
            let dy = tip.y - origin.y
            guard dx.isFinite, dy.isFinite, hypot(dx, dy) >= 1 else { return derived }

            // `atan2` measures from the x axis and the artwork points north,
            // which on screen is up, which is negative y — so a quarter turn
            // puts zero where the sprite already is.
            return atan2(dy, dx) + .pi / 2
        }

        /// How far ahead of an aircraft to put the probe, in metres.
        ///
        /// Worked out once per pass from the camera's own distance rather than
        /// fixed, and that is the whole trick to making the measurement stable.
        /// Too short and the two projected points land on the same pixel at
        /// world zoom, so the angle is rounding noise; too long and the probe
        /// is a great-circle arc whose far end has swung away from the local
        /// tangent, so the angle is honest about somewhere the aeroplane is not.
        /// Two per cent of the camera distance lands the probe fifteen or
        /// twenty points from the aircraft at every zoom, which is far enough
        /// to be exact and near enough to be local.
        private static func headingProbe(for mapView: MKMapView) -> CLLocationDistance {
            let distance = mapView.camera.centerCoordinateDistance
            guard distance.isFinite, distance > 0 else { return 20_000 }
            return min(max(distance * 0.02, 1_000), 400_000)
        }

        /// The point a given distance from here along a given true bearing.
        ///
        /// The inverse of `FlightProgress.bearingDegrees`, and the only thing
        /// the probe needs.
        private static func coordinate(
            from origin: CLLocationCoordinate2D,
            bearing degrees: Double,
            metres: CLLocationDistance
        ) -> CLLocationCoordinate2D {
            let earthRadius = 6_371_000.0
            let angular = metres / earthRadius
            let bearing = degrees * .pi / 180
            let latitude = origin.latitude * .pi / 180
            let longitude = origin.longitude * .pi / 180

            let destinationLatitude = asin(
                sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(bearing)
            )
            let destinationLongitude = longitude + atan2(
                sin(bearing) * sin(angular) * cos(latitude),
                cos(angular) - sin(latitude) * sin(destinationLatitude)
            )

            return CLLocationCoordinate2D(
                latitude: destinationLatitude * 180 / .pi,
                longitude: (destinationLongitude * 180 / .pi).remainder(dividingBy: 360)
            )
        }

        /// Repaints every drawn sprite when the highlighting changes.
        ///
        /// One `Equatable` comparison guards the whole thing, so the common
        /// case — nothing changed, which is every packet — costs nothing.
        func applyHighlighting(_ highlighting: PilotHighlighting, on mapView: MKMapView) {
            guard appliedHighlighting != highlighting else { return }
            appliedHighlighting = highlighting

            for annotation in mapView.annotations {
                guard let flight = annotation as? FlightAnnotation,
                      let view = mapView.view(for: flight) else { continue }
                apply(
                    annotation: flight,
                    to: view,
                    selected: flight.flightId == parent.selection?.id,
                    on: mapView
                )
            }
        }

        // MARK: Airports

        /// What the drawn markers were last diffed against: the ranking, where
        /// the map is looking, and everything that decides how a marker is
        /// written. Nothing in that list changes on an ordinary redraw, and the
        /// diff below costs a string per marked field.
        private struct AirportSyncKey: Equatable {
            let revision: Int
            let latitude: Double
            let longitude: Double
            let latitudeSpan: Double
            let longitudeSpan: Double
            let conditions: Bool
            let weather: Int
            let windUnit: String
            let temperatureUnit: String
        }

        private var renderedAirportKey: AirportSyncKey?

        /// Adds, updates and removes the field markers.
        ///
        /// Culled to the viewport like the traffic is, and for the same reason:
        /// a busy server can have a hundred-odd fields worth marking, and the
        /// ones off screen cost layout for nothing. Unlike an aircraft there is
        /// no grace period — a field does not flicker in and out of a packet.
        func syncAirports(_ airports: [MapAirport], revision: Int, on mapView: MKMapView) {
            guard !airports.isEmpty else {
                if !airportAnnotations.isEmpty {
                    mapView.removeAnnotations(Array(airportAnnotations.values))
                    airportAnnotations.removeAll()
                    renderedCategories.removeAll()
                }
                renderedAirportKey = nil
                return
            }

            let region = mapView.region
            guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else { return }

            // Wind and temperature under the code, but only once the map is
            // near enough that a marker has room for a second line. Zoomed
            // out, every field on a continent carrying two lines is a wall of
            // text rather than a map.
            let conditions = parent.showsFieldConditions
                && region.span.latitudeDelta <= Self.fieldConditionSpanDegrees

            let preferences = WeatherPreferences.shared
            let key = AirportSyncKey(
                revision: revision,
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                latitudeSpan: region.span.latitudeDelta,
                longitudeSpan: region.span.longitudeDelta,
                conditions: conditions,
                // A report landing repaints one marker. The counter is how that
                // is noticed without asking the cache about every field on
                // every pass.
                weather: WeatherService.shared.generation,
                windUnit: preferences.windUnit.rawValue,
                temperatureUnit: preferences.temperatureUnit.rawValue
            )

            guard key != renderedAirportKey else { return }
            renderedAirportKey = key

            let latitudeMargin = region.span.latitudeDelta * AppConfig.flightAddMargin
            let longitudeMargin = region.span.longitudeDelta * AppConfig.flightAddMargin

            var wanted: [String: MapAirport] = [:]
            for field in airports {
                let coordinate = field.airport.coordinate
                guard abs(coordinate.latitude - region.center.latitude) <= latitudeMargin,
                      Self.longitudeDelta(coordinate.longitude, region.center.longitude) <= longitudeMargin
                else { continue }
                wanted[field.airport.icao] = field
            }

            var additions: [AirportAnnotation] = []

            // The reports behind the colours, for the fields being marked and
            // no others.
            WeatherService.shared.prefetch(Array(wanted.keys))

            // Everything but the category is the same for every marker on this
            // pass, so it is written once rather than per field.
            let suffix = "|\(conditions)|\(preferences.windUnit.rawValue)|\(preferences.temperatureUnit.rawValue)"

            for (icao, field) in wanted {
                let category = WeatherService.shared.cached(icao)?.flightCategory.rawValue ?? ""
                // The drawn state is more than the category: the same report is
                // written differently depending on whether there is room for
                // it, and on the units it is written in.
                let drawn = category + suffix

                if let existing = airportAnnotations[icao] {
                    let repaint = renderedCategories[icao] != drawn
                    guard existing.field != field || repaint else { continue }
                    existing.field = field
                    renderedCategories[icao] = drawn
                    if let view = mapView.view(for: existing) as? AirportAnnotationView {
                        view.apply(existing, conditions: conditions)
                    }
                } else {
                    renderedCategories[icao] = drawn
                    let annotation = AirportAnnotation(field: field)
                    airportAnnotations[icao] = annotation
                    additions.append(annotation)
                }
            }

            var removals: [AirportAnnotation] = []
            for (icao, annotation) in airportAnnotations where wanted[icao] == nil {
                removals.append(annotation)
                airportAnnotations.removeValue(forKey: icao)
                renderedCategories.removeValue(forKey: icao)
            }

            if !removals.isEmpty { mapView.removeAnnotations(removals) }
            if !additions.isEmpty { mapView.addAnnotations(additions) }
        }

        // MARK: Annotation syncing

        /// The revision the drawn traffic was last diffed against.
        private var syncedTrafficRevision: Int?

        /// The diff, but only when the traffic it would be diffing can have
        /// changed. Panning goes to `sync` directly — the viewport is not part
        /// of the revision, and re-culling for it is the one thing that has to
        /// happen without a new packet.
        func syncIfNeeded(flights: [Flight], revision: Int, on mapView: MKMapView) {
            guard syncedTrafficRevision != revision else { return }
            syncedTrafficRevision = revision
            sync(flights: flights, on: mapView)
        }

        func sync(flights: [Flight], on mapView: MKMapView) {
            let now = Date()
            let visible = cull(flights: flights, to: mapView)
            var seen = Set<String>()
            seen.reserveCapacity(visible.count)
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

            // Built on demand rather than up front. On a settled map every
            // annotation is in `seen` and this is never needed at all — and
            // building it means an array and a set of several thousand strings,
            // which was being thrown away unused on every pass.
            var reported: Set<String>?

            var removals: [FlightAnnotation] = []

            for (id, annotation) in annotations {
                guard id != selectedId, !seen.contains(id) else { continue }

                let ids = reported ?? Set(flights.lazy.map(\.id))
                reported = ids

                if !ids.contains(id),
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
            let selectedId = parent.selection?.id
            var selected: Flight?

            defer { selectedSnapshot = selected }

            let region = mapView.region
            guard region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite else {
                selected = selectedId.flatMap { id in flights.first { $0.id == id } }
                return flights
            }

            let center = region.center
            let addLatitude = region.span.latitudeDelta * AppConfig.flightAddMargin
            let addLongitude = region.span.longitudeDelta * AppConfig.flightAddMargin
            let keepLatitude = region.span.latitudeDelta * AppConfig.flightKeepMargin
            let keepLongitude = region.span.longitudeDelta * AppConfig.flightKeepMargin

            return flights.filter { flight in
                // Picked up in the pass that is already walking every aircraft,
                // so the route under the open window costs nothing to find.
                if flight.id == selectedId { selected = flight }

                let deltaLatitude = abs(flight.latitude - center.latitude)
                let deltaLongitude = Self.longitudeDelta(flight.longitude, center.longitude)

                // Already on the map, so it is held to the wider boundary.
                let isDrawn = annotations[flight.id] != nil

                return deltaLatitude <= (isDrawn ? keepLatitude : addLatitude)
                    && deltaLongitude <= (isDrawn ? keepLongitude : addLongitude)
            }
        }

        /// The open aircraft as it was in the packet the map was last diffed
        /// against. Selecting one changes the revision, so this is never behind
        /// the selection it belongs to.
        private var selectedSnapshot: Flight?

        /// Shortest angular distance between two longitudes, so traffic either
        /// side of the antimeridian isn't treated as half a world away.
        private static func longitudeDelta(_ lhs: Double, _ rhs: Double) -> Double {
            let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
            return delta > 180 ? 360 - delta : delta
        }

        private func refresh(annotation: FlightAnnotation, on mapView: MKMapView) {
            guard let view = mapView.view(for: annotation) else { return }
            apply(
                annotation: annotation,
                to: view,
                selected: annotation.flightId == parent.selection?.id,
                on: mapView
            )
        }

        private func apply(
            annotation: FlightAnnotation,
            to view: MKAnnotationView,
            selected: Bool,
            on mapView: MKMapView
        ) {
            let key = annotation.flight.spriteKey
            view.image = PlaneSprites.shared.icon(
                forKey: key,
                selected: selected,
                tint: appliedHighlighting.tint(for: annotation.flight.username)
            )
            view.transform = rotation(
                for: annotation.flight.heading,
                at: annotation.coordinate,
                on: mapView
            )

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

        /// The open aircraft, without walking the server for it.
        ///
        /// The snapshot the last diff took is the same object the linear search
        /// would find; the search is kept as the answer for the one pass where
        /// a selection has been made and no diff has run yet.
        private func selectedFlight() -> Flight? {
            guard let id = parent.selection?.id else { return nil }
            if let snapshot = selectedSnapshot, snapshot.id == id { return snapshot }
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

            // Asked for here as well as by the window, and asked for first:
            // this runs on the map's very next pass after the aeroplane is
            // tapped, which is before the sheet has finished coming up. The
            // window's own request is the one that used to start the clock, and
            // half a second of sheet animation is half a second of a path that
            // could already have been on its way.
            //
            // Once per flight, tracked here rather than in the service, because
            // a history that comes back empty — a flight that has only just
            // pushed back — leaves `hasHistory` false forever, and a condition
            // that stays true on a method called every layout pass is a request
            // storm.
            if !FlightTrailStore.shared.hasHistory(for: flight.id),
               requestedHistory.insert(flight.id).inserted {
                // Nothing worth remembering about the ones before: this exists
                // to stop a repeat, and an id that has not been asked for in a
                // hundred aircraft is not about to be asked for twice.
                if requestedHistory.count > 200 { requestedHistory = [flight.id] }

                FlightHistoryService.shared.load(flightId: flight.id) { history in
                    FlightTrailStore.shared.seed(history, for: flight.id)
                }
            }

            let trail = FlightTrailStore.shared.points(for: flight.id)

            // Read before the key is built, because asking is also what starts
            // the fetch. Empty on the first pass for every flight, and empty
            // forever for the many pilots who file nothing.
            let plan = parent.showsFlightPlan
                ? FlightPlanStore.shared.waypoints(for: flight.id)
                : []
            let key = [
                flight.id,
                String(trail.count),
                // In the key as well as on the view, which looks redundant and
                // is not: the seed is the reason this pass is running at all,
                // and a count that happened to come back the same — a history
                // exactly as long as the fragment it replaced — would otherwise
                // leave the old fragment drawn.
                String(parent.trailRevision),
                // The band the aircraft is in, so a climb through a boundary
                // redraws the path. The trail thins its own samples and stops
                // growing at all once it is full, so counting points alone
                // leaves the colours frozen partway up.
                String(AltitudeBand.band(forFeet: flight.altitudeFeet)),
                flight.departureIcao ?? "",
                flight.arrivalIcao ?? "",
                // The plan arrives well after the first draw — it is fetched
                // when first asked for — so its arrival has to be able to
                // invalidate the key, or the route is drawn once without it and
                // never again.
                parent.showsFlightPlan ? String(plan.count) : "off"
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

            // One line, coloured by height along its whole length. See
            // `FlownPath`: it used to be one polyline per run of samples
            // sharing a band, which stepped the colour six times through a
            // climb and stacked a round cap on every boundary.
            flownRamp = FlownPath(
                points: flown,
                bands: Self.heightBands(of: flown),
                title: Self.flownTitle,
                glowTitle: Self.flownGlowTitle
            )
            if let path = flownRamp {
                // The halo first. Overlays draw in the order they are added
                // within a level, so this is what puts it underneath.
                routeOverlays.append(path.glow)
                routeOverlays.append(path.line)
            }

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

            // MARK: The filed plan
            //
            // Drawn under everything else it shares the screen with: it is what
            // the pilot *intends*, where the coloured track behind them is what
            // they have actually done, and the two should not compete. The
            // fixes are labelled because a line through unnamed corners is a
            // shape rather than a route — the names are the whole reason for
            // plotting the plan instead of just its ends.
            if plan.count >= 2 {
                let line = MKGeodesicPolyline(
                    coordinates: plan.map(\.coordinate),
                    count: plan.count
                )
                line.title = Self.planTitle
                routeOverlays.append(line)
            }

            if !routeOverlays.isEmpty {
                mapView.addOverlays(routeOverlays, level: .aboveRoads)
            }

            if !planLabels.isEmpty {
                mapView.removeAnnotations(planLabels)
                planLabels.removeAll(keepingCapacity: true)
            }
            if !plan.isEmpty {
                planLabels = plan.map { PlanWaypointAnnotation(waypoint: $0) }
                mapView.addAnnotations(planLabels)
            }
        }

        private func dashed(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> MKPolyline {
            let line = MKGeodesicPolyline(coordinates: [from, to], count: 2)
            line.title = Self.plannedTitle
            return line
        }

        /// How far a path can run at exactly zero feet before the zero is read
        /// as missing rather than as low.
        ///
        /// A flight from a sea-level field reports tens of feet, not a clean
        /// zero, and an aircraft that never leaves the apron does not travel
        /// twenty miles. A run that does both is a height the backend did not
        /// send.
        private static let unknownHeightRunNM: Double = 20

        /// The band each sample belongs in, or nil where its height is missing
        /// rather than low.
        ///
        /// Judged per run rather than over the whole path: a track seeded from
        /// the backend without heights, with the live position on the end of
        /// it, is the ordinary case — and it should draw as an unknown path
        /// that becomes a coloured one, not as a flight that spent three hours
        /// on the deck.
        private static func heightBands(of points: [TrackPoint]) -> [Int?] {
            var bands: [Int?] = points.map { AltitudeBand.band(forFeet: $0.altitudeFeet) }

            var start = 0
            while start < points.count {
                guard points[start].altitudeFeet == 0 else {
                    start += 1
                    continue
                }

                var end = start
                while end + 1 < points.count, points[end + 1].altitudeFeet == 0 { end += 1 }

                let spanNM = FlightProgress.distanceNM(
                    from: points[start].coordinate,
                    to: points[end].coordinate
                )
                if spanNM > unknownHeightRunNM {
                    for index in start...end { bands[index] = nil }
                }

                start = end + 1
            }

            return bands
        }

        private func clearRoute(on mapView: MKMapView) {
            if !planLabels.isEmpty {
                mapView.removeAnnotations(planLabels)
                planLabels.removeAll(keepingCapacity: true)
            }

            guard !routeOverlays.isEmpty else {
                renderedRouteKey = nil
                return
            }
            mapView.removeOverlays(routeOverlays)
            routeOverlays.removeAll(keepingCapacity: true)
            flownRamp = nil
            renderedRouteKey = nil
        }

        // MARK: Weather

        /// The tiles currently on the map, by the frame they are of, so a
        /// frame that has not changed is not torn down and re-fetched.
        private var weatherOverlay: RainViewerTileOverlay?

        /// What was last said about the tiles being worth drawing at this zoom,
        /// so the model hears about a change rather than about every pass.
        private var reportedWeatherLegibility = true

        /// The barbs on the map, and the grid they belong to.
        private var windAnnotations: [WindBarbAnnotation] = []
        private var renderedWindKey: String?

        /// Swaps the weather tiles when the frame changes, and takes them away
        /// when the layer goes off.
        ///
        /// One overlay at a time. Cross-fading two frames would look better and
        /// would mean holding two full tile sets for a layer that is already
        /// the most expensive thing on the map.
        func syncWeatherTiles(on mapView: MKMapView) {
            // Zoomed in past where the tiles hold any detail, the overlay comes
            // off rather than being magnified into a smear. The map is the only
            // thing that knows how wide the view is, so it decides — and tells
            // the model, which is what puts the reason in the strip.
            let span = mapView.region.span.longitudeDelta
            let legible = parent.weatherTiles
                .map { MapWeatherSource.isLegible($0.layer, acrossDegrees: span) } ?? true

            if legible != reportedWeatherLegibility {
                reportedWeatherLegibility = legible
                parent.onWeatherLegibility(legible)
            }

            let wanted = legible ? parent.weatherTiles : nil

            if weatherOverlay?.key == wanted?.key { return }

            if let existing = weatherOverlay {
                mapView.removeOverlay(existing)
                weatherOverlay = nil
            }

            guard let wanted = wanted else { return }

            let overlay = RainViewerTileOverlay(tiles: wanted)
            weatherOverlay = overlay
            // Below the roads and the labels: this is weather over the ground,
            // and a place name you cannot read through it is a map that has
            // stopped being a map.
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        /// Keeps the wind barbs matched to where the map is looking.
        ///
        /// The store does the deciding — which lattice this region rounds to,
        /// whether that grid is already held, whether it is worth asking at
        /// this zoom at all. This only draws whatever it currently holds.
        /// Where the map was, and which level was wanted, the last time the
        /// grid was asked for.
        private var windRequest: (latitude: Double, longitude: Double, span: Double, level: String)?
        private var windRequestedAt = Date.distantPast

        /// How often the grid is re-asked for over a map that is sitting still.
        /// The store answers from its cache until the model data is stale; this
        /// is only about noticing that it has gone stale.
        private static let windRefreshInterval: TimeInterval = 20

        func syncWinds(on mapView: MKMapView) {
            guard parent.showsWinds else {
                if !windAnnotations.isEmpty {
                    mapView.removeAnnotations(windAnnotations)
                    windAnnotations.removeAll(keepingCapacity: true)
                }
                renderedWindKey = nil
                windRequest = nil
                WindsAloftStore.shared.clear()
                return
            }

            let store = WindsAloftStore.shared

            // Working out which lattice this region rounds to builds the whole
            // grid of points and formats its identity, which is a good deal of
            // work to do on every redraw to arrive at the same answer as last
            // time. The map moving is what changes that answer — plus the clock,
            // so that a still map still notices stale model data.
            let region = mapView.region
            let here = (
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                span: region.span.latitudeDelta,
                level: parent.windLevel.rawValue
            )
            let now = Date()
            if windRequest == nil
                || windRequest! != here
                || now.timeIntervalSince(windRequestedAt) >= Self.windRefreshInterval {
                windRequest = here
                windRequestedAt = now
                store.load(region: region, level: parent.windLevel)
            }

            guard renderedWindKey != store.key else { return }
            renderedWindKey = store.key

            if !windAnnotations.isEmpty {
                mapView.removeAnnotations(windAnnotations)
                windAnnotations.removeAll(keepingCapacity: true)
            }

            guard !store.barbs.isEmpty else { return }
            windAnnotations = store.barbs.map { WindBarbAnnotation(barb: $0) }
            mapView.addAnnotations(windAnnotations)
        }

        // MARK: The ruler

        private var measureOverlay: MKPolyline?
        private var measurePins: [MeasurePoint] = []
        private var renderedMeasureKey: String?

        /// Where the tap landed, as a place on the earth.
        @objc func handleMeasureTap(_ recogniser: UITapGestureRecognizer) {
            guard parent.measurement.isOn else { return }
            guard let mapView = recogniser.view as? MKMapView else { return }

            let point = recogniser.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }

            parent.measurement.add(coordinate)
        }

        /// Lets the map keep its own gestures, and keeps aeroplanes tappable.
        ///
        /// Without the second half of this, dropping a measuring point on top
        /// of an aircraft would also open that aircraft's window — two things
        /// happening for one tap, neither of them cancellable.
        func gestureRecognizer(
            _ recogniser: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard parent.measurement.isOn else { return false }

            var view = touch.view
            while let candidate = view {
                if candidate is MKAnnotationView { return false }
                view = candidate.superview
            }
            return true
        }

        func gestureRecognizer(
            _ recogniser: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func syncMeasurement(on mapView: MKMapView) {
            let measurement = parent.measurement
            let key = measurement.isOn
                ? [measurement.start, measurement.end]
                    .map { $0.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "-" }
                    .joined(separator: "|")
                : "off"

            guard renderedMeasureKey != key else { return }
            renderedMeasureKey = key

            if let existing = measureOverlay {
                mapView.removeOverlay(existing)
                measureOverlay = nil
            }
            if !measurePins.isEmpty {
                mapView.removeAnnotations(measurePins)
                measurePins.removeAll(keepingCapacity: true)
            }

            guard measurement.isOn else { return }

            if let start = measurement.start {
                measurePins.append(MeasurePoint(coordinate: start, letter: "A"))
            }
            if let end = measurement.end {
                measurePins.append(MeasurePoint(coordinate: end, letter: "B"))
            }
            if !measurePins.isEmpty { mapView.addAnnotations(measurePins) }

            guard let start = measurement.start, let end = measurement.end else { return }

            // Geodesic, because the number in the readout is a great-circle
            // distance and a straight line would be measuring something else.
            let line = MKGeodesicPolyline(coordinates: [start, end], count: 2)
            line.title = MeasureStyle.title
            measureOverlay = line
            mapView.addOverlay(line, level: .aboveLabels)
        }

        // MARK: Night

        private var terminatorOverlays: [MKPolygon] = []

        /// When the drawn terminator was worked out, so it is rebuilt on its
        /// own slow clock rather than on every pass.
        private var terminatorDrawnAt: Date?

        /// How stale the shape may get. The terminator sweeps a quarter of a
        /// degree a minute, so two minutes is half a degree — a fifth of the
        /// width of one band of the fade, and invisible at any zoom that shows
        /// a whole continent.
        private static let terminatorLifetime: TimeInterval = 120

        func syncTerminator(on mapView: MKMapView) {
            guard parent.showsTerminator else {
                clearTerminator(on: mapView)
                return
            }

            if let drawn = terminatorDrawnAt,
               Date().timeIntervalSince(drawn) < Self.terminatorLifetime {
                return
            }

            clearTerminator(on: mapView)
            terminatorDrawnAt = Date()
            terminatorOverlays = Terminator.polygons()
            guard !terminatorOverlays.isEmpty else { return }

            // Below everything: this is a wash over the ground, and every other
            // thing the map draws has to stay readable through it.
            mapView.addOverlays(terminatorOverlays, level: .aboveRoads)
        }

        private func clearTerminator(on mapView: MKMapView) {
            guard terminatorDrawnAt != nil else { return }
            mapView.removeOverlays(terminatorOverlays)
            terminatorOverlays.removeAll(keepingCapacity: true)
            terminatorDrawnAt = nil
        }

        // MARK: The organised tracks

        private var natOverlays: [MKPolyline] = []
        private var natLabels: [MKAnnotation] = []

        /// What is drawn, so a set that has not been republished is not torn
        /// down and rebuilt on every packet.
        private var renderedNatKey: String?

        /// Draws the North Atlantic track system.
        ///
        /// Whole-world rather than culled to the viewport: there are a dozen
        /// tracks, they are one polyline each, and the alternative — rebuilding
        /// them on every pan — costs more than simply leaving them on the map.
        func syncNatTracks(on mapView: MKMapView) {
            guard parent.showsNatTracks else {
                clearNatTracks(on: mapView)
                return
            }

            let service = NatTrackService.shared
            service.refresh()

            let tracks = service.tracks
            let key = tracks.map { "\($0.name)|\($0.coordinates.count)" }.joined(separator: ",")
            guard renderedNatKey != key else { return }

            clearNatTracks(on: mapView)
            renderedNatKey = key
            guard !tracks.isEmpty else { return }

            for track in tracks {
                // Geodesic, because a track is flown as a great circle and a
                // straight line between two North Atlantic fixes is visibly
                // south of where the aeroplanes actually are.
                let line = MKGeodesicPolyline(
                    coordinates: track.coordinates,
                    count: track.coordinates.count
                )
                line.title = NatTrackStyle.title(for: track)
                natOverlays.append(line)

                // Named at both ends, because which end you are looking at
                // depends entirely on which side of the ocean you are.
                let text = NatTrackStyle.label(for: track)
                if let first = track.coordinates.first {
                    natLabels.append(GroundLabel(coordinate: first, text: text))
                }
                if let last = track.coordinates.last, track.coordinates.count > 1 {
                    natLabels.append(GroundLabel(coordinate: last, text: text))
                }
            }

            // Under the traffic, like everything else that is context.
            mapView.addOverlays(natOverlays, level: .aboveRoads)
            mapView.addAnnotations(natLabels)
        }

        private func clearNatTracks(on mapView: MKMapView) {
            guard renderedNatKey != nil else { return }
            mapView.removeOverlays(natOverlays)
            mapView.removeAnnotations(natLabels)
            natOverlays.removeAll(keepingCapacity: true)
            natLabels.removeAll(keepingCapacity: true)
            renderedNatKey = nil
        }

        // MARK: Ground layout

        /// How wide the view has to be, in nautical miles, before a field's
        /// pavement is worth drawing.
        ///
        /// About the width of a large airport plus its approach. Wider than
        /// that and runways are hairlines that clutter the map; closer in they
        /// are the map.
        private static let groundSpanNM: Double = 9

        /// Where the map was the last time the ground layer was worked out.
        private var groundRegion: (latitude: Double, longitude: Double, span: Double)?

        /// How wide the view may be, in degrees of latitude, before a field's
        /// conditions stop being drawn under its code. About four hundred
        /// miles — a country rather than a continent.
        static let fieldConditionSpanDegrees: Double = 6

        /// Draws the pavement of whichever field the map is sitting over.
        ///
        /// Runways, taxiways, aprons and terminals from OpenStreetMap, with
        /// the runway designators — which is the part neither Apple's basemap
        /// nor imagery gives you.
        ///
        /// Resolving which field the map is over is a walk over every airport
        /// in the dataset on a cache miss, so it is done when the map moves and
        /// skipped on the redraws where it hasn't.
        func syncGround(on mapView: MKMapView) {
            guard parent.showsGroundLayout else {
                clearGround(on: mapView)
                groundRegion = nil
                return
            }

            let region = mapView.region
            guard region.span.latitudeDelta.isFinite else { return }

            let here = (
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                span: region.span.latitudeDelta
            )
            // Only once something is actually drawn for this spot. Until then
            // the pavement may still be arriving from the network, and the
            // redraw it lands on is what puts it on the map.
            if let last = groundRegion, last == here, renderedGroundIcao != nil { return }
            groundRegion = here

            // Degrees of latitude are nautical miles times sixty, everywhere.
            let spanNM = region.span.latitudeDelta * 60
            guard spanNM <= Self.groundSpanNM else {
                clearGround(on: mapView)
                return
            }

            guard let field = AirportStore.shared.nearestAirport(
                to: region.center,
                withinNM: Self.groundSpanNM
            ) else {
                clearGround(on: mapView)
                return
            }

            let store = AirportLayoutStore.shared
            store.load(field)

            guard let layout = store.layout(for: field.icao), !layout.isEmpty else { return }
            guard renderedGroundIcao != layout.icao else { return }

            clearGround(on: mapView)
            renderedGroundIcao = layout.icao

            // Aprons first, runways last, so the pieces stack the way the
            // concrete does.
            for kind in AirportLayout.drawingOrder {
                for piece in layout.pieces where piece.kind == kind {
                    groundOverlays.append(Self.overlay(for: piece))
                }
            }

            for runway in layout.runways {
                guard let ref = runway.ref, let centre = Self.midpoint(of: runway.coordinates) else { continue }
                groundLabels.append(GroundLabel(coordinate: centre, text: ref))
            }

            // Under the traffic and under the flown path: this is the ground
            // the aircraft are on, not something to read over them.
            //
            // Which means inserting rather than adding. Overlays draw in the
            // order they sit in their level, and `addOverlays` puts them on
            // top of it — so the pavement landed over the track that had been
            // added before it, and a taxi out was a coloured line disappearing
            // under every stand and apron it crossed. These go in at the
            // bottom of the level instead, in the order the concrete stacks,
            // and everything laid over them — the plan, the track, the night —
            // stays laid over them.
            let base = Self.bottomOfRoadsLevel(on: mapView)
            for (offset, overlay) in groundOverlays.enumerated() {
                mapView.insertOverlay(overlay, at: base + offset, level: .aboveRoads)
            }
            mapView.addAnnotations(groundLabels)
        }

        /// The first slot in `.aboveRoads` that anything but the dimming wash
        /// may occupy.
        ///
        /// The wash is inserted at zero precisely so it sits under the whole
        /// level and darkens the cartography rather than the things drawn on
        /// it; sliding the pavement in beneath it would put the airport under
        /// the dimmer and back at basemap brightness. Read off the map rather
        /// than assumed to be one, so the answer stays right whether the wash
        /// is up or not.
        private static func bottomOfRoadsLevel(on mapView: MKMapView) -> Int {
            let overlays = mapView.overlays(in: .aboveRoads)
            return overlays.firstIndex { !($0 is MapDimming.Overlay) } ?? overlays.count
        }

        private func clearGround(on mapView: MKMapView) {
            guard renderedGroundIcao != nil else { return }
            mapView.removeOverlays(groundOverlays)
            mapView.removeAnnotations(groundLabels)
            groundOverlays.removeAll(keepingCapacity: true)
            groundLabels.removeAll(keepingCapacity: true)
            renderedGroundIcao = nil
        }

        private static func overlay(for piece: AirportLayout.Piece) -> MKOverlay {
            let coordinates = piece.coordinates
            if piece.kind.isArea {
                let polygon = MKPolygon(coordinates: coordinates, count: coordinates.count)
                polygon.title = "\(groundTitle):\(piece.kind.rawValue)"
                return polygon
            }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            line.title = "\(groundTitle):\(piece.kind.rawValue)"
            return line
        }

        /// The point halfway *along* the way rather than the average of its
        /// nodes: a runway mapped with a cluster of nodes at one end would
        /// otherwise carry its label off-centre.
        private static func midpoint(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
            guard coordinates.count >= 2 else { return coordinates.first }

            var lengths: [Double] = []
            var total = 0.0
            for index in 1..<coordinates.count {
                let step = FlightProgress.distanceNM(from: coordinates[index - 1], to: coordinates[index])
                total += step
                lengths.append(total)
            }
            guard total > 0 else { return coordinates.first }

            let half = total / 2
            for (index, run) in lengths.enumerated() where run >= half {
                let previous = index == 0 ? 0 : lengths[index - 1]
                let segment = run - previous
                let fraction = segment > 0 ? (half - previous) / segment : 0
                let from = coordinates[index]
                let to = coordinates[index + 1]
                return CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction
                )
            }
            return coordinates.last
        }

        static let groundTitle = "ground"

        /// Marks the filed plan, so the renderer can draw it as intention
        /// rather than as track.
        static let planTitle = "plan"

        static let flownTitle = "flown"
        static let flownGlowTitle = "flown.glow"
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
                    apply(replay: existing, to: view, on: mapView)
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

        private func apply(
            replay annotation: ReplayAnnotation,
            to view: MKAnnotationView,
            on mapView: MKMapView
        ) {
            view.image = PlaneSprites.shared.icon(forKey: annotation.spriteKey, selected: true)
            view.transform = rotation(
                for: annotation.heading,
                at: annotation.coordinate,
                on: mapView
            )
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
            UIEdgeInsets(
                top: 96,
                left: 44,
                bottom: parent.bottomInset + 28,
                right: 44 + parent.trailingInset
            )
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                // Enough to read the weather, not so much that the coastline
                // under it disappears. Radar is the denser image of the two, so
                // it is the one drawn back further.
                renderer.alpha = parent.weatherTiles?.layer == .satellite ? 0.62 : 0.55
                return renderer
            }

            if overlay is MapDimming.Overlay {
                return MapDimming.Renderer(overlay: overlay, dimming: parent.style.dimming)
            }

            if let area = overlay as? MKPolygon {
                if Terminator.isBand(area.title) {
                    let renderer = MKPolygonRenderer(polygon: area)
                    renderer.fillColor = Terminator.fill(for: area.title)
                    // No outline at all. The whole point of the stack of bands
                    // is a soft edge, and a stroke would put the hard line back.
                    renderer.strokeColor = .clear
                    renderer.lineWidth = 0
                    return renderer
                }

                return Self.groundRenderer(for: area, title: area.title)
            }

            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            if line.title?.hasPrefix(Self.groundTitle) == true {
                return Self.groundRenderer(for: line, title: line.title)
            }

            if line.title == MeasureStyle.title {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = MeasureStyle.line
                renderer.lineWidth = 2.4
                renderer.lineCap = .round
                renderer.lineDashPattern = [6, 5]
                return renderer
            }

            if let track = NatTrackStyle.name(fromTitle: line.title) {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                renderer.strokeColor = NatTrackStyle.colour(for: track).withAlphaComponent(0.75)
                renderer.lineWidth = 2.6
                return renderer
            }

            if line.title == Self.flownGlowTitle {
                return flownRenderer(for: line, glowing: true)
            }

            if line.title == Self.flownTitle {
                return flownRenderer(for: line, glowing: false)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            if line.title == Self.planTitle {
                // The route as filed: solid but faint, and thin. It is a
                // statement of intent sitting underneath a track that actually
                // happened, and it should read as the quieter of the two. The
                // colour is shared with the fixes drawn along it, so the line
                // and the diamonds on it are visibly one route.
                renderer.strokeColor = PlanStyle.line
                renderer.lineWidth = 1.8
                return renderer
            }

            if line.title == Self.plannedTitle {
                // Inferred, so it reads as an assumption rather than as track.
                renderer.strokeColor = UIColor { traits in
                    traits.userInterfaceStyle == .light
                        ? UIColor(white: 0.20, alpha: 0.34)
                        : UIColor(white: 1, alpha: 0.34)
                }
                renderer.lineWidth = 2
                renderer.lineDashPattern = [2, 7]
            }

            return renderer
        }

        /// The flown track: one line, one ramp, one cap at each end.
        ///
        /// The stops come off `flownRamp` rather than off the overlay, which
        /// carries only a title. A path on the map without a ramp behind it is
        /// a path whose heights were all unknown, or one left over from a
        /// route that has since been rebuilt — grey either way, which is what
        /// an unreadable title has always fallen back to.
        private func flownRenderer(for line: MKPolyline, glowing: Bool) -> MKOverlayRenderer {
            let renderer = MKGradientPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.lineWidth = glowing ? flownWidth * FlownPathStyle.glowSpread : flownWidth

            let ramp = flownRamp
            let matches = ramp.map { glowing ? $0.glow === line : $0.line === line } ?? false

            if let ramp = ramp, matches, ramp.colors.count >= 2 {
                renderer.setColors(
                    glowing ? ramp.glowColors : ramp.colors,
                    locations: ramp.locations
                )
            } else {
                let fallback = glowing
                    ? AltitudeBand.unknownColor.withAlphaComponent(FlownPathStyle.glowOpacity)
                    : AltitudeBand.unknownColor
                renderer.setColors([fallback, fallback], locations: [0, 1])
            }

            return renderer
        }

        /// Re-widths the flown path for wherever the camera now stands.
        ///
        /// Run from the live region callback, and it has to be cheap enough
        /// for that: one camera read and one comparison in the ordinary case,
        /// where the change since the last frame rounds to nothing. Only the
        /// width is touched — the ramp and the geometry are untouched, so this
        /// is a repaint rather than a rebuild.
        private func updateFlownWidth(on mapView: MKMapView) {
            let width = FlownPathStyle.width(
                forCameraDistance: mapView.camera.centerCoordinateDistance
            )
            guard abs(width - flownWidth) > 0.05 else { return }
            flownWidth = width

            guard let path = flownRamp else { return }

            for (overlay, drawn) in [
                (path.glow, width * FlownPathStyle.glowSpread),
                (path.line, width)
            ] {
                guard let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer else {
                    continue
                }
                renderer.lineWidth = drawn
                renderer.setNeedsDisplay()
            }
        }

        /// Pavement, drawn like a chart rather than like a photograph.
        ///
        /// Widths are in points and so do not grow with the zoom: a runway
        /// drawn to scale is a hairline from the edge of the field and a slab
        /// from the threshold, and the point of this layer is to be readable
        /// at both. Everything is translucent enough to sit over imagery
        /// without hiding the concrete underneath it.
        private static func groundRenderer(for overlay: MKOverlay, title: String?) -> MKOverlayRenderer {
            let kind = title?.split(separator: ":").last.map(String.init)

            if let area = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: area)
                let isTerminal = kind == AirportLayout.Piece.Kind.terminal.rawValue
                renderer.fillColor = UIColor { traits in
                    let alpha = isTerminal ? 0.20 : 0.12
                    return traits.userInterfaceStyle == .light
                        ? UIColor(white: 0.25, alpha: alpha)
                        : UIColor(white: 0.95, alpha: alpha)
                }
                renderer.strokeColor = .clear
                renderer.lineWidth = 0
                return renderer
            }

            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .butt
            renderer.lineJoin = .round

            let isRunway = kind == AirportLayout.Piece.Kind.runway.rawValue
            renderer.lineWidth = isRunway ? 7 : 2.5
            renderer.strokeColor = UIColor { traits in
                let alpha = isRunway ? 0.72 : 0.42
                return traits.userInterfaceStyle == .light
                    ? UIColor(white: 0.18, alpha: alpha)
                    : UIColor(white: 0.92, alpha: alpha)
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let point = annotation as? MeasurePoint {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MeasurePointView.reuseIdentifier,
                    for: annotation
                )
                (view as? MeasurePointView)?.apply(point)
                return view
            }

            if let barb = annotation as? WindBarbAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: WindBarbView.reuseIdentifier,
                    for: annotation
                )
                (view as? WindBarbView)?.apply(barb)
                return view
            }

            if let waypoint = annotation as? PlanWaypointAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PlanWaypointView.reuseIdentifier,
                    for: annotation
                )
                (view as? PlanWaypointView)?.apply(waypoint)
                return view
            }

            if let label = annotation as? GroundLabel {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: GroundLabelView.reuseIdentifier,
                    for: label
                )
                (view as? GroundLabelView)?.apply(label)
                return view
            }

            if let field = annotation as? AirportAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: AirportAnnotationView.reuseIdentifier,
                    for: field
                )
                // Same test the diff above uses, because a marker added
                // mid-pan has to arrive drawn the way its neighbours already
                // are.
                let conditions = parent.showsFieldConditions
                    && mapView.region.span.latitudeDelta <= Self.fieldConditionSpanDegrees
                (view as? AirportAnnotationView)?.apply(field, conditions: conditions)
                return view
            }

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

                apply(replay: replay, to: view, on: mapView)
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
                selected: flightAnnotation.flightId == parent.selection?.id,
                on: mapView
            )

            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let field = view.annotation as? AirportAnnotation {
                // Deselected immediately: a field opens a panel and is not a
                // selection the map holds, so leaving it selected would leave a
                // marker stuck in a highlighted state behind the sheet.
                mapView.deselectAnnotation(field, animated: false)
                parent.onSelectAirport(field.icao)
                return
            }

            guard let annotation = view.annotation as? FlightAnnotation else { return }

            apply(annotation: annotation, to: view, selected: true, on: mapView)

            isApplyingSelection = true
            parent.selection = SelectedFlight(id: annotation.flightId)
            isApplyingSelection = false
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation as? FlightAnnotation else { return }

            apply(annotation: annotation, to: view, selected: false, on: mapView)

            guard parent.selection?.id == annotation.flightId else { return }

            isApplyingSelection = true
            parent.selection = nil
            isApplyingSelection = false
        }

        /// Fires continuously through a drag, a pinch or a twist, which is the
        /// point: waiting for the gesture to end meant aircraft arrived in a
        /// batch once the map settled, and a pan into empty sky stayed empty
        /// until you let go.
        ///
        /// Two jobs, on two different clocks, which is why they share one
        /// callback rather than being throttled together. Straightening the
        /// sprites has to keep up with the finger or the aircraft visibly lag
        /// behind a spinning globe, and it is gated on the bearing having
        /// actually moved — on a north-up map it costs one comparison. Re-culling
        /// walks every aircraft on the server, so it stays on its own throttle.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // How wide the track is drawn follows how far back the camera is
            // standing, so it belongs on the frame clock rather than on the
            // settle: a pinch that ended two hundred milliseconds ago is a
            // pinch you watched the line fatten through.
            updateFlownWidth(on: mapView)

            // Straightening the sprites. On a north-up flat map there is
            // nothing to straighten — the camera cannot spin or tilt, so a
            // heading is its own angle on screen — and the gate keeps that
            // case at one comparison.
            //
            // Everywhere else it runs on every frame of the gesture rather
            // than only when the bearing moves, and that is the globe fix: a
            // sprite's angle on screen is not `heading - cameraHeading` except
            // in the middle of the view. Spinning the planet is not the only
            // thing that changes it — panning an aircraft out towards the limb
            // does too, with the camera's bearing never moving at all.
            if parent.style.usesScreenAngles, hasCameraMoved(on: mapView) {
                realign(on: mapView, heading: mapView.camera.heading)
            }

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
                self.syncGround(on: mapView)
                // The wind grid is a function of the region, so it is resolved
                // on the same settle the ground layer is — never mid-pan.
                self.syncWinds(on: mapView)
                // And whether the weather tiles still hold detail at this zoom,
                // which is the same question asked of a different layer. On the
                // settle rather than mid-pinch: a zoom that passes through the
                // limit and back out should not flick the overlay off and on.
                self.syncWeatherTiles(on: mapView)
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
