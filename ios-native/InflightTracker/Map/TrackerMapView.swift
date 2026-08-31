import MapKit
import QuartzCore
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

    /// Whether airborne traffic is carried between packets rather than jumping
    /// on each one. See `FlightMotion`.
    ///
    /// Passed in rather than read from the setting here, because the setting is
    /// not the only thing that can turn it off: Reduce Motion does too, and the
    /// map has no business knowing about either. It is told.
    var smoothsTraffic = true

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

    /// Whether the open aircraft gets a straight line to its destination,
    /// travelling with it. Mutually exclusive with the filed plan above — see
    /// `RouteLineMode` for why the two are a choice rather than two switches.
    var showsDirectLine = false

    /// Whether the open aircraft's flown track is drawn. See
    /// `MapFilters.showsFlownPath` — the dashed leg back to the departure
    /// field goes with it, since that leg is an inference about the same
    /// flown path rather than a separate thing.
    var showsFlownPath = true

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

        // The clock the traffic flies on. Nothing to do with the feed, which
        // arrives when it arrives; this is the screen's own tick, and on a
        // frame where nothing is being smoothed it costs one comparison.
        context.coordinator.startFlying(on: mapView)

        return mapView
    }

    /// SwiftUI is finished with the map. The display link holds the coordinator,
    /// and a display link that is never invalidated is a retain cycle that goes
    /// on ticking after the view it draws into is gone.
    static func dismantleUIView(_ mapView: ChromeInsetMapView, coordinator: Coordinator) {
        coordinator.stopFlying()
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
        ///
        /// `MKOverlay` rather than `MKPolyline` since the flown track stopped
        /// being one: it is drawn by hand now and arrives as its own overlay,
        /// alongside the dashed legs and the filed plan, which are still lines.
        private var renderedRouteKey: String?
        private var routeOverlays: [MKOverlay] = []

        /// Flights whose backend history this map has asked for, and when.
        ///
        /// A set of ids was not enough, and the failure was the quiet kind. The
        /// trail store drops the trail of any aircraft missing from a packet —
        /// right, since trails are the expensive part — and the feed does blink:
        /// one short packet or a reconnect and a nine-hour flight's seeded
        /// history is gone. With an id already in the set the map would never
        /// ask again, so the path silently collapsed to the fragment recorded
        /// since the blink and stayed that way for as long as the window was
        /// open. A date lets the request come back, while still holding off the
        /// storm the set existed to prevent: a flight that has only just pushed
        /// back has an empty history, `hasHistory` stays false for it forever,
        /// and this method runs on every layout pass.
        private var requestedHistory: [String: Date] = [:]

        /// How long a history request holds the door shut behind it.
        private static let historyRetryInterval: TimeInterval = 45

        /// How close to a field a slow sample has to be for that field's
        /// pavement to be worth fetching, so the flown path can be matched to
        /// it.
        ///
        /// Wider than an aerodrome and narrower than a circuit: an aircraft
        /// four miles out at taxi speed is a light aeroplane on final, not
        /// something on a taxiway, and asking OpenStreetMap about every field a
        /// slow flight passes would be a request per airport in the county.
        private static let taxiFieldRadiusNM: Double = 4

        /// The flown path currently on the map.
        ///
        /// One overlay now, carrying its own points and their colours — the
        /// renderer needs nothing looked up on the side. It used to be a pair,
        /// a halo polyline and a line polyline, with the colour ramp held here
        /// because `MKPolyline` can carry nothing but a title.
        private var flownOverlay: FlownPathOverlay?

        /// How wide that path is drawn, in points.
        ///
        /// Narrower the further back the camera stands. See `FlownPathStyle`:
        /// a fixed width is a line zoomed in and a filled shape zoomed out.
        private var flownWidth: CGFloat = FlownPathStyle.closeWidth

        /// The fix names on the open flight's filed plan. Kept separately from
        /// `groundLabels` so that turning the plan off, or opening another
        /// aircraft, does not take an airport's runway designators with it.
        private var planLabels: [MKAnnotation] = []

        /// The line from the open aircraft to where it is going, and what it
        /// was drawn from.
        ///
        /// Held apart from `routeOverlays` deliberately, and that separation is
        /// the whole fix. Everything in that array is rebuilt together, when
        /// the route key changes — and the key is a statement about the *shape*
        /// of the route: how many breadcrumbs, which airports, how long the
        /// plan is. An aeroplane flying along its route changes none of that.
        ///
        /// So this line, which starts at the aeroplane, used to be pinned to
        /// wherever it happened to be standing at the last rebuild and stay
        /// there — while the aircraft flew out from under it. The trail store
        /// thins its own samples and stops growing once it is full, so on a
        /// long flight the count stopped changing too and the line stopped
        /// moving altogether, leaving an aeroplane trailing a line anchored an
        /// ocean behind it.
        ///
        /// Updated on the frame clock instead, from the position the aircraft
        /// is *drawn* at, so the two travel together.
        private var directOverlay: MKPolyline?
        private var directOrigin: MKMapPoint?
        private var directDestination: CLLocationCoordinate2D?
        private var directDrawnAt: CFTimeInterval = 0

        /// How far the aeroplane has to have moved, on screen, before the line
        /// ahead of it is worth redrawing. Under a point is a move nobody can
        /// see; standing far enough back, a whole leg is under a point.
        private static let directStep: Double = 1

        /// And how often that redraw may happen at most.
        ///
        /// The step alone is not a bound: zoomed in on an aircraft on final,
        /// a point of movement is a fraction of a second, and this is the one
        /// overlay whose bounding rect can be a continent wide. Twelve a second
        /// is past what reads as continuous for a line with one end nailed
        /// down, and it is a ceiling the cruise never comes near.
        private static let directInterval: CFTimeInterval = 1.0 / 12

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
        ///
        /// Held as figures rather than as the `MKMapCamera` they were read
        /// from, and that is the whole of it: `MKMapCamera` is a class, and
        /// `mapView.camera` hands back the map's own object rather than a
        /// snapshot of it — which this file already says out loud, a few
        /// hundred lines up, where it refuses to mutate one in place. Keeping
        /// the object here meant keeping a reference to the live camera, so
        /// every figure `hasCameraMoved` compared was being compared against
        /// itself. It never once said yes. The sprites were squared up on the
        /// first pass and never again, which is why spinning the planet took
        /// every aeroplane on it round too.
        private struct CameraStand {
            var heading: CLLocationDirection
            var pitch: CGFloat
            var latitude: CLLocationDegrees
            var longitude: CLLocationDegrees
            var distance: CLLocationDistance

            init(_ camera: MKMapCamera) {
                heading = camera.heading
                pitch = camera.pitch
                latitude = camera.centerCoordinate.latitude
                longitude = camera.centerCoordinate.longitude
                distance = camera.centerCoordinateDistance
            }
        }

        private var alignedCamera: CameraStand?

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

            // The pavement's areas hold their fill rather than reading it, so
            // a repaint is not enough for them. Light to dark is exactly the
            // switch this is for.
            refreshGroundLook(on: mapView)
        }

        /// Applies a look to the map, and says whether it actually swapped the
        /// map's configuration — which is what the scheme above needs to know,
        /// because a swap is the thing that can lose it.
        @discardableResult
        func applyStyle(_ style: MapLook, on mapView: MKMapView) -> Bool {
            guard appliedStyle != style else { return false }
            let previous = appliedStyle
            appliedStyle = style

            // Pavement is coloured against the ground under it, and the ground
            // has just changed. Cartography to imagery is the case that matters:
            // the concrete is in the photograph now, so the layer stops painting
            // it and starts outlining it instead.
            defer { refreshGroundLook(on: mapView) }

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
            let camera = CameraStand(mapView.camera)
            guard let last = alignedCamera else { return true }

            if abs(camera.heading - last.heading) > 0.5 { return true }
            if abs(camera.pitch - last.pitch) > 0.5 { return true }

            // In degrees, and deliberately crude: a tenth of a degree of pan is
            // several pixels of swing at the limb and nothing at all in the
            // middle, so the threshold is set by the worse of the two.
            if abs(camera.latitude - last.latitude) > 0.02 { return true }
            if abs(camera.longitude - last.longitude) > 0.02 { return true }

            guard last.distance > 0 else { return true }
            return abs(camera.distance - last.distance) / last.distance > 0.02
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
            alignedCamera = CameraStand(mapView.camera)

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
        ///
        /// ## Why an angle is not enough either
        ///
        /// Turning the sprite the right way round is only half of lying flat on
        /// something. The other half is foreshortening, and a rotation has none
        /// in it: whatever the angle, the sprite is still drawn at full size and
        /// perfectly square. In the middle of the view that is correct, because
        /// there the ground is square-on to the camera. Out at the limb it is
        /// not — the surface there is turning away almost edge-on, a circle
        /// painted on it projects to a thin ellipse, and a sprite that stays a
        /// full-size square on top of that reads as a cardboard cut-out
        /// standing up and facing you rather than as an aeroplane lying on the
        /// planet.
        ///
        /// So measure the whole local frame rather than one direction of it.
        /// Two probes — one along the aircraft's track, one ninety degrees off
        /// it — give the two vectors the ground's own axes project to, and
        /// those two vectors *are* the transform. Near the middle they come out
        /// the same length and the result is exactly the rotation this used to
        /// return; out at the limb the one pointing at the horizon collapses
        /// and the sprite lies down with the surface.
        ///
        /// Which axis to keep at full size is not a choice: the one along the
        /// limb is not foreshortened at all, so both are divided by the longer
        /// of the two. That leaves scale alone everywhere it should be left
        /// alone, and takes it out of the one direction that has genuinely got
        /// shorter.
        private func rotation(
            for heading: Double,
            at coordinate: CLLocationCoordinate2D,
            on mapView: MKMapView
        ) -> CGAffineTransform {
            // Worked out only where it is wanted. This runs on every drawn
            // aircraft on every frame of a spin, and the measured angle costs a
            // probe and two projections of its own — so the frame below, which
            // already carries the rotation inside it, never pays for one.
            func turned() -> CGAffineTransform {
                CGAffineTransform(
                    rotationAngle: screenAngle(for: heading, at: coordinate, on: mapView)
                )
            }

            guard parent.style.usesScreenAngles else { return turned() }
            guard CLLocationCoordinate2DIsValid(coordinate) else { return turned() }

            let ahead = GreatCircle.coordinate(from: coordinate, bearing: heading, metres: headingProbe)
            let beside = GreatCircle.coordinate(from: coordinate, bearing: heading + 90, metres: headingProbe)
            guard CLLocationCoordinate2DIsValid(ahead), CLLocationCoordinate2DIsValid(beside) else {
                return turned()
            }

            let origin = mapView.convert(coordinate, toPointTo: mapView)
            let tip = mapView.convert(ahead, toPointTo: mapView)
            let side = mapView.convert(beside, toPointTo: mapView)

            let forward = CGPoint(x: tip.x - origin.x, y: tip.y - origin.y)
            let right = CGPoint(x: side.x - origin.x, y: side.y - origin.y)
            guard forward.x.isFinite, forward.y.isFinite, right.x.isFinite, right.y.isFinite else {
                return turned()
            }

            let along = hypot(forward.x, forward.y)
            let across = hypot(right.x, right.y)
            let longer = max(along, across)
            // Both probes landing within a pixel is a projection with nothing
            // to say — the same condition the angle falls back on.
            guard longer >= 1 else { return turned() }

            // The far side of the planet, where east and north come out mirrored
            // and the frame would flip the sprite. MapKit usually culls these
            // before they are drawn; this is what happens when it does not.
            let winding = right.x * forward.y - right.y * forward.x
            guard winding < 0 else { return turned() }

            let axes = [forward, right].map { axis -> CGPoint in
                let scaled = CGPoint(x: axis.x / longer, y: axis.y / longer)
                let length = hypot(scaled.x, scaled.y)
                // Floored, because a sprite is a thing that has to be seen and
                // pressed. Taken to its honest limit an aeroplane on the very
                // edge is a line a fraction of a pixel across, which is
                // realistic and useless.
                guard length > 0.0001, length < Self.minimumFlatten else { return scaled }
                let lift = Self.minimumFlatten / length
                return CGPoint(x: scaled.x * lift, y: scaled.y * lift)
            }

            // The artwork points north, which on screen is up, which is
            // negative y — so the sprite's own up axis is what maps onto the
            // track, and its right axis onto the ground's right.
            return CGAffineTransform(
                a: axes[1].x, b: axes[1].y,
                c: -axes[0].x, d: -axes[0].y,
                tx: 0, ty: 0
            )
        }

        /// How flat a sprite is allowed to get before it stops flattening.
        ///
        /// At the limb the true figure goes to nothing, and a sprite drawn to
        /// it would be invisible and impossible to press. Two fifths is squashed
        /// hard enough to read as lying on a surface turning away, and still
        /// leaves an aeroplane there to tap.
        private static let minimumFlatten: CGFloat = 0.4

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

            let ahead = GreatCircle.coordinate(from: coordinate, bearing: heading, metres: headingProbe)
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
            // The other clock: the one the smoothing runs on, which is the
            // screen's rather than the wall's. Taken once for the whole packet
            // rather than once per aircraft.
            let frameNow = CACurrentMediaTime()
            let visible = cull(flights: flights, to: mapView)
            var seen = Set<String>()
            seen.reserveCapacity(visible.count)
            var additions: [FlightAnnotation] = []

            for flight in visible {
                seen.insert(flight.id)
                lastSeen[flight.id] = now

                if let existing = annotations[flight.id] {
                    if existing.update(with: flight, now: frameNow) {
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

        /// The rotation alone.
        ///
        /// A smoothed heading moves continuously, so an aircraft in a turn
        /// crosses the half-degree that counts as a change on most frames of
        /// it. `refresh` would reassign the sprite each time — the same image,
        /// looked up and set again, and a redraw of the view around it — for a
        /// picture that has not changed. The transform is the whole of what a
        /// frame of a turn actually needs.
        private func turn(annotation: FlightAnnotation, on mapView: MKMapView) {
            guard let view = mapView.view(for: annotation) else { return }
            view.transform = rotation(
                for: annotation.drawnHeading,
                at: annotation.coordinate,
                on: mapView
            )
            annotation.renderedHeading = annotation.drawnHeading
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
                for: annotation.drawnHeading,
                at: annotation.coordinate,
                on: mapView
            )

            annotation.renderedSpriteKey = key
            annotation.renderedHeading = annotation.drawnHeading
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
            // Rate-limited here rather than in the service, because a history
            // that comes back empty — a flight that has only just pushed back —
            // leaves `hasHistory` false forever, and a condition that stays
            // true on a method called every layout pass is a request storm.
            // Rate-limited rather than once-only: see `requestedHistory`.
            let now = Date()
            if !FlightTrailStore.shared.hasHistory(for: flight.id),
               now.timeIntervalSince(requestedHistory[flight.id] ?? .distantPast)
                   > Self.historyRetryInterval {
                requestedHistory[flight.id] = now

                // Nothing worth remembering about the ones before: this exists
                // to stop a repeat, and an id that has not been asked for in a
                // hundred aircraft is not about to be asked for twice.
                if requestedHistory.count > 200 { requestedHistory = [flight.id: now] }

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

            // The pavement the ground part of this track will be laid on, where
            // the track has a ground part at all. Asked for on the same terms
            // as the plan and the history: asking is what starts the fetch, and
            // the answer is nothing until it lands.
            let taxiways = groundNetworks(for: flight, along: trail)
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
                parent.showsFlightPlan ? String(plan.count) : "off",
                // The layer switch is in the key for the same reason the plan's
                // count is: turning it off has to be able to invalidate a route
                // that is already drawn.
                parent.showsFlownPath ? "path" : "nopath",
                // And the pavement, for the third time the same reason: a
                // field's taxiways are fetched from OpenStreetMap when the
                // track first turns out to need them, which is well after the
                // path has been drawn once without them.
                taxiways.map { "\($0.icao)/\($0.edgeCount)" }.joined(separator: "+")
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

            flownOverlay = nil

            if parent.showsFlownPath {
                // On the ground, the track goes the way the concrete goes.
                //
                // Every sample near a taxiway is put on it, and the line
                // between two of them is the route along the pavement rather
                // than the chord across it — which is what a taxi thinned to
                // two breadcrumbs used to be drawn as. Segments with no
                // pavement under them, and the whole airborne length of every
                // flight, come back untouched: the fallback is per segment.
                let drawn = GroundTrack.following(flown, on: taxiways)

                // One overlay, coloured by height along its whole length,
                // drawing its own halo underneath itself. See `FlownPath` for
                // what this replaced and why none of it survived.
                let path = FlownPath(
                    points: drawn,
                    bands: Self.heightBands(of: drawn),
                    title: Self.flownTitle
                )
                flownOverlay = path?.overlay
                if let overlay = path?.overlay {
                    routeOverlays.append(overlay)
                }

                // Before we were watching: departure to the first point we have.
                if let departure = AirportStore.shared.airport(flight.departureIcao),
                   let first = flown.first,
                   FlightProgress.distanceNM(from: departure.coordinate, to: first.coordinate) > 1 {
                    routeOverlays.append(dashed(from: departure.coordinate, to: first.coordinate))
                }
            }

            // What is still to come is not drawn here. It starts at the
            // aeroplane, and the aeroplane moves between rebuilds of this
            // array — see `directOverlay`, which follows it on the frame clock.

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

            // Guarded by its own step, so this is a comparison on every pass
            // that is not the first one.
            syncDirectLine(on: mapView, pointsPerMetre: Self.pointsPerMetre(on: mapView))
        }

        /// Draws the line from the open aircraft to its destination, and keeps
        /// it under the aeroplane as it flies.
        ///
        /// `MKPolyline` cannot be moved — its points are fixed at construction
        /// — so following the aircraft means replacing the overlay, which is
        /// why this is fenced by both a distance and a rate. Neither fence is
        /// theoretical: in the cruise the distance is what bites, redrawing
        /// about once a second, and the rate is there for the other end of it —
        /// an aeroplane on short final under a close camera, crossing a point
        /// of screen every few frames.
        private func syncDirectLine(on mapView: MKMapView, pointsPerMetre: Double) {
            guard parent.showsDirectLine else {
                clearDirectLine(on: mapView)
                return
            }

            // The rate gate is asked first because it is the cheapest question
            // here and it puts a ceiling on all the rest: with a line already
            // drawn, everything below this runs twelve times a second rather
            // than thirty. What it can cost is a twelfth of a second's delay
            // clearing a line whose flight has just been closed, which is not
            // a thing anybody can see.
            let now = CACurrentMediaTime()
            if directOverlay != nil, now - directDrawnAt < Self.directInterval { return }

            // Stamped here rather than where the line is drawn, because this is
            // the moment being rationed: an aeroplane sitting still fails the
            // distance test below on every look, and without a stamp it would
            // be looked at on every frame for as long as it sat there.
            directDrawnAt = now

            guard let flight = selectedFlight(),
                  let arrival = AirportStore.shared.airport(flight.arrivalIcao)
            else {
                clearDirectLine(on: mapView)
                return
            }

            // Where it is being *drawn*, not where its last packet put it. The
            // sprite is carried between packets, and a line that starts at the
            // reported position would come adrift from the aeroplane it is
            // supposed to be attached to for most of every interval.
            let origin = drawnCoordinate(for: flight)
            let destination = arrival.coordinate
            let point = MKMapPoint(origin)

            if let existing = directOverlay,
               let anchor = directOrigin,
               let previous = directDestination,
               previous.latitude == destination.latitude,
               previous.longitude == destination.longitude {

                // A scale of zero is a map with no size yet — nothing to
                // measure the move against, so leave the line where it is.
                guard pointsPerMetre > 0 else { return }
                guard anchor.distance(to: point) * pointsPerMetre >= Self.directStep else {
                    return
                }

                mapView.removeOverlay(existing)
            } else if let existing = directOverlay {
                // A different destination — the pilot amended it, or another
                // aeroplane was opened. Nothing of the old line survives.
                mapView.removeOverlay(existing)
            }

            let line = dashed(from: origin, to: destination)
            mapView.addOverlay(line, level: .aboveRoads)

            directOverlay = line
            directOrigin = point
            directDestination = destination
        }

        private func clearDirectLine(on mapView: MKMapView) {
            guard let existing = directOverlay else { return }
            mapView.removeOverlay(existing)
            directOverlay = nil
            directOrigin = nil
            directDestination = nil
        }

        /// The fields whose taxiways this track needs, and their graphs.
        ///
        /// Two questions, and the order matters. First, does this track have a
        /// ground part at a field at all — a sample slow enough and close
        /// enough to be taxiing rather than overflying? Only then is the
        /// field's pavement asked for, because asking is a request to
        /// OpenStreetMap and the answer is cached for a month; a flight that is
        /// enroute for eleven hours should not be fetching aerodromes it passes
        /// over.
        ///
        /// Both ends of the route and both ends of the track, because a flight
        /// window is opened at every stage of a trip: the departure it pushed
        /// back from is where the history begins, the arrival is where it is
        /// taxiing in now, and a track that starts mid-flight has neither of
        /// them filed.
        private func groundNetworks(for flight: Flight, along trail: [TrackPoint]) -> [TaxiNetwork] {
            guard parent.showsFlownPath else { return [] }

            // The whole test, up front and in one cheap pass: a track with
            // nothing slow in it has no ground part, which is every flight in
            // the cruise and so almost every flight on the map. Everything
            // below only ever runs for the handful of samples that are left.
            let slow = trail.filter { $0.groundSpeedKnots <= GroundTrack.taxiSpeedCeiling }
            guard !slow.isEmpty else { return [] }

            let store = AirportStore.shared
            var fields: [Airport] = []

            func consider(_ airport: Airport?) {
                guard let airport = airport, !fields.contains(where: { $0.icao == airport.icao }) else {
                    return
                }
                let taxiing = slow.contains { point in
                    FlightProgress.distanceNM(from: point.coordinate, to: airport.coordinate)
                        <= Self.taxiFieldRadiusNM
                }
                guard taxiing else { return }
                fields.append(airport)
            }

            consider(store.airport(flight.departureIcao))
            consider(store.airport(flight.arrivalIcao))
            if let first = slow.first {
                consider(store.nearestAirport(to: first.coordinate, withinNM: Self.taxiFieldRadiusNM))
            }
            if let last = slow.last {
                consider(store.nearestAirport(to: last.coordinate, withinNM: Self.taxiFieldRadiusNM))
            }

            guard !fields.isEmpty else { return [] }

            let layouts = AirportLayoutStore.shared
            var networks: [TaxiNetwork] = []
            for field in fields {
                // Asked for off the layout pass rather than inside it.
                //
                // `load` moves the field to `.loading`, and that is a published
                // change — made, if it were called from here, while the view
                // observing the store is in the middle of updating, which is
                // the warning SwiftUI exists to give. Nothing is lost by the
                // hop: the answer is a network round trip away either way, and
                // its arrival is what redraws the path.
                if case .idle = layouts.state(for: field.icao) {
                    DispatchQueue.main.async { layouts.load(field) }
                }

                guard let layout = layouts.layout(for: field.icao), !layout.isEmpty else { continue }
                guard let network = TaxiNetworkStore.shared.network(
                    for: layout,
                    centre: field.coordinate
                ) else { continue }
                networks.append(network)
            }
            return networks
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
            clearDirectLine(on: mapView)

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
            flownOverlay = nil
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
                groundLabels.append(GroundLabel(coordinate: centre, text: ref, kind: .runway))
            }

            // And the alphabet between them, which is the thing a ground chart
            // is *for* and which this layer has been downloading and throwing
            // away since it was written: `ref` is parsed off every taxiway and
            // only the runways were ever labelled.
            //
            // One per way rather than one per name, which is what puts the
            // letter along the taxiway rather than once in the middle of it —
            // OSM splits a taxiway at every junction, so the ways *are* roughly
            // the intervals a chart repeats the letter at. Short stubs are
            // skipped: a ten-metre link between two stands is not a piece of
            // taxiway anybody navigates by, and labelling it only crowds out
            // the letter on the run it joins.
            var lettered = 0
            for taxiway in layout.taxiways {
                guard lettered < Self.maximumTaxiwayLabels else { break }
                guard let ref = taxiway.ref,
                      let centre = Self.midpoint(of: taxiway.coordinates),
                      Self.length(of: taxiway.coordinates) >= Self.shortestLetteredTaxiway
                else { continue }

                groundLabels.append(GroundLabel(coordinate: centre, text: ref, kind: .taxiway))
                lettered += 1
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
            // A run of pavement carries its own kind and its own real width —
            // see `GroundOverlay`. The title is kept for the areas, which are
            // still polygons and still say what they are that way.
            if let pavement = GroundOverlay(piece: piece) { return pavement }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            line.title = "\(groundTitle):\(piece.kind.rawValue)"
            return line
        }

        /// The point halfway *along* the way rather than the average of its
        /// How short a taxiway can be and still be worth a letter, in nautical
        /// miles. About a hundred metres.
        ///
        /// Below this it is a link between two stands or a corner OSM happened
        /// to split, not a run anybody taxis along, and its letter would only
        /// collide with the one on the taxiway it joins.
        private static let shortestLetteredTaxiway: Double = 0.054

        /// And how many letters a field gets at most.
        ///
        /// A guard rather than a target: the collision rules already thin these
        /// on screen, and the busiest fields in the world do not come near it.
        /// It is here so that a mis-tagged import cannot put four thousand
        /// annotations on the map.
        private static let maximumTaxiwayLabels = 240

        /// How long a run of pavement is, in nautical miles.
        private static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
            guard coordinates.count >= 2 else { return 0 }
            var total = 0.0
            for index in 1..<coordinates.count {
                total += FlightProgress.distanceNM(
                    from: coordinates[index - 1],
                    to: coordinates[index]
                )
            }
            return total
        }

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

            // Once, and then not again for a moment.
            //
            // This is called on every frame now rather than on every packet,
            // because the aircraft it follows moves on every frame. A pan is an
            // animated camera move of its own, though, and one issued thirty
            // times a second is thirty animations each cancelling the last —
            // the camera would crawl, and would go on crawling for as long as
            // the aeroplane stayed outside the middle. So a move is allowed to
            // finish before another is considered.
            let now = CACurrentMediaTime()
            guard now - lastFollowMove > Self.followCooldown else { return }

            if keepInView(drawnCoordinate(for: flight), on: mapView) {
                lastFollowMove = now
            }
        }

        private var lastFollowMove: CFTimeInterval = 0

        /// Long enough for an animated camera move to land, and short enough
        /// that an aeroplane leaving the middle of the map is brought back
        /// before it reaches the edge of it.
        private static let followCooldown: CFTimeInterval = 0.9

        /// Pans to bring a moving aircraft back, but only once it has left the
        /// middle of the map. Re-centring on every frame would take the map
        /// away from wherever the user had just dragged it.
        ///
        /// Measured against the part of the map that is actually *visible* —
        /// the bounds less the info window and the chrome — rather than against
        /// the whole map rect. The middle half of the whole rect includes a
        /// good deal of what the sheet is sitting on, so an aircraft could be
        /// comfortably "in view" and completely hidden behind the window it was
        /// being followed from.
        @discardableResult
        private func keepInView(
            _ coordinate: CLLocationCoordinate2D,
            on mapView: MKMapView
        ) -> Bool {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return false }

            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }

            let clear = bounds.inset(by: edgeInsets(in: bounds))
            guard clear.width > 1, clear.height > 1 else {
                return pan(to: coordinate, on: mapView)
            }

            // The middle half of what is not covered. Inside it, the aircraft
            // is comfortably on screen and the map is left alone.
            let comfortable = clear.insetBy(dx: clear.width * 0.25, dy: clear.height * 0.25)

            let here = mapView.convert(coordinate, toPointTo: mapView)
            guard here.x.isFinite, here.y.isFinite else { return false }
            guard !comfortable.contains(here) else { return false }

            return pan(to: coordinate, on: mapView)
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

        // MARK: Flying

        /// The map this coordinator draws into, for the one caller that does
        /// not have it handed to it: the display link, which is woken by the
        /// screen rather than by SwiftUI.
        private weak var flyingMapView: MKMapView?

        private var flightLink: CADisplayLink?
        private var lastFlightTick: CFTimeInterval = 0

        /// How many aircraft the last frame was actually carrying.
        ///
        /// The switch being off is not on its own a reason to skip the frame —
        /// the aeroplanes that were flying a moment ago have to be put back
        /// where they were reported. It is a reason to skip every frame after
        /// that one, which on a map of two thousand annotations is the
        /// difference between a feature somebody turned off and a loop they are
        /// still paying for.
        private var flyingCount = 0

        /// Slower than the screen, on purpose.
        ///
        /// Thirty is past the rate at which a sprite crossing the map at a
        /// point a second reads as continuous, and half the work of a hundred
        /// and twenty. Nothing here is under a finger, so there is nothing to
        /// be gained from matching a ProMotion panel and a good deal of battery
        /// to be lost.
        private static let flightFrameRate: Float = 30

        /// Below this an aircraft's own progress is under a fifth of a point a
        /// second — a movement nobody can see, on a map standing far enough
        /// back that a whole airline is a handful of pixels. Those are left
        /// exactly where their packets put them, which is both correct and
        /// free.
        private static let visibleMotion: Double = 0.2

        func startFlying(on mapView: MKMapView) {
            flyingMapView = mapView
            guard flightLink == nil else { return }

            let link = CADisplayLink(target: self, selector: #selector(flyOneFrame))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 15,
                maximum: Self.flightFrameRate,
                preferred: Self.flightFrameRate
            )
            // Common, so the traffic keeps flying while a sheet is being
            // dragged over the top of it — the default mode is suspended for
            // the length of a tracking loop, and a map that freezes whenever
            // somebody touches the window in front of it is the jank with an
            // extra step.
            link.add(to: .main, forMode: .common)
            flightLink = link
        }

        func stopFlying() {
            flightLink?.invalidate()
            flightLink = nil
            flyingMapView = nil
        }

        @objc private func flyOneFrame(_ link: CADisplayLink) {
            let now = link.timestamp
            let elapsed = now - lastFlightTick
            lastFlightTick = now

            guard let mapView = flyingMapView, mapView.window != nil else { return }

            let scale = Self.pointsPerMetre(on: mapView)
            guard scale > 0 else { return }

            // Before the smoothing gate rather than after it. The track's head
            // follows wherever the open aircraft is *drawn*, which is a
            // question with an answer whether the aeroplane is being carried
            // between packets or is sitting exactly where its last one put it —
            // and with the switch off, the second is the only case there is.
            updateFlownHead(on: mapView, pointsPerMetre: scale)

            // For the same reason and on the same terms: the line ahead of the
            // aeroplane starts where the aeroplane is drawn, which is a
            // question with a new answer on every frame it is being carried on.
            syncDirectLine(on: mapView, pointsPerMetre: scale)

            let smoothing = parent.smoothsTraffic
            guard smoothing || flyingCount > 0 else { return }
            guard !annotations.isEmpty else { return }

            // A frame, rather than a resume: coming back from the background
            // hands us however long the app was away, and the whole fleet
            // integrating that in one step is the teleport this exists to
            // prevent. The aircraft are put back on their reported positions
            // and start again from there.
            guard elapsed > 0, elapsed < 1 else {
                for (_, annotation) in annotations { annotation.endMotion() }
                flyingCount = 0
                return
            }

            var flying = 0

            for (_, annotation) in annotations {
                // Three questions, cheapest first: is the feature on, is this
                // aeroplane flying, and would any of it be visible at this
                // zoom. Only the last changes as the map moves, which is why it
                // is asked every frame rather than once when the packet landed.
                let wanted = smoothing
                    && annotation.flight.isWorthSmoothing
                    && annotation.drawnPointsPerSecond(pointsPerMetre: scale) >= Self.visibleMotion

                if wanted != annotation.isSmoothing {
                    if wanted {
                        annotation.beginMotion(now: now)
                    } else {
                        annotation.endMotion()
                    }
                }

                guard annotation.isSmoothing else { continue }
                flying += 1

                if annotation.advanceMotion(to: now, pointsPerMetre: scale) {
                    turn(annotation: annotation, on: mapView)
                }
            }

            flyingCount = flying

            // The camera goes with them. Follow acts on the position being
            // drawn rather than the one last reported, or the aeroplane it is
            // following would be the one thing on the map it never quite
            // catches up with.
            followSelection(on: mapView)
        }

        /// The map's scale, as points per metre.
        ///
        /// Measured across the middle of the view rather than taken from the
        /// region's span, which is a rectangle in degrees and says nothing
        /// useful about a globe that may be spun, tilted, or standing over a
        /// pole.
        private static func pointsPerMetre(on mapView: MKMapView) -> Double {
            let bounds = mapView.bounds
            guard bounds.width > 120, bounds.height > 1 else { return 0 }

            let left = mapView.convert(
                CGPoint(x: bounds.midX - 50, y: bounds.midY),
                toCoordinateFrom: mapView
            )
            let right = mapView.convert(
                CGPoint(x: bounds.midX + 50, y: bounds.midY),
                toCoordinateFrom: mapView
            )
            guard CLLocationCoordinate2DIsValid(left), CLLocationCoordinate2DIsValid(right) else {
                return 0
            }

            let metres = MKMapPoint(left).distance(to: MKMapPoint(right))
            guard metres.isFinite, metres > 0 else { return 0 }

            return 100 / metres
        }

        /// Grows the flown path to wherever the open aircraft is drawn.
        ///
        /// The track ends at the newest breadcrumb the store holds, and
        /// breadcrumbs are thinned by distance — two nautical miles apart at
        /// best. So the aeroplane spends most of its time flying off the end of
        /// its own path, with the line catching up in one jump each time a
        /// sample lands. Here the last segment is redrawn on the frame clock
        /// instead, to the same position the aircraft itself is being moved to,
        /// so the two travel together.
        ///
        /// Cheap by construction, and it has to be at thirty frames a second:
        /// the geometry is untouched, only one point moves, and the repaint is
        /// scoped to the strip that point moved through rather than to the few
        /// thousand that have not.
        private func updateFlownHead(on mapView: MKMapView, pointsPerMetre: Double) {
            guard let overlay = flownOverlay else { return }

            guard let id = parent.selection?.id,
                  let annotation = annotations[id] else {
                retreatFlownHead(of: overlay, on: mapView)
                return
            }

            let point = MKMapPoint(annotation.coordinate)

            // Outside the room the overlay reserved, which means the aeroplane
            // has flown further since the last rebuild than the path was built
            // to allow for. Drawn, it would be cut off at the edge of the rect
            // MapKit is willing to ask about; the honest answer is to stop
            // extending and wait for the rebuild the next breadcrumb brings.
            guard overlay.canReach(point) else {
                retreatFlownHead(of: overlay, on: mapView)
                return
            }

            let existing = overlay.head
            let previous = existing ?? overlay.tail

            // Under a fifth of a point is a move nobody can see, and a repaint
            // for it is a tile rasterised for nothing. The first head is worth
            // one at any distance: without it there is a gap rather than a
            // slightly stale line.
            let moved = previous.distance(to: point) * pointsPerMetre
            guard existing == nil ? moved > 0 : moved >= 0.2 else { return }

            overlay.head = point
            renderer(forFlownPath: overlay, on: mapView)?
                .refreshHead(from: previous, to: point)
        }

        /// Takes the head back off, and repaints where it was.
        private func retreatFlownHead(of overlay: FlownPathOverlay, on mapView: MKMapView) {
            guard let previous = overlay.head else { return }
            overlay.head = nil
            renderer(forFlownPath: overlay, on: mapView)?
                .refreshHead(from: overlay.tail, to: previous)
        }

        private func renderer(
            forFlownPath overlay: FlownPathOverlay,
            on mapView: MKMapView
        ) -> FlownPathRenderer? {
            mapView.renderer(for: overlay) as? FlownPathRenderer
        }

        /// Where an aircraft is being *drawn*, which is what the camera and the
        /// buttons beside the window should be acting on. Falls back to what
        /// the feed said for anything not currently being carried.
        private func drawnCoordinate(for flight: Flight) -> CLLocationCoordinate2D {
            annotations[flight.id]?.coordinate ?? flight.coordinate
        }

        // MARK: Camera

        /// Carries out a camera move, once.
        ///
        /// A command is ticked off when the move has actually happened, not
        /// when it has been read — and that is the difference between a button
        /// that works and one that works on the second press. This runs inside
        /// a layout pass, and a layout pass can arrive at a moment when there
        /// is nothing to move to: the map has no size yet because the window
        /// around it is still coming up, or the open aircraft is missing from
        /// the packet that happens to be current, which the feed does for a
        /// beat on a reconnect. Every one of those used to mark the command
        /// handled on the way past and then quietly do nothing. Left unticked
        /// it is carried out on the next pass instead, which is a few
        /// milliseconds later and is the whole of the difference.
        func handle(_ command: MapCommand?, on mapView: MKMapView) {
            guard let command = command, command.id != handledCommand else { return }

            // No map to move. Nothing about the request is wrong, so it waits.
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }

            let carried: Bool
            switch command.kind {
            case .centerOnFlight:
                carried = center(on: mapView)
            case .fitRoute:
                carried = fitRoute(on: mapView)
            case .fitFlownPath:
                carried = fitFlownPath(on: mapView)
            case .focus(let latitude, let longitude, let spanMeters):
                carried = focus(
                    on: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    spanMeters: spanMeters,
                    on: mapView
                )
            }

            // Or there is nothing left to wait for: the three moves above are
            // all about the open aircraft, and there isn't one. Ticked off so a
            // stale request cannot fire at whatever is opened next.
            if carried || parent.selection == nil { handledCommand = command.id }
        }

        /// Takes the map to somewhere it isn't currently looking — a search
        /// result, a field with a tower open. Unlike `center`, this sets the
        /// zoom as well as the position: the whole point is that whatever was
        /// picked may be nowhere near the current view.
        @discardableResult
        private func focus(
            on coordinate: CLLocationCoordinate2D,
            spanMeters: Double,
            on mapView: MKMapView
        ) -> Bool {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return false }

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
                edgePadding: edgeInsets(in: mapView.bounds),
                animated: true
            )
            return true
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
        @discardableResult
        private func center(on mapView: MKMapView) -> Bool {
            guard let flight = selectedFlight() else { return false }
            return pan(to: drawnCoordinate(for: flight), on: mapView)
        }

        /// Moves the camera so a coordinate lands in the middle of whatever
        /// part of the map nothing is standing on — without touching the zoom,
        /// the heading or the pitch.
        ///
        /// ## Why this is not `setVisibleMapRect(_:edgePadding:)`
        ///
        /// It was, and that was the first bug behind "the centre button doesn't
        /// work". `edgePadding` does not *offset* a rect; it **fits** it inside
        /// the view's bounds inset by that padding. Handing it a rect the size
        /// of the current view therefore asks the map to squeeze a whole
        /// screen's worth of world into a smaller box — which it does, by
        /// zooming out. Every tap of "centre on aircraft" pulled the camera
        /// back another notch, and follow mode, which went through the same
        /// call, zoomed out a little every time the aeroplane drifted.
        ///
        /// ## ...and why it is not the projection either, where it can be
        /// helped
        ///
        /// The answer to that was to work in view points: project the aircraft,
        /// work out which view point has to become the middle of the map, and
        /// unproject *that*. Correct arithmetic, and the second bug behind the
        /// same report — because the point it unprojects is, by construction,
        /// as far from the middle of the view as the aircraft is from the
        /// target. Open a window on an aeroplane the sheet is sitting on and
        /// that point is off the bottom of the screen; open one on an aeroplane
        /// the map has since been dragged away from and it is off the screen
        /// entirely. `convert(_:toCoordinateFrom:)` is only asked about points
        /// inside the view, and outside it — on a renderer that is drawing a
        /// tilted, curved planet — what comes back is a coordinate near the
        /// horizon rather than the one the arithmetic wanted. Which is a centre
        /// button that lands nowhere near the aeroplane, and the further away
        /// it was, the further away it lands.
        ///
        /// So on the flat north-up map — which is every map the app opens on —
        /// the move is made in Mercator space, where it is exact and where a
        /// point off the edge of the screen is no different from one on it: the
        /// visible rect is slid so the aircraft's own map point falls at the
        /// same fraction across and down it as the target does across and down
        /// the view. Same size of rect in, same size out, so the zoom is
        /// untouched by construction rather than by asking.
        ///
        /// The globe cannot be done that way — `visibleMapRect` means nothing
        /// on a sphere — so it keeps the projection, guarded now: if the point
        /// that would have to be unprojected is outside the view, the camera
        /// goes straight to the aircraft instead. A little less considerate of
        /// the chrome, and the right place to be looking.
        @discardableResult
        private func pan(to coordinate: CLLocationCoordinate2D, on mapView: MKMapView) -> Bool {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return false }

            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }

            // The middle of what nothing is standing on, which on a phone with
            // the flight window up is well above the middle of the screen.
            let clear = bounds.inset(by: edgeInsets(in: bounds))
            let target = CGPoint(x: clear.midX, y: clear.midY)

            if isPlanar(mapView), slide(to: coordinate, landingOn: target, in: bounds, on: mapView) {
                return true
            }

            let here = mapView.convert(coordinate, toPointTo: mapView)
            guard here.x.isFinite, here.y.isFinite else { return false }

            // The view point that has to become the middle of the map for the
            // aircraft to land on `target`.
            let wanted = CGPoint(
                x: bounds.midX + (here.x - target.x),
                y: bounds.midY + (here.y - target.y)
            )

            let camera = mapView.camera
            let distance = camera.centerCoordinateDistance
            let centre = mapView.convert(wanted, toCoordinateFrom: mapView)

            // Off the view, over the horizon, or a camera with no usable
            // height: none of those have an answer worth trusting.
            guard bounds.insetBy(dx: -1, dy: -1).contains(wanted),
                  CLLocationCoordinate2DIsValid(centre),
                  distance.isFinite,
                  distance > 0
            else {
                mapView.setCenter(coordinate, animated: true)
                return true
            }

            mapView.setCamera(
                MKMapCamera(
                    lookingAtCenter: centre,
                    fromDistance: distance,
                    pitch: camera.pitch,
                    heading: camera.heading
                ),
                animated: true
            )
            return true
        }

        /// Whether the map is the flat sheet seen from straight above, north
        /// up — the one case where the view and `visibleMapRect` are the same
        /// rectangle under an affine transform, and the slide below is exact.
        private func isPlanar(_ mapView: MKMapView) -> Bool {
            guard !parent.style.isFreeCamera else { return false }

            let camera = mapView.camera
            guard camera.pitch < 0.5 else { return false }
            return camera.heading < 0.5 || camera.heading > 359.5
        }

        /// Slides the visible rect, keeping its size, so `coordinate` lands on
        /// `target`.
        ///
        /// Everything is a fraction of the rect: where the target sits in the
        /// view is where the aircraft has to sit in the rect. Off-screen is not
        /// a special case — a map point is a map point wherever the camera
        /// happens to be looking — which is the whole reason this exists.
        private func slide(
            to coordinate: CLLocationCoordinate2D,
            landingOn target: CGPoint,
            in bounds: CGRect,
            on mapView: MKMapView
        ) -> Bool {
            let rect = mapView.visibleMapRect
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0
            else { return false }

            let point = MKMapPoint(coordinate)
            guard point.x.isFinite, point.y.isFinite else { return false }

            let across = (target.x - bounds.minX) / bounds.width
            let down = (target.y - bounds.minY) / bounds.height

            var x = point.x - rect.width * across
            let y = point.y - rect.height * down

            // The world repeats sideways, and a rect that has walked off one
            // end of it is the same view one world over. Wrapped rather than
            // clamped: an aeroplane a few degrees west of the antimeridian is a
            // short pan from one a few degrees east of it, not a flight across
            // the entire planet.
            let world = MKMapRect.world.size.width
            if world > 0 {
                x = x.truncatingRemainder(dividingBy: world)
                if x < 0 { x += world }
            }

            guard x.isFinite, y.isFinite else { return false }

            mapView.setVisibleMapRect(
                MKMapRect(x: x, y: y, width: rect.width, height: rect.height),
                animated: true
            )
            return true
        }

        /// Frames everything the route touches: the flown track, both
        /// endpoints, and where the aircraft is now.
        @discardableResult
        private func fitRoute(on mapView: MKMapView) -> Bool {
            guard let flight = selectedFlight() else { return false }

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

            guard isFramable(rect, at: flight.coordinate.latitude) else {
                // Nothing worth framing — an aircraft that has just pushed back
                // with no filed route is a rect a few metres across. Put the
                // map on it at the zoom it is already at instead, which is the
                // useful answer to "show me this" and not a view of apron.
                return pan(to: flight.coordinate, on: mapView)
            }

            mapView.setVisibleMapRect(
                rect,
                edgePadding: edgeInsets(in: mapView.bounds),
                animated: true
            )
            return true
        }

        /// Frames the flown track alone — every breadcrumb we hold plus where
        /// the aircraft is now.
        ///
        /// Falls back to centring when there is no track yet to frame, so the
        /// button always does something legible: an aircraft that pushed back a
        /// minute ago has one sample, and framing a single point would either
        /// do nothing or zoom to a hundred metres of apron.
        @discardableResult
        private func fitFlownPath(on mapView: MKMapView) -> Bool {
            guard let flight = selectedFlight() else { return false }

            var rect = MKMapRect.null

            func include(_ coordinate: CLLocationCoordinate2D) {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0.01, height: 0.01))
            }

            let trail = FlightTrailStore.shared.points(for: flight.id)
            guard trail.count >= 2 else {
                return pan(to: flight.coordinate, on: mapView)
            }

            for point in trail { include(point.coordinate) }
            include(flight.coordinate)

            guard isFramable(rect, at: flight.coordinate.latitude) else {
                return pan(to: flight.coordinate, on: mapView)
            }

            mapView.setVisibleMapRect(
                rect,
                edgePadding: edgeInsets(in: mapView.bounds),
                animated: true
            )
            return true
        }

        /// Whether a rect is big enough to frame rather than to fall into.
        ///
        /// `setVisibleMapRect` will fit a fifty-metre box to the screen as
        /// happily as an ocean, and a track a minute old is a fifty-metre box.
        /// Zooming to it answers "where has this been" with a photograph of
        /// some tarmac, which is indistinguishable from the button having
        /// thrown the map away.
        private func isFramable(_ rect: MKMapRect, at latitude: CLLocationDegrees) -> Bool {
            guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return false }

            let perMetre = MKMapPointsPerMeterAtLatitude(latitude)
            guard perMetre > 0, perMetre.isFinite else { return false }

            return max(rect.width, rect.height) >= perMetre * 800
        }

        /// What the app is standing on, as a padding to keep a camera move
        /// clear of: the search field and the weather chip along the top, the
        /// flight window across the bottom or down one side, and a margin so
        /// nothing that is framed ends up hard against an edge.
        ///
        /// Clamped against the view it is for, and that is not defensive
        /// tidying. `bottomInset` is the flight window's own measured height,
        /// and on a short screen with a photo peek up it can be most of the
        /// display; add the top inset and the two can meet or cross. A padding
        /// taller than the view leaves `setVisibleMapRect(_:edgePadding:)`
        /// fitting a rect into a box of negative height — which is a camera
        /// somewhere else entirely — and leaves the middle of the "clear" box
        /// above the top of the screen. Held to two thirds of the view from
        /// each side, so the box being centred in is always a real one.
        private func edgeInsets(in bounds: CGRect) -> UIEdgeInsets {
            let wanted = UIEdgeInsets(
                top: 96,
                left: 44,
                bottom: parent.bottomInset + 28,
                right: 44 + parent.trailingInset
            )

            guard bounds.width > 1, bounds.height > 1 else { return wanted }

            return UIEdgeInsets(
                top: min(wanted.top, bounds.height * 2 / 3),
                left: min(wanted.left, bounds.width * 2 / 3),
                bottom: min(wanted.bottom, bounds.height * 2 / 3),
                right: min(wanted.right, bounds.width * 2 / 3)
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

                return groundRenderer(for: area, title: area.title)
            }

            // Matched by type rather than by title: the flown path is its own
            // overlay now and carries its own points and colours, so there is
            // nothing to look up and nothing to fall back to when the lookup
            // misses — which is what used to paint a whole track grey.
            if let flown = overlay as? FlownPathOverlay {
                let renderer = FlownPathRenderer(overlay: flown)
                renderer.apply(width: flownWidth)
                return renderer
            }

            if let pavement = overlay as? GroundOverlay {
                return GroundRenderer(overlay: pavement, ground: groundLook)
            }

            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
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

            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            if line.title == Self.planTitle {
                // The route as filed: dashed, and faint. It is a statement of
                // intent sitting underneath a track that actually happened, and
                // it should read as the quieter of the two. The colour is
                // shared with the fixes drawn along it, so the line and the
                // diamonds on it are visibly one route.
                //
                // Long dashes with tight gaps, which is deliberately not the
                // dash the inferred legs wear. `plannedTitle` below — the leg
                // back to a departure field nobody watched, the line drawn
                // straight at a destination because the route is unknown — is
                // short marks with wide gaps, and reads as hesitant because it
                // is a guess. A filed plan is the one thing on the map the
                // pilot actually declared, so it gets the confident dash: more
                // ink than gap, closer to a line than to a series of marks.
                //
                // The two can be on screen together — the inferred leg belongs
                // to the flown path, which has its own switch — so telling them
                // apart at a glance is the whole point of the difference.
                renderer.strokeColor = PlanStyle.line
                renderer.lineWidth = 1.8
                renderer.lineDashPattern = [7, 4]
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

            guard let overlay = flownOverlay,
                  let renderer = mapView.renderer(for: overlay) as? FlownPathRenderer
            else { return }

            // The halo follows from the core inside the renderer, so this is
            // the one number, and the renderer decides whether it is worth a
            // repaint.
            renderer.apply(width: width)
        }

        /// What the map underneath the pavement is made of.
        ///
        /// Read off the live style rather than baked into the overlay, so
        /// switching from cartography to imagery restyles the field that is
        /// already drawn — see `refreshGroundLook`.
        private var groundLook: AirportGroundStyle.Ground {
            AirportGroundStyle.Ground(parent.style, isLight: parent.colorScheme == .light)
        }

        /// Aprons and terminals, which are areas rather than runs of pavement.
        ///
        /// Runways and taxiways are drawn by `GroundRenderer` now, to their
        /// real widths. These stay polygons because that is what they are: an
        /// apron is a shape, not a line with a thickness.
        private func groundRenderer(for overlay: MKOverlay, title: String?) -> MKOverlayRenderer {
            let kind = title?.split(separator: ":").last
                .map(String.init)
                .flatMap(AirportLayout.Piece.Kind.init(rawValue:))

            guard let area = overlay as? MKPolygon, let kind = kind else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolygonRenderer(polygon: area)
            renderer.fillColor = AirportGroundStyle.area(for: kind, on: groundLook)
            renderer.strokeColor = .clear
            renderer.lineWidth = 0
            return renderer
        }

        /// Repaints the field for a map it is now lying on something else.
        ///
        /// Pavement is coloured against the ground under it, and that ground
        /// changes without the pavement moving: a switch from the light map to
        /// the dark one, or to imagery, which wants an outline where the others
        /// want a fill. The overlays are unchanged and only their renderers
        /// have anything to say, so this repaints rather than rebuilding.
        private func refreshGroundLook(on mapView: MKMapView) {
            for overlay in groundOverlays {
                mapView.renderer(for: overlay)?.setNeedsDisplay()
            }
            // The polygon renderers hold their fill as a property rather than
            // reading it per frame, so those are rebuilt rather than repainted.
            let areas = groundOverlays.filter { $0 is MKPolygon }
            guard !areas.isEmpty else { return }
            let base = Self.bottomOfRoadsLevel(on: mapView)
            mapView.removeOverlays(areas)
            for (offset, area) in areas.enumerated() {
                mapView.insertOverlay(area, at: base + offset, level: .aboveRoads)
            }
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
            // And square the sprites up once more, now the map has stopped.
            //
            // The live callback above is what keeps them with the finger, and
            // on a gesture it has already done this. This is for the moves that
            // are not gestures: `setCamera(animated:)` centring on an aircraft,
            // fitting a route, restoring the camera after a style swap. Those
            // do not reliably report a changing region on their way past, and
            // one that slipped through left every sprite corrected against
            // wherever the camera used to be. Gated the same way, so on a
            // north-up map and on a settle that only re-culled it is one
            // comparison.
            if parent.style.usesScreenAngles, hasCameraMoved(on: mapView) {
                realign(on: mapView, heading: mapView.camera.heading)
            }

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

    /// The field this aircraft was opened from, when it was opened from one —
    /// a tap in an airport panel's inbound, departed or on-the-ground list.
    ///
    /// Carried here rather than kept beside the selection, and that is the
    /// whole reason it can be trusted. There are a dozen ways into the flight
    /// window — the map, a widget, the friends list, a search result, a deep
    /// link — and every one of them builds a `SelectedFlight` without saying
    /// anything about an airport, so every one of them clears this by simply
    /// not setting it. Separate state would have had to be cleared by each of
    /// them in turn, and the way back to Heathrow would eventually have
    /// survived onto an aeroplane over Chile.
    var origin: String?

    init(id: String, origin: String? = nil) {
        self.id = id
        self.origin = origin
    }
}

/// A one-shot camera move. The token is what makes it one-shot: SwiftUI hands
/// the same value to `updateUIView` on every feed tick, so the map replays
/// nothing it has already carried out.
struct MapCommand: Equatable {

    enum Kind: Equatable {
        case centerOnFlight
        case fitRoute

        /// Frames the track the aircraft has actually flown, and nothing else
        /// — not the departure field it left hours ago, not the arrival field
        /// it has not reached. `fitRoute` frames all of that, which on a
        /// long-haul means the flown path is a fifth of a view mostly full of
        /// ocean. This is the one to reach for when the path is the question.
        case fitFlownPath

        /// Somewhere on the map by position rather than by aircraft — what a
        /// search result or an open tower resolves to. Carried as plain
        /// numbers because `CLLocationCoordinate2D` is not `Equatable`, and
        /// the command has to be comparable to be one-shot.
        case focus(latitude: Double, longitude: Double, spanMeters: Double)
    }

    let kind: Kind
    let id = UUID()
}
