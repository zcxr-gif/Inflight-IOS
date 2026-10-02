// Experimental: `addStyleModel`, for the 3D aircraft.
@_spi(Experimental) import MapboxMaps
import QuartzCore
import SwiftUI
import UIKit

/// The live map. A SwiftUI wrapper over Mapbox's `MapView`.
///
/// ## What changed when this stopped being MapKit
///
/// Everything on this map used to be a MapKit annotation view or an overlay
/// renderer: two thousand `UIView`s for a busy server, each moved, culled and
/// re-rotated on the CPU through every pan, with the routes and the weather
/// re-rasterised into tiles underneath them. However carefully each of those
/// was throttled, the map could never be smoother than that pile of work.
///
/// Now the whole picture is GPU data. Every aeroplane is one feature in one
/// GeoJSON source, drawn by one symbol layer; the routes, the pavement, the
/// night, the airspace and the weather are layers in the same style; the
/// labels are placed in Mapbox's own collision pass. A pinch moves the camera
/// and nothing else — no view is touched, nothing is re-culled, and a sprite is
/// turned to its heading by the GPU against the map itself, so a spun or tilted
/// globe needs no correction at all. What is left on the CPU is the part that
/// is genuinely the app's: deciding what to draw, and carrying the aeroplanes
/// forward between packets, which writes only the handful of features that
/// visibly moved on each frame.
///
/// See `MapLayerStyle` for the layers themselves.
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

    /// And how much of each side, for the same reason.
    ///
    /// Only ever non-zero on a screen wide enough to stand the flight window
    /// down the side of the map instead of across the bottom of it. The column
    /// can be docked on either edge, and at most one of these is ever set.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// How far up the map's own ornaments have to sit — the Mapbox logo and
    /// the attribution button, which the terms require to stay visible and
    /// tappable, while the compass and the scale are both off.
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
    var isFollowing = false

    /// Told when a drag on the map takes the camera away from the aircraft it
    /// was following, so the follow control can show it has let go.
    var onFollowEnded: () -> Void = {}

    /// Whether airborne traffic is carried between packets rather than jumping
    /// on each one. See `FlightMotion`.
    var smoothsTraffic = true

    /// Which way round the map is drawn: the palette's own answer when it has
    /// one, and the app's appearance setting when it hasn't.
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
    /// traffic. Rebuilding several thousand features to discover that is the
    /// work this exists to skip.
    var trafficRevision: Int = 0

    /// Fields worth marking — controlled, or busy. Empty when the filter is
    /// off, which is how the whole feature is switched off.
    var airports: [MapAirport] = []

    /// Bumped when the list above is rebuilt.
    var airportsRevision: Int = 0

    /// Whether to draw the pavement of the field the map is over — runways,
    /// taxiways, aprons and terminals, with the runway designators.
    var showsGroundLayout = true
    var showsFlightPlan = false

    /// Whether each fix on the drawn plan is named. The diamonds are drawn
    /// either way — see `MapFilters.showsPlanFixNames`.
    var showsPlanNames = true

    /// Whether the open aircraft gets a straight line to its destination,
    /// travelling with it. See `RouteLineMode`.
    var showsDirectLine = false

    /// Whether the open aircraft's flown track is drawn. See
    /// `MapFilters.showsFlownPath`.
    var showsFlownPath = true

    /// Which aeroplanes wear their callsign. See `MarkerLabelMode`.
    var markerLabels: MarkerLabelMode = .selected

    /// Whether an aeroplane on a partner VA's callsign wears that VA's logo.
    var showsVaMarks = true

    /// The weather tiles to draw under the traffic, if any.
    var weatherTiles: MapWeatherTiles?

    /// Told when the camera starts and stops moving, so the radar animation
    /// can sit still through a gesture.
    var onCameraMoving: (Bool) -> Void = { _ in }

    /// Where the map has come to rest — its centre, and how many degrees of
    /// latitude are on screen. Reported on the settle rather than through the
    /// gesture, because the one thing that reads it goes to the network.
    var onRegionSettled: (CLLocationCoordinate2D, Double) -> Void = { _, _ in }

    /// The ruler: whether it is down, and where its two ends are.
    @Binding var measurement: MapMeasurement

    /// Whether night is washed over the half of the world that is in it.
    var showsTerminator = false

    /// Whether the North Atlantic organised tracks are drawn.
    var showsNatTracks = false

    /// Whether the airspace of every staffed sector is drawn.
    var showsAtcBoundaries = false

    /// The controllers currently on, which decides *which* airspace is drawn.
    var atcStations: [AtcStation] = []

    /// Whether model wind is drawn across the visible map, and at what height.
    var showsWinds = false
    var windLevel: WindLevel = .fl340

    /// Whether the air is drawn moving. See `WindParticles`.
    var showsWindParticles = false

    /// Which scalar field is washed under the traffic, if any.
    var windHeat: WeatherHeat = .off

    /// Whether a marked field carries its wind and temperature once the map is
    /// close enough for them to be read.
    var showsFieldConditions = true

    /// Observed so a layout that arrives from the network after the map has
    /// settled is drawn when it lands.
    @ObservedObject var layouts = AirportLayoutStore.shared

    /// Observed for the same reason: a grid of wind lands after the pan that
    /// asked for it.
    @ObservedObject var winds = WindsAloftStore.shared

    /// And again: the track set lands a moment after the layer is switched on.
    @ObservedObject var natTracks = NatTrackService.shared

    /// Opening a field that was tapped on the map.
    var onSelectAirport: (String) -> Void = { _ in }

    /// Which aircraft get picked out of the traffic, and in what colour.
    var highlighting = PilotHighlighting()

    /// Whether the traffic is drawn as 3D models, and whose. See
    /// `AircraftModelSource`.
    var aircraftModels: AircraftModelSource = .off

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MapView {
        let initial = MapInitOptions(
            mapStyle: style.mapStyle(isLight: colorScheme == .light),
            // Over the Atlantic and far enough out to see most of the world's
            // traffic, until something asks to look somewhere in particular.
            cameraOptions: CameraOptions(
                center: CLLocationCoordinate2D(latitude: 35, longitude: -30),
                zoom: 1.8
            )
        )

        let mapView = MapView(frame: .zero, mapInitOptions: initial)

        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        context.coordinator.attach(to: mapView)
        return mapView
    }

    /// SwiftUI is finished with the map. The display link holds the coordinator,
    /// and a display link that is never invalidated is a retain cycle that goes
    /// on ticking after the view it draws into is gone.
    static func dismantleUIView(_ mapView: MapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {

        private typealias Layer = MapLayerStyle.Layer
        private typealias Source = MapLayerStyle.Source

        var parent: TrackerMapView

        private weak var mapView: MapView?
        private var map: MapboxMap? { mapView?.mapboxMap }
        private var cancelables: Set<AnyCancelable> = []

        /// Whether the style has loaded and the app's layers are on it. Nothing
        /// is written to the map before this, and everything is written again
        /// after it, because a style load is a clean slate.
        private var isStyleLoaded = false

        /// The images the style currently holds, so each is rendered and
        /// uploaded once. Emptied on a style load, which drops them all.
        private var images: Set<String> = []

        init(_ parent: TrackerMapView) {
            self.parent = parent
            super.init()

            // The marks need the VA directory, and nothing else on the map was
            // ever going to ask for it. Said once, here.
            VaMarkStore.shared.warm()

            // A logo arriving is not a packet and not a gesture, so nothing
            // else would repaint the aeroplanes that were waiting for it.
            VaMarkStore.shared.observeMarks(self) { [weak self] in
                self?.trafficPropertiesStale = true
                self?.pushTraffic()
            }

            // Likewise a 3D model finishing its download: the aeroplanes of
            // that type were drawn flat while they waited for it.
            AircraftModelStore.shared.observe(self) { [weak self] ready in
                guard let self, ready.entry.source == self.parent.aircraftModels else { return }
                self.trafficPropertiesStale = true
                self.pushTraffic()
            }
        }

        // MARK: Life

        func attach(to mapView: MapView) {
            self.mapView = mapView
            let map = mapView.mapboxMap!

            map.onStyleLoaded.observe { [weak self] _ in
                self?.styleDidLoad()
            }.store(in: &cancelables)

            map.onCameraChanged.observe { [weak self] _ in
                self?.cameraDidChange()
            }.store(in: &cancelables)

            // A pinch that ends between two of the air path's rewrites still
            // leaves it drawn for the zoom it came to rest at.
            map.onMapIdle.observe { [weak self] _ in
                self?.refreshSky(force: true)
                self?.refreshModelScale(force: true)
            }.store(in: &cancelables)

            // What lifts the opening screen — see `LaunchGate`. The map has its
            // style and the tiles it needed for the first frame, which is the
            // moment the app looks like a map.
            map.onMapLoaded.observeNext { _ in
                LaunchGate.shared.mapDidDraw()
            }.store(in: &cancelables)

            // The map-wide tap interaction, which is what Mapbox's gesture
            // tap became. Every tap lands here and is sorted out by
            // `handleTap`, which queries the layers itself.
            let tap = map.addInteraction(TapInteraction { [weak self] context in
                self?.handleTap(at: context.point, coordinate: context.coordinate)
                return true
            })
            cancelables.insert(AnyCancelable(tap.cancel))

            applyGestures(for: parent.style)
            mapView.gestures.delegate = self
            startFlying()

            // The frame rates follow the phone's condition, not just the
            // screen's capability. See `applyFrameRates`.
            let centre = NotificationCenter.default
            powerObservers = [
                centre.addObserver(
                    forName: ProcessInfo.thermalStateDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.applyFrameRates() },
                centre.addObserver(
                    forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.applyFrameRates() },
            ]
        }

        private var powerObservers: [NSObjectProtocol] = []

        /// How fast the map and the traffic clock run.
        ///
        /// The full refresh rate of a ProMotion screen for the map while a
        /// finger is on it — Mapbox drops back on its own when nothing moves —
        /// and sixty for the aeroplanes, which are never under a finger. In Low
        /// Power Mode, or once the phone is running hot, both are halved up
        /// front: an even sixty is smooth, and iOS throttling a hot phone at
        /// whatever moment it chooses is not. This is the same bargain the
        /// system apps make.
        private func applyFrameRates() {
            let info = ProcessInfo.processInfo
            let constrained = info.isLowPowerModeEnabled
                || info.thermalState == .serious
                || info.thermalState == .critical

            mapView?.preferredFrameRateRange = constrained
                ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                : CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            flightLink?.preferredFrameRateRange = constrained
                ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                : CAFrameRateRange(minimum: 20, maximum: 60, preferred: 60)
        }

        func detach() {
            stopFlying()
            for observer in powerObservers { NotificationCenter.default.removeObserver(observer) }
            powerObservers.removeAll()
            cancelables.removeAll()
            VaMarkStore.shared.stopObservingMarks(self)
            AircraftModelStore.shared.stopObserving(self)
            pendingSettle?.cancel()
        }

        /// The style has loaded — the first one, or a new one after a change
        /// between cartography and imagery. Every layer the app draws goes on,
        /// empty, and everything is written into them again.
        private func styleDidLoad() {
            guard let map = map else { return }
            isStyleLoaded = true
            images.removeAll()
            styleModels.removeAll()
            appliedAirPath = nil
            appliedSky = nil

            MapLayerStyle.install(on: map, labelMinZoom: labelMinZoom)
            registerStaticImages()

            weatherLayer.styleDidReload()
            heatInstalled = false
            particlesInstalled = false
            terrainInstalled = false
            heatKey = nil
            particleKey = nil

            invalidateEverything()
            applyProjection(for: parent.style)
            applyTerrain(for: parent.style)
            MapLayerStyle.applyScheme(isLight: isLight, on: map)
            MapLayerStyle.applyWash(parent.style.wash, on: map)
            appliedWash = parent.style.wash
            applySelectionFilters(force: true)
            applyAirPathLayers()
            refreshSky(force: true)

            cameraDidChange()
            update()
        }

        /// Forgets what every layer was last drawn from, so the next pass
        /// writes all of them.
        private func invalidateEverything() {
            trafficPropertiesStale = true
            trafficNeedsFullWrite = true
            trafficInSource.removeAll()
            syncedTrafficRevision = nil
            renderedAirportKey = nil
            renderedRouteKey = nil
            renderedMeasureKey = nil
            terminatorDrawnAt = nil
            renderedNatKey = nil
            renderedAtcKey = nil
            renderedGroundKey = nil
            renderedWindKey = nil
            renderedReplay = false
            directOrigin = nil
            directDestination = nil
            flownHeadWritten = nil
        }

        // MARK: The update pass

        /// Everything SwiftUI can have changed, applied. Each step compares a
        /// small key against what is already drawn and does nothing when it
        /// matches, which on an ordinary redraw is all of them.
        func update() {
            guard let mapView = mapView, let map = map else { return }

            applyOrnaments(on: mapView)
            applyLook(parent.style, scheme: parent.colorScheme)

            guard isStyleLoaded else { return }

            syncTerminator(on: map)
            syncMeasurement(on: map)
            syncWeatherTiles(on: map)
            syncWinds(on: map)
            syncNatTracks(on: map)
            syncAtcBoundaries(on: map)
            applyHighlighting(parent.highlighting)
            syncTrafficIfNeeded()
            syncAirports(on: map)
            applySelectionFilters(force: false)
            applyAirPathLayers()
            syncRoute(on: map)
            syncReplay(on: map)
            syncGround(on: map)
            // Before the command, so a camera move asked for on this same pass
            // is the one that lands rather than being pulled back by the follow.
            followSelection()
            handle(parent.command)

            // And say where the world is pointed. The settle is the
            // interesting report; this is the safety net under it, for a map
            // that never moves at all after launch.
            if let region = region, region.isUsable {
                parent.onRegionSettled(region.center, region.span.latitudeDelta)
            }
        }

        // MARK: Ornaments

        private var appliedOrnamentInsets: (bottom: CGFloat, leading: CGFloat)?

        /// Keeps the Mapbox logo and attribution clear of the chrome, which
        /// the terms require to stay visible and tappable.
        ///
        /// Both in the bottom-leading corner, side by side: the trailing corner
        /// is where an iPad's flight pane docks by default, and an attribution
        /// button underneath it is one nobody can reach. Lifted by however much
        /// of the bottom of the map the app is covering, and moved past a pane
        /// docked on the leading edge instead.
        private func applyOrnaments(on mapView: MapView) {
            let insets = (bottom: parent.legalInset, leading: parent.leadingInset)
            if let applied = appliedOrnamentInsets, applied == insets { return }
            appliedOrnamentInsets = insets

            let x = 10 + insets.leading
            let y = insets.bottom + 4
            mapView.ornaments.options.logo.position = .bottomLeading
            mapView.ornaments.options.logo.margins = CGPoint(x: x, y: y)
            mapView.ornaments.options.attributionButton.position = .bottomLeading
            // Past the logo, which is about ninety points of wordmark.
            mapView.ornaments.options.attributionButton.margins = CGPoint(x: x + 92, y: y)
        }

        // MARK: Look

        private var isLight: Bool { parent.colorScheme == .light }

        /// The cartography last asked for — the look without its brightness,
        /// and the scheme — so the style is only reconfigured when one of those
        /// actually moved.
        private var appliedCartography: MapLook?
        private var appliedScheme: ColorScheme?
        private var appliedWash: MapWash?

        /// Applies a look and a scheme to the map.
        ///
        /// Three costs, kept apart. The brightness is one layer's opacity, and a
        /// slider drags it a hundred times on the way across. The palette, the
        /// detail and the scheme are configuration on the loaded style, which
        /// Mapbox cross-fades without reloading anything. Only a step between
        /// cartography and imagery swaps the style itself — and the layers come
        /// back on their own when the new one lands, see `styleDidLoad`.
        private func applyLook(_ look: MapLook, scheme: ColorScheme) {
            guard let map = map else { return }

            if appliedWash != look.wash, isStyleLoaded {
                appliedWash = look.wash
                MapLayerStyle.applyWash(look.wash, on: map)
            }

            let cartographyChanged = appliedCartography.map { !$0.sameCartography(as: look) } ?? true
            let schemeChanged = appliedScheme != scheme
            guard cartographyChanged || schemeChanged else { return }

            let previous = appliedCartography
            appliedCartography = look
            appliedScheme = scheme

            // Cartography and imagery are two different styles, and the step
            // between them is a reload: everything the app put on the old one
            // goes with it, and nothing is written until the new one lands.
            if let previous = previous,
               previous.resolvedPalette.usesImagery != look.resolvedPalette.usesImagery {
                isStyleLoaded = false
            }

            map.mapStyle = look.mapStyle(isLight: scheme == .light)
            applyGestures(for: look)

            // The camera does not depend on the style, so a change of shape
            // reframes at once, whether or not a new style is still loading.
            if let previous = previous, previous.projection != look.projection {
                reframe(from: previous, to: look)
            }

            guard isStyleLoaded else { return }

            if schemeChanged {
                MapLayerStyle.applyScheme(isLight: scheme == .light, on: map)
                refreshSky(force: true)
                // The pieces of the map whose colours are baked into their
                // features rather than their layers: the night, the fixes and
                // the barbs are drawn per scheme, and the pavement per ground.
                terminatorDrawnAt = nil
                renderedRouteKey = nil
                renderedWindKey = nil
                renderedGroundKey = nil
            }

            if cartographyChanged {
                applyProjection(for: look)
                applyTerrain(for: look)
                // Pavement is outlined over imagery and painted over
                // cartography, so it has to hear about the ground changing.
                renderedGroundKey = nil
            }
        }

        private func applyGestures(for look: MapLook) {
            guard let mapView = mapView else { return }
            mapView.gestures.options.rotateEnabled = look.isFreeCamera
            // A 3D aircraft seen only from straight above is a plan view, so
            // with models on the map can always be tilted to look at them.
            mapView.gestures.options.pitchEnabled = look.isPitchEnabled || parent.aircraftModels != .off
        }

        private func applyProjection(for look: MapLook) {
            try? map?.setProjection(StyleProjection(name: look.projection.styleProjection))
        }

        private var terrainInstalled = false

        /// Real elevation under the map, where the look asks for it. Mapbox's
        /// own elevation model, at the exaggeration the ground actually has.
        private func applyTerrain(for look: MapLook) {
            guard let map = map, isStyleLoaded else { return }

            guard look.hasTerrain else {
                if terrainInstalled {
                    map.removeTerrain()
                    terrainInstalled = false
                }
                return
            }

            if !map.sourceExists(withId: Source.terrain) {
                let properties: [String: Any] = [
                    "type": "raster-dem",
                    "url": "mapbox://mapbox.mapbox-terrain-dem-v1",
                    "tileSize": 512,
                    "maxzoom": 14,
                ]
                try? map.addSource(withId: Source.terrain, properties: properties)
            }
            let terrain: [String: Any] = ["source": Source.terrain, "exaggeration": 1]
            try? map.setTerrain(properties: terrain)
            terrainInstalled = true
        }

        /// Moves the camera for a change of shape: out to where the globe looks
        /// like one, or back to north-up and level on the way down from it.
        private func reframe(from previous: MapLook, to look: MapLook) {
            guard let mapView = mapView, let map = map else { return }
            let state = map.cameraState

            if let zoom = look.projection.openingZoom {
                mapView.camera.ease(
                    to: CameraOptions(center: state.center, zoom: min(state.zoom, zoom), bearing: 0, pitch: 0),
                    duration: 0.9
                )
            } else if !look.isFreeCamera, state.bearing != 0 || (state.pitch != 0 && !look.isPitchEnabled) {
                mapView.camera.ease(
                    to: CameraOptions(bearing: 0, pitch: look.isPitchEnabled ? state.pitch : 0),
                    duration: 0.5
                )
            }
        }

        // MARK: Images

        /// The images that never change with the data: the callsign plates,
        /// the airport pins and the fix diamonds.
        private func registerStaticImages() {
            for light in [false, true] {
                let plate = FlightMarkStyle.plate(isLight: light)
                let inset = FlightMarkStyle.callsignRadius + 0.5
                addImage(
                    plate.resizableImage(withCapInsets: UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)),
                    id: FlightMarkStyle.plateImage(isLight: light)
                )
                for next in [false, true] {
                    addImage(PlanFixGlyph.image(isNext: next, isLight: light), id: Self.fixImage(isNext: next, isLight: light))
                }
            }
            for controlled in [false, true] {
                let key = AirportMarker.spriteKey(isControlled: controlled)
                if let pin = PlaneSprites.shared.rawIcon(forKey: key, pointSize: AirportMarker.glyph) {
                    addImage(pin, id: Self.fieldImage(isControlled: controlled))
                }
            }
        }

        private func addImage(_ image: UIImage, id: String) {
            guard let map = map, !images.contains(id) else { return }
            do {
                try map.addImage(image, id: id)
                images.insert(id)
            } catch {
                NSLog("[Map] image %@ could not be added: %@", id, String(describing: error))
            }
        }

        private static func fixImage(isNext: Bool, isLight: Bool) -> String {
            "fix|\(isNext ? "next" : "plain")|\(isLight ? "light" : "dark")"
        }

        private static func fieldImage(isControlled: Bool) -> String {
            isControlled ? "field|large" : "field|small"
        }

        /// The sprite for one aeroplane: its airframe, in its body colour —
        /// white, amber for the open one, or whatever the pilot colouring or
        /// the aircraft's own source says. Rendered the first time it is
        /// wanted and shared by every aeroplane that looks the same.
        private func planeImage(key: String, tint: UIColor?, selected: Bool) -> String {
            let body = tint.map { MapLayerStyle.rgba($0) } ?? (selected ? "selected" : "plain")
            let id = "plane|\(key)|\(body)"
            if !images.contains(id),
               let image = PlaneSprites.shared.planetIcon(
                   forKey: key,
                   pointSize: AppConfig.iconPointSize,
                   body: tint,
                   selected: selected
               ) {
                addImage(image, id: id)
            }
            return id
        }

        /// A VA's logo, once it has arrived.
        private func markImage(for ad: VaAd) -> String? {
            let id = "va|\(ad.id)"
            if images.contains(id) { return id }
            // Asking is also what starts the download; nil until it lands.
            guard let logo = VaMarkStore.shared.mark(for: ad) else { return nil }
            addImage(logo, id: id)
            return images.contains(id) ? id : nil
        }

        private func barbImage(knots: Int, isLight: Bool) -> String {
            let id = "barb|\(knots)|\(isLight ? "light" : "dark")"
            if !images.contains(id) {
                addImage(WindBarbGlyph.image(knots: knots, isLight: isLight), id: id)
            }
            return id
        }

        // MARK: Writing features

        private func push(_ features: [Feature], to source: String) {
            guard let map = map, isStyleLoaded else { return }
            map.updateGeoJSONSource(withId: source, geoJSON: .featureCollection(FeatureCollection(features: features)))
        }

        private func clear(_ source: String) {
            push([], to: source)
        }

        private static func pointFeature(
            _ coordinate: CLLocationCoordinate2D,
            id: String? = nil,
            _ properties: JSONObject
        ) -> Feature {
            var feature = Feature(geometry: .point(Point(coordinate)))
            if let id = id { feature.identifier = .string(id) }
            feature.properties = properties
            return feature
        }

        private static func lineFeature(
            _ coordinates: [CLLocationCoordinate2D],
            id: String? = nil,
            _ properties: JSONObject = [:]
        ) -> Feature {
            var feature = Feature(geometry: .lineString(LineString(coordinates)))
            if let id = id { feature.identifier = .string(id) }
            feature.properties = properties
            return feature
        }

        private static func polygonFeature(
            _ rings: [[CLLocationCoordinate2D]],
            _ properties: JSONObject
        ) -> Feature {
            var feature = Feature(geometry: .polygon(Polygon(rings.map(closed))))
            feature.properties = properties
            return feature
        }

        /// A ring with its first point repeated at the end, which is how
        /// GeoJSON says a ring is closed.
        private static func closed(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
            guard let first = ring.first, let last = ring.last else { return ring }
            if first.latitude == last.latitude, first.longitude == last.longitude { return ring }
            return ring + [first]
        }

        // MARK: The camera, as the layers need it

        /// What is on screen, as of the last camera change.
        private(set) var region: GeoRegion?

        /// The current zoom, and how many points one metre covers at the
        /// middle of the screen — the scale every "would anybody see this
        /// move" question is asked against.
        private var zoom: Double = 2
        private var pointsPerMetre: Double = 0

        /// The visible box, widened, that the smoothing works inside.
        private var smoothingBox: (south: Double, north: Double, west: Double, east: Double)?

        /// Whether a point is inside `smoothingBox` — or anywhere, before the
        /// camera has been seen.
        private func isInSmoothingBox(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard let box = smoothingBox else { return true }
            var longitude = coordinate.longitude
            if longitude < box.west { longitude += 360 }
            return coordinate.latitude >= box.south && coordinate.latitude <= box.north
                && longitude >= box.west && longitude <= box.east
        }

        /// The label zoom: as far in as a dozen degrees of latitude on this
        /// screen. See `MapFilters.labelZoomSpan`, which is the same rule.
        private var labelMinZoom: Double {
            let height = max(Double(mapView?.bounds.height ?? 800), 300)
            let span = MapFilters.labelZoomSpan
            // A degree of latitude is 111 km; Mercator's metres per point at a
            // middling latitude, solved for the zoom that fits `span` in
            // `height` points.
            let metresPerPoint = span * 111_320 / height
            let zoom = log2(40_075_016.686 * cos(40 * Double.pi / 180) / (512 * metresPerPoint))
            return zoom.isFinite ? min(max(zoom, 0), 22) : 5
        }

        /// Whether the camera is being moved right now — a finger on the map,
        /// or an animated move that has not landed. The layers that are a
        /// function of the region stand off until it stops.
        private var isRegionChanging = false
        private var pendingSettle: DispatchWorkItem?

        private func cameraDidChange() {
            guard let mapView = mapView, let map = map else { return }
            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return }

            let state = map.cameraState
            zoom = Double(state.zoom)

            let latitude = state.center.latitude
            let circumference = 40_075_016.686 * max(cos(latitude * .pi / 180), 0.01)
            pointsPerMetre = 512 * pow(2, zoom) / circumference

            let visible = map.coordinateBounds(for: bounds)
            var west = visible.west
            var east = visible.east
            if east < west { east += 360 }
            let latitudeSpan = max(visible.north - visible.south, 0)
            let longitudeSpan = max(east - west, 0)
            region = GeoRegion(
                center: CLLocationCoordinate2D(
                    latitude: (visible.north + visible.south) / 2,
                    longitude: WeatherField.wrapped((west + east) / 2)
                ),
                span: GeoSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
            )

            let padLatitude = latitudeSpan * 0.25
            let padLongitude = longitudeSpan * 0.25
            west -= padLongitude
            east += padLongitude
            smoothingBox = (
                visible.south - padLatitude,
                visible.north + padLatitude,
                west,
                east
            )

            // The moving air is told where the camera is on every change: it
            // sets where new particles are born and how fast the clock runs.
            if let particles = particles {
                particles.look(at: visibleMercatorRect(), latitude: latitude)
            }

            if !isRegionChanging {
                isRegionChanging = true
                parent.onCameraMoving(true)
            }
            scheduleSettle()
        }

        /// Everything that waits for the map to stop moving, coalesced so a
        /// gesture made of a hundred camera changes runs it once, at the end.
        private func scheduleSettle() {
            pendingSettle?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let map = self.map else { return }
                if self.isRegionChanging {
                    self.isRegionChanging = false
                    self.parent.onCameraMoving(false)
                }
                guard self.isStyleLoaded else { return }
                self.syncAirports(on: map)
                self.syncGround(on: map)
                self.syncWinds(on: map)
                self.syncWeatherTiles(on: map)

                if let region = self.region, region.isUsable {
                    self.parent.onRegionSettled(region.center, region.span.latitudeDelta)
                }
            }

            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// The visible map as a Mercator rectangle, with its east edge carried
        /// past the antimeridian when the view straddles it.
        private func visibleMercatorRect() -> MercatorRect {
            guard let mapView = mapView, let map = map else { return .null }
            let visible = map.coordinateBounds(for: mapView.bounds)
            let topLeft = MercatorPoint(CLLocationCoordinate2D(latitude: visible.north, longitude: visible.west))
            var bottomRight = MercatorPoint(CLLocationCoordinate2D(latitude: visible.south, longitude: visible.east))
            if bottomRight.x < topLeft.x { bottomRight.x += MercatorRect.worldSide }
            return MercatorRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )
        }

        // MARK: Traffic

        private var markers: [String: FlightMarker] = [:]

        /// When each drawn aircraft was last in a packet, so one the feed skips
        /// for a moment can be held rather than removed and re-added.
        private var lastSeen: [String: Date] = [:]

        /// The revision the drawn traffic was last built from.
        private var syncedTrafficRevision: Int?

        /// Whether every feature's properties need building again — a change of
        /// highlighting, of labels, or a logo arriving — rather than only the
        /// positions of the aeroplanes that moved.
        private var trafficPropertiesStale = true

        /// What each aeroplane's feature carries apart from where it is and
        /// which way it points: its sprites and its marks. Built when those can
        /// have changed and reused on every frame in between.
        private var trafficProperties: [String: JSONObject] = [:]

        /// What each aeroplane's properties were built from — its airframe,
        /// callsign, pilot and source — so a packet rebuilds only the ones that
        /// changed rather than looking every aircraft on the server up in the
        /// VA directory again.
        private var trafficSignatures: [String: String] = [:]

        /// Packets since every aeroplane's properties were last rebuilt. A
        /// sweep every so often picks up what nothing announces — a VA
        /// directory that was still loading when an aeroplane first appeared.
        private var packetsSinceSweep = 0
        private static let packetsPerSweep = 8

        /// How many aircraft on the map are carried whatever the preference
        /// says — real-world traffic, which is swept rather than pushed.
        private var sweptOnMap = 0

        /// The open aircraft as it was in the packet the map was last built
        /// from.
        private var selectedSnapshot: Flight?

        private var appliedHighlighting = PilotHighlighting()
        private var appliedLabelMode: MarkerLabelMode?
        private var appliedVaMarks: Bool?
        private var appliedModelSource: AircraftModelSource?

        func applyHighlighting(_ highlighting: PilotHighlighting) {
            guard appliedHighlighting != highlighting else { return }
            appliedHighlighting = highlighting
            trafficPropertiesStale = true
            pushTraffic()
        }

        private func syncTrafficIfNeeded() {
            if appliedLabelMode != parent.markerLabels || appliedVaMarks != parent.showsVaMarks
                || appliedModelSource != parent.aircraftModels {
                appliedLabelMode = parent.markerLabels
                appliedVaMarks = parent.showsVaMarks
                if appliedModelSource != parent.aircraftModels {
                    appliedModelSource = parent.aircraftModels
                    dropModels(except: parent.aircraftModels)
                    applyGestures(for: parent.style)
                    // Back to level on a look that does not tilt, now there is
                    // nothing standing up to tilt for.
                    if parent.aircraftModels == .off { AircraftModelStore.disarmCrashGuard() }
                    if parent.aircraftModels == .off, !parent.style.isPitchEnabled,
                       let mapView = mapView, mapView.mapboxMap.cameraState.pitch != 0 {
                        mapView.camera.ease(to: CameraOptions(pitch: 0), duration: 0.4)
                    }
                }
                trafficPropertiesStale = true
            }

            guard syncedTrafficRevision != parent.trafficRevision || trafficPropertiesStale else { return }
            if syncedTrafficRevision != parent.trafficRevision {
                syncedTrafficRevision = parent.trafficRevision
                applyPacket(parent.flights)

                packetsSinceSweep += 1
                if packetsSinceSweep >= Self.packetsPerSweep { trafficPropertiesStale = true }
            }
            pushTraffic()
        }

        /// A packet: new aeroplanes added, the rest told where they were
        /// reported, and the ones that have left the feed let go.
        private func applyPacket(_ flights: [Flight]) {
            let now = Date()
            let frameNow = CACurrentMediaTime()
            let selectedId = parent.selection?.id
            var reported = Set<String>()
            reported.reserveCapacity(flights.count)
            var swept = 0
            var selected: Flight?

            for flight in flights {
                reported.insert(flight.id)
                lastSeen[flight.id] = now
                if flight.requiresSmoothing { swept += 1 }
                if flight.id == selectedId { selected = flight }

                if let existing = markers[flight.id] {
                    existing.update(with: flight, now: frameNow)
                    // Something the sprite or the marks are drawn from moved,
                    // so this one's properties are built again.
                    if trafficSignatures[flight.id] != Self.signature(of: flight) {
                        trafficProperties.removeValue(forKey: flight.id)
                    }
                } else {
                    markers[flight.id] = FlightMarker(flight: flight)
                }
            }

            sweptOnMap = swept
            selectedSnapshot = selected

            // One that has vanished from the packet is held for a moment: the
            // feed skips an aircraft for a packet or two and has it back, and
            // removing it in the gap is exactly the blink this is here to stop.
            //
            // Real traffic gets no grace at all, and that is the point: the
            // layer's whole promise is that switching it off empties the map
            // on the same frame.
            for (id, marker) in markers where !reported.contains(id) && id != selectedId {
                let held = marker.flight.origin == .infiniteFlight
                    && now.timeIntervalSince(lastSeen[id] ?? .distantPast) < AppConfig.flightGracePeriod
                guard !held else { continue }
                markers.removeValue(forKey: id)
                lastSeen.removeValue(forKey: id)
                trafficProperties.removeValue(forKey: id)
                trafficSignatures.removeValue(forKey: id)
                modelled.removeValue(forKey: id)
            }
        }

        private static func signature(of flight: Flight) -> String {
            "\(flight.spriteKey)|\(flight.callsign ?? "")|\(flight.username ?? "")|\(flight.origin == .infiniteFlight)"
        }

        /// The aeroplanes the traffic source currently holds, so a packet can
        /// be written as the difference it makes rather than the whole server.
        private var trafficInSource: Set<String> = []

        /// Whether the next write has to be the whole source — the first one on
        /// a fresh style, or after every aeroplane's properties were rebuilt.
        private var trafficNeedsFullWrite = true

        /// Writes the traffic source.
        ///
        /// As a difference wherever it can be. A packet moves the aeroplanes
        /// that are flying and leaves the third of the server sitting at gates
        /// exactly where it was, and the aeroplanes being smoothed have already
        /// been written by the frame clock — so the ordinary packet is a few
        /// hundred updates, a handful of arrivals and departures, and nothing
        /// at all for everything else. Mapbox re-tiles only what it is handed,
        /// on its worker thread, which is what keeps a packet landing in the
        /// middle of a pinch from being felt.
        ///
        /// When most of the source has changed anyway, one full write is
        /// cheaper than a long list of partial ones, so it does that instead.
        private func pushTraffic() {
            guard isStyleLoaded, let map = map else { return }

            if trafficPropertiesStale {
                trafficPropertiesStale = false
                packetsSinceSweep = 0
                trafficProperties.removeAll(keepingCapacity: true)
                trafficNeedsFullWrite = true
            }

            var added: [Feature] = []
            var updated: [Feature] = []

            for (id, marker) in markers {
                let fresh = trafficProperties[id] == nil
                if fresh {
                    trafficProperties[id] = properties(for: marker)
                    trafficSignatures[id] = Self.signature(of: marker.flight)
                }

                guard !trafficNeedsFullWrite else { continue }

                if !trafficInSource.contains(id) {
                    added.append(trafficFeature(for: marker))
                } else if fresh || Self.hasMoved(marker) {
                    updated.append(trafficFeature(for: marker))
                }
            }

            let removed = trafficInSource.filter { markers[$0] == nil }

            let partial = added.count + updated.count + removed.count
            if trafficNeedsFullWrite || partial > max(markers.count * 6 / 10, 64) {
                trafficNeedsFullWrite = false
                push(markers.values.map { trafficFeature(for: $0) }, to: Source.traffic)
                trafficInSource = Set(markers.keys)
                return
            }

            guard partial > 0 else { return }

            if !removed.isEmpty {
                map.removeGeoJSONSourceFeatures(forSourceId: Source.traffic, featureIds: Array(removed))
                trafficInSource.subtract(removed)
            }
            if !added.isEmpty {
                map.addGeoJSONSourceFeatures(forSourceId: Source.traffic, features: added)
                for feature in added {
                    if case .string(let id)? = feature.identifier { trafficInSource.insert(id) }
                }
            }
            if !updated.isEmpty {
                map.updateGeoJSONSourceFeatures(forSourceId: Source.traffic, features: updated)
            }
        }

        /// Whether what is drawn differs from what was last written at all —
        /// exactly, not by the on-screen threshold the frame clock uses: an
        /// aeroplane off screen still has to be in the right place when the
        /// map is panned to it.
        private static func hasMoved(_ marker: FlightMarker) -> Bool {
            guard let written = marker.writtenCoordinate, let heading = marker.writtenHeading else { return true }
            return written.latitude != marker.coordinate.latitude
                || written.longitude != marker.coordinate.longitude
                || heading != marker.drawnHeading
        }

        private func trafficFeature(for marker: FlightMarker) -> Feature {
            var properties = trafficProperties[marker.flightId] ?? [:]
            properties["heading"] = JSONValue.number(marker.drawnHeading)
            marker.writtenCoordinate = marker.coordinate
            marker.writtenHeading = marker.drawnHeading
            if modelled[marker.flightId] != nil {
                addModelPose(to: &properties, for: marker)
            }
            return Self.pointFeature(marker.coordinate, id: marker.flightId, properties)
        }

        /// Everything an aeroplane's feature says about it but its position.
        private func properties(for marker: FlightMarker) -> JSONObject {
            let flight = marker.flight
            // The pilot colouring first, and the aircraft's own source behind
            // it — see `Flight.originTint`. Real traffic has no username, so in
            // practice the two never meet.
            let tint = appliedHighlighting.tint(for: flight.username) ?? flight.originTint
            let key = flight.spriteKey

            var properties: JSONObject = [
                "fid": .string(flight.id),
                "icon": .string(planeImage(key: key, tint: tint, selected: false)),
                "iconSelected": .string(planeImage(key: key, tint: tint, selected: true)),
            ]

            let callsign = (flight.callsign ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !callsign.isEmpty {
                switch parent.markerLabels {
                case .off:
                    break
                case .selected:
                    properties["selectedLabel"] = JSONValue.string(callsign)
                case .all:
                    properties["label"] = JSONValue.string(callsign)
                    properties["selectedLabel"] = JSONValue.string(callsign)
                }
            }

            // The 3D model, when one is chosen and has arrived. Until it has,
            // the aeroplane stays a flat icon — and asking is what fetches it.
            // Always the model itself, at real size — see `AircraftModelStyle`.
            modelled.removeValue(forKey: flight.id)
            if parent.aircraftModels != .off,
               let entry = AircraftModelCatalog.entry(for: flight, in: parent.aircraftModels),
               let ready = AircraftModelStore.shared.ready(entry),
               registerModel(id: ready.entry.styleId, file: ready.file) {
                properties["model"] = JSONValue.string(ready.entry.styleId)
                modelled[flight.id] = ready.lengthMetres
                properties["mlen"] = JSONValue.number(ready.lengthMetres)
                if let tint {
                    properties["tint"] = JSONValue.string(MapLayerStyle.rgba(tint))
                }
            }

            // Never on real traffic. A logo over an aeroplane is read as whose
            // aeroplane it is, the partner listings are keyed on callsign, and
            // real airline callsigns collide with virtual ones by design.
            if parent.showsVaMarks, flight.origin == .infiniteFlight,
               let ad = VaMarkStore.shared.partner(callsign: flight.callsign),
               let mark = markImage(for: ad) {
                properties["mark"] = JSONValue.string(mark)
                properties["selectedMark"] = JSONValue.string(mark)
            }

            return properties
        }

        // MARK: 3D aircraft

        /// The models the style holds, by style id. Emptied on a style load,
        /// which drops them with everything else.
        private var styleModels: Set<String> = []

        /// The aeroplanes drawn as models, and each one's real length.
        private var modelled: [String: Double] = [:]

        /// The aircraft flown on this phone, as its own simulator reports it.
        private struct OwnAttitude: Equatable {
            let flightId: String
            let pitch: Double
            let bank: Double
            let heightMetres: Double?
        }

        private var ownAttitude: OwnAttitude?
        private var writtenOwnAttitude: OwnAttitude?

        /// Puts a model on the style, once. False if Mapbox would not take it.
        private func registerModel(id: String, file: URL) -> Bool {
            if styleModels.contains(id) { return true }
            guard let map = map, isStyleLoaded else { return false }
            do {
                AircraftModelStore.armCrashGuard()
                try map.addStyleModel(modelId: id, modelUri: file.absoluteString)
                styleModels.insert(id)
                return true
            } catch {
                NSLog("[Map] model %@ could not be added: %@", id, String(describing: error))
                return false
            }
        }

        /// Takes another source's models off the style, so switching between
        /// them does not keep three fleets in memory at once.
        ///
        /// A few seconds later rather than now. The features that name the old
        /// models are rewritten on this same pass, but Mapbox applies that on
        /// its own thread, and a model taken away while a feature still asks
        /// for it is not something to find out about on a live map.
        private func dropModels(except source: AircraftModelSource) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let map = self.map, self.parent.aircraftModels == source else { return }
                let keep = "ac3d-\(source.key)-"
                for id in self.styleModels where !id.hasPrefix(keep) {
                    try? map.removeStyleModel(modelId: id)
                    self.styleModels.remove(id)
                }
            }
        }

        /// Where the model points and how high it flies, written beside the
        /// heading on every write of the feature.
        private func addModelPose(to properties: inout JSONObject, for marker: FlightMarker) {
            let now = CACurrentMediaTime()
            let pitch: Double
            let bank: Double
            if let own = ownAttitude, own.flightId == marker.flightId {
                pitch = own.pitch
                bank = own.bank
            } else {
                pitch = marker.attitude.pitch(at: now)
                bank = marker.attitude.bank(at: now)
            }
            let height = modelHeight(for: marker, at: now)
            marker.writtenBank = bank
            let scale = modelScale(for: marker)
            writtenScale[marker.flightId] = scale

            let pose = AircraftModelStyle.properties(
                heading: marker.drawnHeading,
                pitch: pitch,
                bank: bank,
                heightMetres: height,
                scale: scale
            )
            for (key, values) in pose {
                properties[key] = JSONValue.array(values.map { JSONValue.number($0) })
            }
        }

        /// The factor each model was last written at, and the zoom the models
        /// were last looked over for — see `refreshModelScale`.
        private var writtenScale: [String: Double] = [:]
        private var scaleCheckedZoom = 2.0
        private var scaleStaleOffScreen = false

        /// The factor a model is drawn at right now — see
        /// `AircraftModelStyle.magnification`.
        private func modelScale(for marker: FlightMarker) -> Double {
            AircraftModelStyle.magnification(
                lengthMetres: modelled[marker.flightId] ?? 38,
                latitude: marker.coordinate.latitude,
                zoom: zoom
            )
        }

        /// Keeps each model at its size as the zoom moves. Mapbox will not
        /// work a zoom-dependent scale out on this source, so the factor is
        /// written into the features — and only for the aeroplanes whose
        /// factor has changed: close in every model is real size, its factor
        /// is one at both zooms, and nothing is written. While the map is
        /// moving only those on screen are kept up; the rest are caught up
        /// when it rests.
        private func refreshModelScale(force: Bool) {
            guard isStyleLoaded, let map = map else { return }
            guard abs(zoom - scaleCheckedZoom) > 0.004 || (force && scaleStaleOffScreen) else { return }
            scaleCheckedZoom = zoom

            var features: [Feature] = []
            var skipped = false
            for id in modelled.keys {
                guard let marker = markers[id], trafficInSource.contains(id) else { continue }
                let scale = modelScale(for: marker)
                if let written = writtenScale[id], abs(scale / written - 1) < 0.003 { continue }
                if !force, !isInSmoothingBox(marker.coordinate) {
                    skipped = true
                    continue
                }
                features.append(trafficFeature(for: marker))
            }
            if force {
                scaleStaleOffScreen = false
            } else if skipped {
                scaleStaleOffScreen = true
            }
            if !features.isEmpty {
                map.updateGeoJSONSourceFeatures(forSourceId: Source.traffic, features: features)
            }
        }

        /// How high a model is flown, in metres above the ground: the
        /// simulator's own height for the aeroplane flown here, and the feed's
        /// for everything else.
        private func modelHeight(for marker: FlightMarker, at now: CFTimeInterval) -> Double {
            if let own = ownAttitude, own.flightId == marker.flightId, let height = own.heightMetres {
                return height
            }
            return marker.attitude.heightMetres(at: now)
        }

        /// The aeroplane being flown here, from Connect: its real pitch and
        /// bank rather than the ones worked out from the feed, written every
        /// frame they change. This is the one aircraft on the map that moves
        /// exactly as its pilot is flying it.
        private func stepOwnModel() {
            ownAttitude = MainActor.assumeIsolated {
                let telemetry = ConnectSession.shared.telemetry
                guard let id = telemetry.flightID, Date().timeIntervalSince(telemetry.sampledAt) < 5,
                      let pitch = telemetry.pitch, let bank = telemetry.bank,
                      pitch.isFinite, bank.isFinite else { return nil }
                let height = telemetry.altitudeAGL.flatMap { $0.isFinite ? max($0, 0) * 0.3048 : nil }
                return OwnAttitude(flightId: id, pitch: pitch, bank: bank, heightMetres: height)
            }
            guard let own = ownAttitude, own != writtenOwnAttitude,
                  let marker = markers[own.flightId], modelled[own.flightId] != nil,
                  trafficInSource.contains(own.flightId) else { return }
            writtenOwnAttitude = own
            map?.updateGeoJSONSourceFeatures(forSourceId: Source.traffic, features: [trafficFeature(for: marker)])
        }

        /// The open aircraft in the selection amber, and a highlighted pilot
        /// in their colour, mixed into the model's own paint.
        private func applyModelSelection(selectedId id: String, on map: MapboxMap) {
            guard map.layerExists(withId: Layer.trafficModels) else { return }
            let amber = MapLayerStyle.rgba(UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1))
            let isOpen: [Any] = ["==", ["get", "fid"], id]
            let colour: [Any] = ["case", isOpen, amber, ["has", "tint"], ["to-color", ["get", "tint"]], "#ffffff"]
            let mix: [Any] = ["case", isOpen, 0.55, ["has", "tint"], 0.45, 0.0]
            try? map.setLayerProperty(for: Layer.trafficModels, property: "model-color", value: colour)
            try? map.setLayerProperty(for: Layer.trafficModels, property: "model-color-mix-intensity", value: mix)
        }

        // MARK: Selection

        private var appliedSelectedId: String?

        /// The open aircraft is drawn by its own layers, over the rest of the
        /// traffic and in amber, and left out of the ordinary ones. All of that
        /// is filters on the same source, so opening a window rewrites four
        /// filters rather than a single feature.
        private func applySelectionFilters(force: Bool) {
            guard let map = map, isStyleLoaded else { return }
            let id = parent.selection?.id ?? ""
            guard force || appliedSelectedId != id else { return }
            appliedSelectedId = id

            let isOpen: [Any] = ["==", ["get", "fid"], id]
            let isNotOpen: [Any] = ["!=", ["get", "fid"], id]
            let hasSelectedMark: [Any] = ["has", "selectedMark"]
            let hasSelectedLabel: [Any] = ["has", "selectedLabel"]
            let hasMark: [Any] = ["has", "mark"]
            let hasLabel: [Any] = ["has", "label"]

            let filters: [(String, [Any])] = [
                (Layer.traffic, isNotOpen),
                (Layer.trafficMarks, ["all", hasMark, isNotOpen]),
                (Layer.trafficLabels, ["all", hasLabel, isNotOpen]),
                (Layer.selected, isOpen),
                (Layer.selectedMark, ["all", hasSelectedMark, isOpen]),
                (Layer.selectedLabel, ["all", hasSelectedLabel, isOpen]),
            ]
            for (layer, filter) in filters where map.layerExists(withId: layer) {
                try? map.setLayerProperty(for: layer, property: "filter", value: filter)
            }
            applyModelSelection(selectedId: id, on: map)
        }

        /// The open aircraft, without walking the server for it.
        private func selectedFlight() -> Flight? {
            guard let id = parent.selection?.id else { return nil }
            if let marker = markers[id] { return marker.flight }
            if let snapshot = selectedSnapshot, snapshot.id == id { return snapshot }
            return parent.flights.first { $0.id == id }
        }

        /// Where an aircraft is being *drawn*, which is what the camera and the
        /// buttons beside the window should be acting on.
        private func drawnCoordinate(for flight: Flight) -> CLLocationCoordinate2D {
            markers[flight.id]?.coordinate ?? flight.coordinate
        }

        // MARK: Taps

        /// What a tap meant: an aeroplane under the finger opens it, whatever
        /// else is going on — even mid-measurement, so tapping an aeroplane
        /// still opens the aeroplane. Otherwise the ruler takes the tap if it
        /// is down, then a field, and a tap on empty map closes the window.
        private func handleTap(at point: CGPoint, coordinate: CLLocationCoordinate2D) {
            guard let map = map, isStyleLoaded else { return }

            let box = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let trafficQuery = RenderedQueryOptions(layerIds: MapLayerStyle.tappableTraffic, filter: nil)

            _ = map.queryRenderedFeatures(with: box, options: trafficQuery) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let hits = (try? result.get()) ?? []
                    if let id = self.nearest(hits, to: point, property: "fid") {
                        // The replay's aircraft is not a selection of its own.
                        guard self.markers[id] != nil || self.parent.flights.contains(where: { $0.id == id }) else { return }
                        self.parent.selection = SelectedFlight(id: id)
                        return
                    }
                    self.handleGroundTap(at: point, box: box, coordinate: coordinate)
                }
            }
        }

        private func handleGroundTap(at point: CGPoint, box: CGRect, coordinate: CLLocationCoordinate2D) {
            if parent.measurement.isOn {
                guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }
                parent.measurement.add(coordinate)
                return
            }

            guard let map = map else { return }
            let fieldQuery = RenderedQueryOptions(layerIds: MapLayerStyle.tappableFields, filter: nil)
            _ = map.queryRenderedFeatures(with: box, options: fieldQuery) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let hits = (try? result.get()) ?? []
                    if let icao = self.nearest(hits, to: point, property: "icao") {
                        self.parent.onSelectAirport(icao)
                        return
                    }
                    // Empty map: the window closes, the way tapping away from a
                    // selected marker always has.
                    if self.parent.selection != nil {
                        self.parent.selection = nil
                    }
                }
            }
        }

        /// The feature among `hits` closest to the finger, by one property.
        private func nearest(_ hits: [QueriedRenderedFeature], to point: CGPoint, property: String) -> String? {
            var best: (String, CGFloat)?
            for hit in hits {
                let feature = hit.queriedFeature.feature
                guard case .string(let value)? = feature.properties?[property] ?? nil else { continue }
                var distance: CGFloat = 0
                if case .point(let position)? = feature.geometry, let map = map {
                    let projected = map.point(for: position.coordinates)
                    distance = hypot(projected.x - point.x, projected.y - point.y)
                }
                if best == nil || distance < best!.1 { best = (value, distance) }
            }
            return best?.0
        }

        // MARK: Airports

        private struct AirportSyncKey: Equatable {
            let revision: Int
            let conditions: Bool
            let weather: Int
            let windUnit: String
            let temperatureUnit: String
            let prefetchCell: String
        }

        private var renderedAirportKey: AirportSyncKey?

        /// The fields, all of them — Mapbox draws a few hundred symbols for
        /// nothing, so they are no longer culled to the viewport. What still is
        /// is the weather behind their colours: only the fields near the
        /// screen are asked for a report.
        private func syncAirports(on map: MapboxMap) {
            let airports = parent.airports
            guard !airports.isEmpty else {
                if renderedAirportKey != nil {
                    clear(Source.fields)
                    renderedAirportKey = nil
                }
                return
            }

            guard let region = region, region.isUsable else { return }

            // Nothing about the camera is worth rebuilding the fields for while
            // it is still moving: SwiftUI redraws through a pinch for reasons
            // of its own — a radar frame, a replay tick — and each would
            // otherwise rewrite every marker for a zoom the finger has already
            // left. The settle runs this again. A new list of fields does not
            // wait: that is data, not camera.
            if isRegionChanging, renderedAirportKey?.revision == parent.airportsRevision { return }

            // Wind and temperature under the code, but only once the map is
            // near enough that a marker has room for a second line.
            let conditions = parent.showsFieldConditions
                && region.span.latitudeDelta <= Self.fieldConditionSpanDegrees

            // Which fields to ask the weather about: the ones near the screen,
            // and only re-asked when the view has moved by a good part of
            // itself.
            let cell = String(
                format: "%.0f|%.0f|%.0f",
                region.center.latitude / max(region.span.latitudeDelta / 3, 0.01),
                region.center.longitude / max(region.span.longitudeDelta / 3, 0.01),
                log2(max(region.span.latitudeDelta, 0.0001))
            )

            let preferences = WeatherPreferences.shared
            let key = AirportSyncKey(
                revision: parent.airportsRevision,
                conditions: conditions,
                weather: WeatherService.shared.generation,
                windUnit: preferences.windUnit.rawValue,
                temperatureUnit: preferences.temperatureUnit.rawValue,
                prefetchCell: cell
            )
            guard key != renderedAirportKey else { return }
            renderedAirportKey = key

            let latitudeMargin = region.span.latitudeDelta * AppConfig.flightAddMargin
            let longitudeMargin = region.span.longitudeDelta * AppConfig.flightAddMargin
            var nearby: [String] = []

            var features: [Feature] = []
            features.reserveCapacity(airports.count)

            for field in airports {
                let airport = field.airport
                let coordinate = airport.coordinate
                let isNear = abs(coordinate.latitude - region.center.latitude) <= latitudeMargin
                    && Self.longitudeDelta(coordinate.longitude, region.center.longitude) <= longitudeMargin
                if isNear { nearby.append(airport.icao) }

                let report = WeatherService.shared.cached(airport.icao)
                let category = report.map { MapLayerStyle.rgba($0.flightCategory.colour) } ?? "#ffffff"
                let line = (conditions && isNear) ? report.map(AirportMarker.conditionsLine(for:)) ?? "" : ""

                features.append(Self.pointFeature(coordinate, id: airport.icao, [
                    "icao": .string(airport.icao),
                    "icon": .string(Self.fieldImage(isControlled: field.isControlled)),
                    "category": .string(category),
                    "conditions": .string(line.isEmpty ? "" : "\n" + line),
                    // A staffed field is the one you would go looking for, so
                    // it gets full strength and first claim on the space.
                    "alpha": .number(field.isControlled ? 1 : 0.72),
                    "rank": .number(field.isControlled ? 0 : 1),
                ]))
            }

            // The reports behind the colours, for the fields being looked at
            // and no others.
            WeatherService.shared.prefetch(nearby)

            push(features, to: Source.fields)
        }

        /// How wide the view may be, in degrees of latitude, before a field's
        /// conditions stop being drawn under its code. About four hundred
        /// miles — a country rather than a continent.
        static let fieldConditionSpanDegrees: Double = 6

        /// Shortest angular distance between two longitudes.
        private static func longitudeDelta(_ lhs: Double, _ rhs: Double) -> Double {
            let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
            return delta > 180 ? 360 - delta : delta
        }

        // MARK: Route

        private var renderedRouteKey: String?

        /// The drawn track, kept so its live head can grow from where it ends.
        private var flownTail: (coordinate: CLLocationCoordinate2D, color: UIColor)?

        /// How far to a field a slow sample has to be for that field's pavement
        /// to be worth fetching, so the flown path can be matched to it.
        private static let taxiFieldRadiusNM: Double = 4

        /// Draws the selected aircraft's path: the track we have actually
        /// watched it fly, plus dashed legs for the parts we can only infer.
        private func syncRoute(on map: MapboxMap) {
            guard let flight = selectedFlight() else {
                clearRoute()
                return
            }

            // Where the aircraft was before we were watching. Asked for here as
            // well as by the window, and first: this runs on the map's very
            // next pass after the aeroplane is tapped.
            FlightHistoryService.shared.ensureHistory(for: flight.id)

            let trail = FlightTrailStore.shared.points(for: flight.id)

            // Read before the key is built, because asking is also what starts
            // the fetch.
            let plan = parent.showsFlightPlan
                ? FlightPlanStore.shared.waypoints(for: flight.id)
                : []

            // Which fix the aeroplane is actually flying to. See
            // `PlanProgress` — the one place that decides it.
            let nextFix = PlanProgress.next(in: plan, from: flight.coordinate)?.waypoint.index

            let taxiways = groundNetworks(for: flight, along: trail)

            let planKey: String = parent.showsFlightPlan ? String(plan.count) : "off"
            let namesKey: String = parent.showsPlanNames ? "names" : "nonames"
            let nextFixKey: String = nextFix?.description ?? "-"
            let schemeKey: String = isLight ? "light" : "dark"
            let pathKey: String = parent.showsFlownPath ? "path" : "nopath"
            let airKey: String = isAirPathOn ? "air" : "flat"
            let taxiKey: String = taxiways.map { "\($0.icao)/\($0.edgeCount)" }.joined(separator: "+")

            let parts: [String] = [
                flight.id,
                String(trail.count),
                String(parent.trailRevision),
                String(AltitudeBand.band(forFeet: flight.altitudeFeet)),
                flight.departureIcao ?? "",
                flight.arrivalIcao ?? "",
                planKey,
                namesKey,
                nextFixKey,
                pathKey,
                taxiKey,
                schemeKey,
                airKey,
            ]
            let key = parts.joined(separator: "|")

            guard key != renderedRouteKey else { return }
            renderedRouteKey = key

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

            // The filed plan, joined by great circles.
            if plan.count >= 2 {
                push([Self.lineFeature(GreatCircle.path(through: plan.map(\.coordinate)))], to: Source.plan)
            } else {
                clear(Source.plan)
            }

            flownTail = nil
            airRuns = []
            airTailHeight = nil
            var inferred: [Feature] = []
            var runs: [Feature] = []

            if parent.showsFlownPath {
                // On the ground, the track goes the way the concrete goes. See
                // `GroundTrack`.
                let drawn = GroundTrack.following(flown, on: taxiways)

                let bands = FlownPath.heightBands(of: drawn.points)

                // Beside the 3D aircraft the path is drawn at the heights it
                // was flown at — see `FlownPathProfile`.
                var heights: [Double] = []
                if isAirPathOn {
                    let profile = FlownPathProfile.heights(of: drawn.points, bands: bands)
                    heights = profile.heights
                    if let ground = profile.groundFeet { markers[flight.id]?.adoptGroundAltitude(ground) }
                }

                if let path = FlownPath(
                    points: drawn.points,
                    bands: bands,
                    onPavement: drawn.onPavement,
                    heights: heights
                ) {
                    for (index, run) in path.runs.enumerated() {
                        let feature = Self.lineFeature(run.coordinates, id: "run-\(index)", [
                            "color": .string(MapLayerStyle.rgba(run.color)),
                            "halo": .string(MapLayerStyle.rgba(FlownPathStyle.halo(for: run.color))),
                        ])
                        runs.append(feature)
                        if !run.heights.isEmpty {
                            airRuns.append(AirRun(
                                feature: feature,
                                profile: FlownPathProfile.resampled(run.coordinates, heights: run.heights)
                            ))
                        }
                    }
                    flownTail = (path.tail, path.tailColor)
                    airTailHeight = path.tailHeight
                }

                // Before we were watching: departure to the first point we
                // have. A guess, and drawn like one.
                if let departure = AirportStore.shared.airport(flight.departureIcao),
                   let first = flown.first,
                   FlightProgress.distanceNM(from: departure.coordinate, to: first.coordinate) > 1 {
                    inferred.append(Self.lineFeature(GreatCircle.arc(from: departure.coordinate, to: first.coordinate)))
                }
            }

            if !airRuns.isEmpty {
                runs = liftedAirRuns()
            }
            push(runs, to: Source.flown)
            push(inferred, to: Source.inferred)
            flownHeadWritten = nil
            if flownTail == nil { clear(Source.flownHead) }

            // The fixes, with the one being flown to picked out and the ones
            // behind the wing dimmed.
            var fixes: [Feature] = []
            for fix in plan {
                let isNext = fix.index == nextFix
                let isPassed = nextFix.map { fix.index < $0 } ?? false
                let colour = MapLayerStyle.rgba(isNext ? PlanStyle.nextFix : PlanStyle.fix, isLight: isLight)
                fixes.append(Self.pointFeature(fix.coordinate, [
                    "icon": .string(Self.fixImage(isNext: isNext, isLight: isLight)),
                    "name": .string(parent.showsPlanNames ? fix.name : ""),
                    "color": .string(colour),
                    "alpha": .number(isPassed ? Double(PlanStyle.passedOpacity) : 1),
                    "rank": .number(isNext ? 0 : 1),
                ]))
            }
            push(fixes, to: Source.fixes)

            syncDirectLine()
        }

        private func clearRoute() {
            guard renderedRouteKey != nil || flownTail != nil || directDestination != nil else { return }
            renderedRouteKey = nil
            flownTail = nil
            flownHeadWritten = nil
            airRuns = []
            airTailHeight = nil
            for source in [Source.plan, Source.flown, Source.flownHead, Source.inferred, Source.fixes] {
                clear(source)
            }
            clearDirectLine()
        }

        /// The fields whose taxiways this track needs, and their graphs. Only
        /// asked about when the track has a ground part at a field at all.
        private func groundNetworks(for flight: Flight, along trail: [TrackPoint]) -> [TaxiNetwork] {
            guard parent.showsFlownPath else { return [] }

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
                // Asked for off the update pass rather than inside it: `load`
                // publishes, and publishing from inside a SwiftUI update is the
                // warning SwiftUI exists to give.
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

        // MARK: The live ends of the route

        /// Where the flown path's head was last written to, so it is rewritten
        /// only when the aeroplane has visibly moved off it.
        private var flownHeadWritten: CLLocationCoordinate2D?

        /// Grows the flown path to wherever the open aircraft is drawn.
        ///
        /// The track ends at the newest breadcrumb, and breadcrumbs are two
        /// nautical miles apart at best — so the aeroplane spends most of its
        /// time flying off the end of its own path. This is one short segment
        /// from the last breadcrumb to the aeroplane, rewritten on the frame
        /// clock, so the two travel together.
        private func updateFlownHead() {
            guard let tail = flownTail,
                  let id = parent.selection?.id,
                  let marker = markers[id]
            else {
                if flownHeadWritten != nil {
                    flownHeadWritten = nil
                    clear(Source.flownHead)
                }
                return
            }

            let head = marker.coordinate

            // In the air, from where the path ends to where the model is
            // drawn, so the two stay joined.
            var elevation: [Double]?
            if isAirPathOn, let tailHeight = airTailHeight {
                let start = AircraftModelStyle.drawnLift(heightMetres: tailHeight)
                let end = AircraftModelStyle.drawnLift(heightMetres: modelHeight(for: marker, at: CACurrentMediaTime()))
                elevation = [(start * 10).rounded() / 10, (end * 10).rounded() / 10]
            }

            if let written = flownHeadWritten,
               FlightMotion.pointsApart(written, head, pointsPerMetre: pointsPerMetre) < 0.2,
               !Self.elevationMoved(from: flownHeadElevation, to: elevation) {
                return
            }
            flownHeadWritten = head
            flownHeadElevation = elevation

            let end = GreatCircle.unwrapped(head, after: tail.coordinate)
            var properties: JSONObject = [
                "color": .string(MapLayerStyle.rgba(tail.color)),
                "halo": .string(MapLayerStyle.rgba(FlownPathStyle.halo(for: tail.color))),
            ]
            if let elevation {
                properties["elevation"] = .array(elevation.map { JSONValue.number($0) })
            }
            push([Self.lineFeature([tail.coordinate, end], properties)], to: Source.flownHead)
        }

        /// The heights the head was last written with.
        private var flownHeadElevation: [Double]?

        /// Whether either end of the head has moved up or down by enough to
        /// be worth a rewrite: a metre, or half a percent of the height.
        private static func elevationMoved(from old: [Double]?, to new: [Double]?) -> Bool {
            guard let old, let new, old.count == new.count else { return old != new }
            return zip(old, new).contains { abs($0 - $1) > max(1, abs($0) * 0.005) }
        }

        // MARK: The path in the air

        /// Whether the flown path is drawn at its heights: with the 3D
        /// aircraft, and on the flat map — Mapbox lifts lines off a flat map
        /// only.
        private var isAirPathOn: Bool {
            parent.aircraftModels != .off && parent.style.projection != .globe
        }

        private var appliedAirPath: Bool?

        /// One run of the path, as written to the map without its heights,
        /// and its heights sampled evenly along it, before the cap.
        private struct AirRun {
            let feature: Feature
            let profile: [Double]
        }

        private var airRuns: [AirRun] = []
        private var airTailHeight: Double?

        private func applyAirPathLayers() {
            guard let map = map, isStyleLoaded else { return }
            let isOn = isAirPathOn
            guard isOn != appliedAirPath else { return }
            appliedAirPath = isOn
            MapLayerStyle.applyAirPath(isOn, on: map)
        }

        private func liftedAirRuns() -> [Feature] {
            airRuns.map { run in
                var feature = run.feature
                var properties = feature.properties ?? [:]
                properties["elevation"] = .array(FlownPathProfile.lifted(run.profile).map { JSONValue.number($0) })
                feature.properties = properties
                return feature
            }
        }

        // MARK: The sky

        private var appliedSky: SkyStyle.Palette?
        private var skyCheckedAt: CFTimeInterval = 0

        /// The real sky over wherever the map is looking — see `SkyStyle`.
        /// Looked at every few seconds and on every settle; written only when
        /// it has changed by enough to see.
        private func refreshSky(force: Bool) {
            guard let map = map, isStyleLoaded else { return }
            let now = CACurrentMediaTime()
            guard force || now - skyCheckedAt > 5 else { return }
            skyCheckedAt = now
            let palette = SkyStyle.palette(at: map.cameraState.center, isLight: isLight)
            if let applied = appliedSky, !Self.skyMoved(from: applied, to: palette) { return }
            appliedSky = palette
            try? map.setAtmosphere(properties: SkyStyle.atmosphere(palette))
        }

        private static func skyMoved(from old: SkyStyle.Palette, to new: SkyStyle.Palette) -> Bool {
            func apart(_ a: SkyStyle.RGB, _ b: SkyStyle.RGB) -> Double {
                max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
            }
            return apart(old.horizon, new.horizon) > 2 || apart(old.high, new.high) > 2
                || apart(old.space, new.space) > 2 || abs(old.stars - new.stars) > 0.02
        }

        /// The line from the open aircraft to where it is going, and what it
        /// was last drawn from.
        private var directOrigin: CLLocationCoordinate2D?
        private var directDestination: CLLocationCoordinate2D?
        private var directDrawnAt: CFTimeInterval = 0

        /// How far the aeroplane has to have moved, on screen, before the line
        /// ahead of it is redrawn, and how often that may happen at most.
        private static let directStep: Double = 1
        private static let directInterval: CFTimeInterval = 1.0 / 12

        /// Draws the line from the open aircraft to its destination, and keeps
        /// it under the aeroplane as it flies.
        private func syncDirectLine() {
            guard parent.showsDirectLine else {
                clearDirectLine()
                return
            }

            let now = CACurrentMediaTime()
            if directDestination != nil, now - directDrawnAt < Self.directInterval { return }
            directDrawnAt = now

            guard let flight = selectedFlight(),
                  let arrival = AirportStore.shared.airport(flight.arrivalIcao)
            else {
                clearDirectLine()
                return
            }

            let origin = drawnCoordinate(for: flight)
            let destination = arrival.coordinate

            if let anchor = directOrigin,
               let previous = directDestination,
               previous.latitude == destination.latitude,
               previous.longitude == destination.longitude {
                guard pointsPerMetre > 0 else { return }
                guard FlightMotion.pointsApart(anchor, origin, pointsPerMetre: pointsPerMetre) >= Self.directStep else {
                    return
                }
            }

            push([Self.lineFeature(GreatCircle.arc(from: origin, to: destination))], to: Source.direct)
            directOrigin = origin
            directDestination = destination
        }

        private func clearDirectLine() {
            guard directDestination != nil else { return }
            clear(Source.direct)
            directOrigin = nil
            directDestination = nil
        }

        // MARK: Weather

        private let weatherLayer = WeatherTileLayer()

        /// Swaps the weather tiles when the frame changes, and takes them away
        /// when the layer goes off. Not while the camera is moving: a frame of
        /// the radar animation is worth the wait, and the settle calls this
        /// again.
        private func syncWeatherTiles(on map: MapboxMap) {
            let wanted = parent.weatherTiles
            if wanted != nil, isRegionChanging { return }
            weatherLayer.show(wanted, on: map)
        }

        /// The barbs, the coloured field and the moving air — all three off one
        /// grid, and all three switched by their own settings.
        private var renderedWindKey: String?
        private var windRequest: (latitude: Double, longitude: Double, span: Double, demand: String)?
        private var windRequestedAt = Date.distantPast
        private static let windRefreshInterval: TimeInterval = 20

        private func syncWinds(on map: MapboxMap) {
            let wantsBarbs = parent.showsWinds
            let wantsParticles = parent.showsWindParticles
            let wantsHeat = parent.windHeat != .off

            guard wantsBarbs || wantsParticles || wantsHeat else {
                clearWinds(on: map)
                WindsAloftStore.shared.clear()
                return
            }

            let store = WindsAloftStore.shared

            let demand = WindsAloftStore.Demand(
                level: parent.windLevel,
                needsField: wantsParticles || wantsHeat,
                needsTemperature: parent.windHeat == .temperature,
                needsShear: parent.windHeat == .shear
            )

            guard let region = region, region.isUsable else { return }
            let here = (
                latitude: region.center.latitude,
                longitude: region.center.longitude,
                span: region.span.latitudeDelta,
                demand: demand.key
            )
            let now = Date()
            let moved = windRequest.map { $0 != here } ?? true
            let stale = now.timeIntervalSince(windRequestedAt) >= Self.windRefreshInterval

            // Nothing is asked for while the camera is moving; the settle runs
            // this again.
            if !isRegionChanging, moved || stale {
                windRequest = here
                windRequestedAt = now
                store.load(region: region, demand: demand)
            }

            guard !isRegionChanging else { return }

            let wanted = [
                store.key ?? "-",
                parent.windHeat.rawValue,
                wantsBarbs ? "b" : "-",
                wantsParticles ? "p" : "-",
                isLight ? "light" : "dark",
            ].joined(separator: "|")
            guard renderedWindKey != wanted else { return }
            renderedWindKey = wanted

            syncWindBarbs(wanted: wantsBarbs, store: store)
            syncWindHeat(on: map, store: store)
            syncWindParticles(on: map, wanted: wantsParticles, store: store)
        }

        private func syncWindBarbs(wanted: Bool, store: WindsAloftStore) {
            guard wanted, !store.barbs.isEmpty else {
                clear(Source.barbs)
                return
            }
            let features = store.barbs.map { barb -> Feature in
                let knots = WindBarbGlyph.bucket(forKnots: barb.speedKnots)
                return Self.pointFeature(barb.coordinate, [
                    "icon": .string(barbImage(knots: knots, isLight: isLight)),
                    "direction": .number(barb.directionDegrees.isFinite ? barb.directionDegrees : 0),
                ])
            }
            push(features, to: Source.barbs)
        }

        // The coloured wash.

        private var heatKey: String?
        private var heatInstalled = false

        private func syncWindHeat(on map: MapboxMap, store: WindsAloftStore) {
            let product = parent.windHeat
            let key = "\(store.key ?? "-")|\(product.rawValue)"
            guard heatKey != key else { return }
            heatKey = key

            guard product != .off,
                  let field = store.field,
                  let raster = WeatherHeatRaster(field: field, product: product, level: parent.windLevel)
            else {
                MapLayerStyle.setVisible(false, layers: [Layer.heat], on: map)
                return
            }

            // Under the moving air and the night: a tint on the cartography,
            // with everything the app draws belonging over it.
            let below = map.layerExists(withId: Layer.particles) ? Layer.particles : Layer.night
            guard installImageRaster(
                source: Source.heat,
                layer: Layer.heat,
                below: below,
                corners: raster.corners,
                installed: &heatInstalled,
                on: map
            ) else { return }

            try? map.updateImageSource(withId: Source.heat, image: raster.image)
            MapLayerStyle.setVisible(true, layers: [Layer.heat], on: map)
        }

        /// Puts an image source and its raster layer on the map, once, and
        /// pins the picture to its corners every time.
        private func installImageRaster(
            source: String,
            layer: String,
            below: String,
            corners: [[Double]],
            installed: inout Bool,
            on map: MapboxMap
        ) -> Bool {
            if installed, map.sourceExists(withId: source) {
                try? map.setSourceProperty(for: source, property: "coordinates", value: corners)
                return true
            }

            guard let placeholder = Self.clearImageURL else { return false }
            let properties: [String: Any] = [
                "type": "image",
                "url": placeholder.absoluteString,
                "coordinates": corners,
            ]
            do {
                try map.addSource(withId: source, properties: properties)
            } catch {
                NSLog("[Map] image source %@ could not be added: %@", source, String(describing: error))
                return false
            }

            let definition: [String: Any] = [
                "id": layer,
                "type": "raster",
                "source": source,
                "slot": "middle",
                "paint": [
                    "raster-opacity": 1,
                    "raster-fade-duration": 0,
                    "raster-resampling": "linear",
                ] as [String: Any],
            ]
            do {
                try map.addLayer(with: MapLayerStyle.selfLit(definition), layerPosition: MapLayerStyle.position(below: below, on: map))
            } catch {
                NSLog("[Map] raster layer %@ could not be added: %@", layer, String(describing: error))
                try? map.removeSource(withId: source)
                return false
            }

            installed = true
            return true
        }

        /// A one-pixel transparent picture on disk, which is what an image
        /// source is created pointing at before its real picture is handed
        /// over in memory.
        private static let clearImageURL: URL? = {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("inflight-clear.png")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
            guard let data = image.pngData(), (try? data.write(to: url)) != nil else { return nil }
            return url
        }()

        // The moving air.

        private var particles: WindParticles?
        private var particleKey: String?
        private var particlesInstalled = false
        private var lastParticleStep: CFTimeInterval = 0
        private var particleRenderInFlight = false
        private let particleQueue = DispatchQueue(label: "com.tracker.Inflight.particles", qos: .userInitiated)

        /// Reseeded wholesale on a new grid rather than carried across: a
        /// particle drifting on last lattice's numbers is drifting on numbers
        /// that are no longer on screen.
        private func syncWindParticles(on map: MapboxMap, wanted: Bool, store: WindsAloftStore) {
            let key = wanted ? (store.key ?? "-") : "off"
            guard particleKey != key else { return }
            particleKey = key

            guard wanted, let field = store.field, let grid = WindVelocityGrid(field: field),
                  let mapView = mapView
            else {
                particles = nil
                MapLayerStyle.setVisible(false, layers: [Layer.particles], on: map)
                return
            }

            let simulation = WindParticles()
            let bounds = mapView.bounds
            simulation.adopt(
                field: grid,
                visible: visibleMercatorRect(),
                screenArea: Double(bounds.width * bounds.height)
            )
            simulation.look(at: visibleMercatorRect(), latitude: region?.center.latitude ?? 0)
            particles = simulation
        }

        private func clearWinds(on map: MapboxMap) {
            guard renderedWindKey != nil || particles != nil || heatKey != nil else { return }
            clear(Source.barbs)
            MapLayerStyle.setVisible(false, layers: [Layer.heat, Layer.particles], on: map)
            particles = nil
            renderedWindKey = nil
            heatKey = nil
            particleKey = nil
            windRequest = nil
        }

        /// One step of the wind field, and a fresh picture of it, from the
        /// map's own frame clock — twenty-four a second whatever the screen is
        /// doing. The picture is drawn off the main thread, and a step whose
        /// last picture has not landed yet does not ask for another.
        private func stepWindParticles(at now: CFTimeInterval) {
            guard let simulation = particles, let map = map, let mapView = mapView else { return }

            let interval = 1 / WindParticleStyle.stepsPerSecond
            let elapsed = now - lastParticleStep
            guard elapsed >= interval else { return }
            lastParticleStep = now

            // Coming back from the background hands us however long the app was
            // away. A step of the ordinary size picks up where it left off.
            simulation.step(min(elapsed, interval * 3))

            guard !particleRenderInFlight, let snapshot = simulation.snapshot() else { return }

            let visible = visibleMercatorRect()
            let area = visible.intersection(snapshot.rect)
            guard !area.isNull, area.width > 0, area.height > 0, visible.width > 0, visible.height > 0 else { return }

            // The picture covers the part of the field on screen, at about one
            // pixel per point of it.
            let bounds = mapView.bounds
            var size = CGSize(
                width: CGFloat(area.width / visible.width) * bounds.width,
                height: CGFloat(area.height / visible.height) * bounds.height
            )
            let longest = max(size.width, size.height)
            if longest > 1024 {
                size = CGSize(width: size.width * 1024 / longest, height: size.height * 1024 / longest)
            }
            size = CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))

            let topLeft = MercatorPoint(x: area.minX, y: area.minY).coordinate
            let bottomRight = MercatorPoint(x: area.maxX, y: area.maxY).coordinate
            let west = area.minX / MercatorRect.worldSide * 360 - 180
            let east = area.maxX / MercatorRect.worldSide * 360 - 180
            let corners: [[Double]] = [
                [west, topLeft.latitude],
                [east, topLeft.latitude],
                [east, bottomRight.latitude],
                [west, bottomRight.latitude],
            ]

            let colour = WindParticleStyle.colour(for: parent.colorScheme)
            particleRenderInFlight = true

            particleQueue.async { [weak self] in
                let image = WindParticleRaster.image(of: snapshot, in: area, size: size, colour: colour)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.particleRenderInFlight = false
                    guard self.particles === simulation, let image = image else { return }
                    guard self.installImageRaster(
                        source: Source.particles,
                        layer: Layer.particles,
                        below: Layer.night,
                        corners: corners,
                        installed: &self.particlesInstalled,
                        on: map
                    ) else { return }
                    try? map.updateImageSource(withId: Source.particles, image: image)
                    MapLayerStyle.setVisible(true, layers: [Layer.particles], on: map)
                }
            }
        }

        // MARK: The ruler

        private var renderedMeasureKey: String?

        private func syncMeasurement(on map: MapboxMap) {
            let measurement = parent.measurement
            let key = measurement.isOn
                ? [measurement.start, measurement.end]
                    .map { $0.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "-" }
                    .joined(separator: "|")
                : "off"

            guard renderedMeasureKey != key else { return }
            renderedMeasureKey = key

            guard measurement.isOn else {
                clear(Source.measure)
                return
            }

            var features: [Feature] = []
            if let start = measurement.start, let end = measurement.end {
                // Geodesic, because the number in the readout is a great-circle
                // distance and a straight line would be measuring something else.
                features.append(Self.lineFeature(GreatCircle.arc(from: start, to: end, stepMetres: 20_000)))
            }
            if let start = measurement.start {
                features.append(Self.pointFeature(start, ["letter": .string("A")]))
            }
            if let end = measurement.end {
                features.append(Self.pointFeature(end, ["letter": .string("B")]))
            }
            push(features, to: Source.measure)
        }

        // MARK: Night

        private var terminatorDrawnAt: Date?
        private var terminatorShown = false

        /// How stale the shape may get. The terminator sweeps a quarter of a
        /// degree a minute, so two minutes is half a degree — invisible at any
        /// zoom that shows a whole continent.
        private static let terminatorLifetime: TimeInterval = 120

        private func syncTerminator(on map: MapboxMap) {
            guard parent.showsTerminator else {
                if terminatorShown {
                    clear(Source.night)
                    terminatorShown = false
                }
                terminatorDrawnAt = nil
                return
            }

            if let drawn = terminatorDrawnAt,
               Date().timeIntervalSince(drawn) < Self.terminatorLifetime {
                return
            }
            terminatorDrawnAt = Date()

            let light = isLight
            let features = Terminator.bands().map { band -> Feature in
                let rings = band.hole.isEmpty ? [band.outer] : [band.outer, band.hole]
                return Self.polygonFeature(rings, [
                    "color": .string(MapLayerStyle.rgba(Terminator.fill(atIndex: band.index, isLight: light))),
                ])
            }
            push(features, to: Source.night)
            terminatorShown = true
        }

        // MARK: The organised tracks

        private var renderedNatKey: String?

        private func syncNatTracks(on map: MapboxMap) {
            guard parent.showsNatTracks else {
                if renderedNatKey != nil {
                    clear(Source.nat)
                    renderedNatKey = nil
                }
                return
            }

            let service = NatTrackService.shared
            service.refresh()

            let tracks = service.tracks
            let key = tracks.map { "\($0.name)|\($0.coordinates.count)" }.joined(separator: ",")
            guard renderedNatKey != key else { return }
            renderedNatKey = key

            var features: [Feature] = []
            for track in tracks {
                let colour = MapLayerStyle.rgba(NatTrackStyle.colour(for: track.name).withAlphaComponent(0.75))
                // Great circles, because a track is flown as one and a straight
                // line between two North Atlantic fixes is visibly south of
                // where the aeroplanes actually are.
                features.append(Self.lineFeature(GreatCircle.path(through: track.coordinates), [
                    "color": .string(colour),
                ]))

                // Named at both ends, because which end you are looking at
                // depends entirely on which side of the ocean you are.
                let text = NatTrackStyle.label(for: track)
                if let first = track.coordinates.first {
                    features.append(Self.pointFeature(first, ["label": .string(text)]))
                }
                if let last = track.coordinates.last, track.coordinates.count > 1 {
                    features.append(Self.pointFeature(last, ["label": .string(text)]))
                }
            }
            push(features, to: Source.nat)
        }

        // MARK: Controlled airspace

        private var renderedAtcKey: String?

        /// Draws the airspace of every sector somebody is working. Keyed on
        /// the stations, so a packet that changes nothing about who is on
        /// frequency costs one string comparison.
        private func syncAtcBoundaries(on map: MapboxMap) {
            guard parent.showsAtcBoundaries else {
                if renderedAtcKey != nil {
                    clear(Source.atc)
                    renderedAtcKey = nil
                }
                return
            }

            let centres = parent.atcStations.filter(\.isCenter)
            let key = centres
                .map { "\($0.identifier)/\($0.facilities.count)" }
                .sorted()
                .joined(separator: ",")

            guard renderedAtcKey != key else { return }
            renderedAtcKey = key

            guard !centres.isEmpty else {
                clear(Source.atc)
                return
            }

            var features: [Feature] = []
            for active in AtcBoundaryStore.shared.activeSectors(for: centres) {
                for ring in active.sector.rings where ring.count >= 3 {
                    features.append(Self.polygonFeature([ring], ["sector": .string(active.sector.id)]))
                }
                features.append(Self.pointFeature(active.sector.label, ["label": .string(active.label)]))
            }
            push(features, to: Source.atc)
        }

        // MARK: Ground layout

        /// How wide the view has to be, in nautical miles, before a field's
        /// pavement is worth drawing — and, wider, before pavement already
        /// drawn is taken away. Two limits, so a zoom that hovers near one
        /// does not rebuild the field on every settle.
        private static let groundSpanNM: Double = 9
        private static let groundKeepSpanNM: Double = 13

        private var renderedGroundIcao: String?
        private var renderedGroundKey: String?

        /// Draws the pavement of whichever field the map is sitting over.
        private func syncGround(on map: MapboxMap) {
            guard parent.showsGroundLayout else {
                clearGround()
                return
            }

            // Everything past here is a question about the region, so it waits
            // for the map to stop.
            guard !isRegionChanging, let region = region, region.isUsable else { return }

            let spanNM = region.span.latitudeDelta * 60
            let isDrawn = renderedGroundIcao != nil
            let limit = isDrawn ? Self.groundKeepSpanNM : Self.groundSpanNM
            guard spanNM <= limit else {
                clearGround()
                return
            }

            // The near search picks a field; the wide one only ever confirms
            // the one already drawn.
            let near = AirportStore.shared.nearestAirport(to: region.center, withinNM: Self.groundSpanNM)
            var held: Airport? = nil
            if near == nil, isDrawn,
               let wider = AirportStore.shared.nearestAirport(to: region.center, withinNM: Self.groundKeepSpanNM),
               wider.icao == renderedGroundIcao {
                held = wider
            }

            guard let field = near ?? held else {
                clearGround()
                return
            }

            let store = AirportLayoutStore.shared
            store.load(field)

            guard let layout = store.layout(for: field.icao), !layout.isEmpty else { return }

            let ground = AirportGroundStyle.Ground(parent.style, isLight: isLight)
            let key = "\(layout.icao)|\(ground)"
            guard renderedGroundKey != key else { return }
            renderedGroundKey = key
            renderedGroundIcao = layout.icao

            push(GroundLayoutFeatures.features(for: layout, on: ground, latitude: field.coordinate.latitude), to: Source.ground)
        }

        private func clearGround() {
            guard renderedGroundIcao != nil else { return }
            clear(Source.ground)
            renderedGroundIcao = nil
            renderedGroundKey = nil
        }

        // MARK: Replay

        private var renderedReplay = false

        /// The aircraft the replay is drawing, rewritten each frame of the
        /// playback — one feature in a source of its own, which is about the
        /// cheapest thing a map can be asked to move.
        private func syncReplay(on map: MapboxMap) {
            guard let frame = parent.replayFrame else {
                if renderedReplay {
                    clear(Source.replay)
                    renderedReplay = false
                }
                return
            }

            // The replayed aircraft is the open one; the sprite survives the
            // flight dropping out of the feed part way through a playback.
            let key = selectedFlight()?.spriteKey ?? replaySpriteKey ?? "TRIANGLE"
            replaySpriteKey = key

            let icon = planeImage(key: key, tint: nil, selected: true)
            push([Self.pointFeature(frame.coordinate, [
                "icon": .string(icon),
                "heading": .number(frame.heading),
            ])], to: Source.replay)
            renderedReplay = true

            keepInView(frame.coordinate)
        }

        private var replaySpriteKey: String?

        // MARK: Following

        /// The aircraft the camera is locked to, and when the glide onto it
        /// lands.
        private var followLockedId: String?
        private var followGlideEnds: CFTimeInterval = 0
        private var followNeedsGlide = false

        /// Whether a pinch, a rotation or a tilt is under way, which the
        /// follow stands back for rather than fighting.
        private var isGestureActive = false

        private static let followGlide: CFTimeInterval = 0.8

        /// Keeps the camera on the open aircraft as it flies, while follow is
        /// on.
        ///
        /// It glides onto the aeroplane — aimed where the aeroplane will be
        /// when the glide lands, not where it was when it started — and from
        /// then on moves with it every frame. The position it moves to is the
        /// one the aeroplane is drawn at, which is already smoothed between
        /// packets, so the map slides along with the aeroplane rather than
        /// waiting for it to drift off centre and hopping after it.
        private func followSelection() {
            guard parent.isFollowing, let flight = selectedFlight(), let mapView = mapView, let map = map else {
                followLockedId = nil
                return
            }
            guard !isGestureActive else { return }
            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return }
            let target = drawnCoordinate(for: flight)
            guard CLLocationCoordinate2DIsValid(target) else { return }
            let padding = edgeInsets(in: bounds)
            let now = CACurrentMediaTime()

            if followLockedId != flight.id || followNeedsGlide {
                followLockedId = flight.id
                followNeedsGlide = false
                followGlideEnds = now + Self.followGlide
                let moving = markers[flight.id]?.isSmoothing ?? false
                let landing = moving ? Self.ahead(of: target, flight: flight, seconds: Self.followGlide) : target
                mapView.camera.ease(
                    to: CameraOptions(center: landing, padding: padding),
                    duration: Self.followGlide,
                    curve: .easeInOut
                )
                return
            }
            guard now >= followGlideEnds else { return }
            map.setCamera(to: CameraOptions(center: target, padding: padding))
        }

        /// Where an aircraft will be in `seconds`, at its heading and speed.
        private static func ahead(
            of coordinate: CLLocationCoordinate2D,
            flight: Flight,
            seconds: Double
        ) -> CLLocationCoordinate2D {
            let metres = flight.groundSpeedKnots * 0.514444 * seconds
            let heading = flight.heading * .pi / 180
            let latitude = coordinate.latitude + metres * cos(heading) / 111_320
            let longitude = coordinate.longitude
                + metres * sin(heading) / (111_320 * max(cos(coordinate.latitude * .pi / 180), 0.01))
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// Pans to bring a moving aircraft back, but only once it has left the
        /// middle of the part of the map nothing is standing on.
        @discardableResult
        private func keepInView(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard CLLocationCoordinate2DIsValid(coordinate), let mapView = mapView, let map = map else {
                return false
            }
            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }

            let clear = bounds.inset(by: edgeInsets(in: bounds))
            guard clear.width > 1, clear.height > 1 else { return pan(to: coordinate) }

            let comfortable = clear.insetBy(dx: clear.width * 0.25, dy: clear.height * 0.25)
            let here = map.point(for: coordinate)
            // Off the view comes back as (-1, -1), which is outside anyway.
            guard here.x.isFinite, here.y.isFinite, !comfortable.contains(here) else { return false }
            return pan(to: coordinate)
        }

        // MARK: The frame clock

        private var flightLink: CADisplayLink?
        private var lastFlightTick: CFTimeInterval = 0
        private var flyingCount = 0

        private func startFlying() {
            guard flightLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(flyOneFrame))
            // Common, so the traffic keeps flying while a sheet is being
            // dragged over the top of it.
            link.add(to: .main, forMode: .common)
            flightLink = link
            // Sixty rather than the display's hundred and twenty, or less on a
            // phone that is saving power. An aeroplane is never under a finger,
            // and what this writes per frame is features — worth doing often
            // enough to read as continuous and no more often than that.
            applyFrameRates()
        }

        private func stopFlying() {
            flightLink?.invalidate()
            flightLink = nil
        }

        @objc private func flyOneFrame(_ link: CADisplayLink) {
            let now = link.timestamp
            let elapsed = now - lastFlightTick
            lastFlightTick = now

            guard isStyleLoaded, let mapView = mapView, mapView.window != nil else { return }
            guard pointsPerMetre > 0 else { return }

            // The camera goes with the followed aircraft on every frame,
            // whichever way this one ends.
            defer { followSelection() }

            refreshModelScale(force: false)
            updateFlownHead()
            syncDirectLine()
            refreshSky(force: false)
            stepWindParticles(at: now)
            stepOwnModel()

            let smoothing = parent.smoothsTraffic
            guard smoothing || flyingCount > 0 || sweptOnMap > 0 else { return }
            guard !markers.isEmpty else { return }

            // A resume from the background rather than a frame: the aircraft go
            // back to their reported positions and start again from there.
            guard elapsed > 0, elapsed < 1 else {
                var reset: [Feature] = []
                for marker in markers.values where marker.isSmoothing {
                    marker.endMotion()
                    reset.append(trafficFeature(for: marker))
                }
                flyingCount = 0
                if !reset.isEmpty {
                    map?.updateGeoJSONSourceFeatures(forSourceId: Source.traffic, features: reset)
                }
                return
            }

            var flying = 0
            var changed: [Feature] = []

            for marker in markers.values {
                // Cheapest first: is it on screen, is it to be carried at all,
                // and is it moving.
                let inView = isInSmoothingBox(marker.coordinate)

                let flight = marker.flight
                let required = flight.requiresSmoothing
                // The aircraft the camera is following is always carried, so
                // the camera has a smooth path to move along.
                let followed = parent.isFollowing && flight.id == parent.selection?.id
                // Every moving aeroplane on screen, however slowly it crosses
                // it: one left on its packets hops, and one that started or
                // stopped being carried as the zoom moved past a speed floor
                // was put back on its last packet — a jump, mid-pinch.
                let wanted = inView && (smoothing || required || followed) && flight.isWorthSmoothing

                let was = marker.isSmoothing
                if wanted != was {
                    if wanted { marker.beginMotion(now: now) } else { marker.endMotion() }
                }

                if marker.isSmoothing {
                    marker.advanceMotion(to: now)
                    flying += 1
                }

                guard marker.isSmoothing || was else { continue }
                if marker.needsWrite(pointsPerMetre: pointsPerMetre) {
                    changed.append(trafficFeature(for: marker))
                }
            }

            flyingCount = flying

            if !changed.isEmpty {
                map?.updateGeoJSONSourceFeatures(forSourceId: Source.traffic, features: changed)
            }
        }

        // MARK: Camera commands

        private var handledCommand: UUID?

        /// Carries out a camera move, once — and ticks it off only when the
        /// move has actually happened, so a command that arrives before there
        /// is anything to move to waits for the next pass instead of being
        /// lost.
        private func handle(_ command: MapCommand?) {
            guard let command = command, command.id != handledCommand else { return }
            guard let mapView = mapView, mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }

            let carried: Bool
            switch command.kind {
            case .centerOnFlight:
                carried = center()
            case .fitRoute:
                carried = fitRoute()
            case .fitFlownPath:
                carried = fitFlownPath()
            case .focus(let latitude, let longitude, let spanMeters):
                carried = focus(
                    on: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    spanMeters: spanMeters
                )
            }

            // Or there is nothing left to wait for: the three moves above are
            // all about the open aircraft, and there isn't one.
            if carried || parent.selection == nil { handledCommand = command.id }
        }

        /// Takes the map to somewhere it isn't looking — a search result, a
        /// field with a tower open — at the zoom that fits `spanMeters` into
        /// the part of the map nothing is standing on. Flown rather than eased,
        /// so a jump across an ocean pulls back, crosses, and settles in.
        @discardableResult
        private func focus(on coordinate: CLLocationCoordinate2D, spanMeters: Double) -> Bool {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                  let mapView = mapView else { return false }

            let bounds = mapView.bounds
            let insets = edgeInsets(in: bounds)
            let clear = bounds.inset(by: insets)
            let side = Double(max(min(clear.width, clear.height), 80))
            let span = max(spanMeters, 50)
            let circumference = 40_075_016.686 * max(cos(coordinate.latitude * .pi / 180), 0.01)
            let zoom = log2(circumference * side / (512 * span))

            mapView.camera.fly(
                to: CameraOptions(
                    center: coordinate,
                    padding: insets,
                    zoom: CGFloat(min(max(zoom, 1), 19))
                ),
                duration: 1.1
            )
            return true
        }

        /// Keeps the current zoom and puts the aircraft in the part of the map
        /// the info window isn't covering.
        @discardableResult
        private func center() -> Bool {
            guard let flight = selectedFlight() else { return false }
            return pan(to: drawnCoordinate(for: flight))
        }

        /// Moves the camera so a coordinate lands in the middle of whatever part
        /// of the map nothing is standing on — without touching the zoom, the
        /// bearing or the pitch.
        ///
        /// Mapbox does this natively: the camera's padding moves the point the
        /// camera is centred on, so asking for the coordinate as the centre
        /// with the chrome as the padding puts it in the middle of the clear
        /// box. On the flat map and on the globe alike, wherever the
        /// coordinate is — on screen, off it, round the back of the planet.
        @discardableResult
        private func pan(to coordinate: CLLocationCoordinate2D) -> Bool {
            guard CLLocationCoordinate2DIsValid(coordinate), let mapView = mapView else { return false }
            let bounds = mapView.bounds
            guard bounds.width > 1, bounds.height > 1 else { return false }

            mapView.camera.ease(
                to: CameraOptions(center: coordinate, padding: edgeInsets(in: bounds)),
                duration: 0.45
            )
            return true
        }

        /// Frames everything the route touches: the flown track, both
        /// endpoints, and where the aircraft is now.
        @discardableResult
        private func fitRoute() -> Bool {
            guard let flight = selectedFlight() else { return false }

            var coordinates: [CLLocationCoordinate2D] = [flight.coordinate]
            coordinates += FlightTrailStore.shared.points(for: flight.id).map(\.coordinate)
            if let departure = AirportStore.shared.airport(flight.departureIcao) {
                coordinates.append(departure.coordinate)
            }
            if let arrival = AirportStore.shared.airport(flight.arrivalIcao) {
                coordinates.append(arrival.coordinate)
            }
            return frame(coordinates, around: flight)
        }

        /// Frames the flown track alone — every breadcrumb we hold plus where
        /// the aircraft is now — and falls back to centring when there is no
        /// track yet to frame.
        @discardableResult
        private func fitFlownPath() -> Bool {
            guard let flight = selectedFlight() else { return false }

            let trail = FlightTrailStore.shared.points(for: flight.id)
            guard trail.count >= 2 else { return pan(to: flight.coordinate) }

            return frame(trail.map(\.coordinate) + [flight.coordinate], around: flight)
        }

        /// Fits a set of coordinates into the clear part of the map, or — if
        /// they are all within a few hundred metres of each other — simply
        /// centres on the aircraft, because zooming to a fifty-metre box answers
        /// "where has this been" with a photograph of some tarmac.
        private func frame(_ coordinates: [CLLocationCoordinate2D], around flight: Flight) -> Bool {
            guard let mapView = mapView, let map = map else { return false }

            // On one continuous line of longitude around the aircraft, so a
            // route over the Pacific is framed across it rather than the long
            // way round the world.
            let anchor = flight.coordinate
            let unwrapped = coordinates
                .filter { CLLocationCoordinate2DIsValid($0) }
                .map { GreatCircle.unwrapped($0, after: anchor) }

            guard isFramable(unwrapped) else { return pan(to: flight.coordinate) }

            let state = map.cameraState
            let insets = edgeInsets(in: mapView.bounds)
            guard let camera = try? map.camera(
                for: unwrapped,
                camera: CameraOptions(padding: .zero, bearing: state.bearing, pitch: 0),
                coordinatesPadding: insets,
                maxZoom: 16,
                offset: nil
            ) else {
                return pan(to: flight.coordinate)
            }

            mapView.camera.ease(to: camera, duration: 0.8)
            return true
        }

        private func isFramable(_ coordinates: [CLLocationCoordinate2D]) -> Bool {
            guard let first = coordinates.first else { return false }
            var south = first.latitude, north = first.latitude
            var west = first.longitude, east = first.longitude
            for coordinate in coordinates {
                south = min(south, coordinate.latitude)
                north = max(north, coordinate.latitude)
                west = min(west, coordinate.longitude)
                east = max(east, coordinate.longitude)
            }
            let metres = MercatorPoint(CLLocationCoordinate2D(latitude: south, longitude: west))
                .distance(to: MercatorPoint(CLLocationCoordinate2D(latitude: north, longitude: east)))
            return metres >= 800
        }

        /// What the app is standing on, as a padding to keep a camera move
        /// clear of: the search field along the top, the flight window across
        /// the bottom or down one side, and a margin so nothing framed ends up
        /// hard against an edge. Clamped to two thirds of the view from each
        /// side, so the box being centred in is always a real one.
        private func edgeInsets(in bounds: CGRect) -> UIEdgeInsets {
            let wanted = UIEdgeInsets(
                top: 96,
                left: 44 + parent.leadingInset,
                bottom: parent.bottomInset + 28,
                right: 44 + parent.trailingInset
            )

            guard bounds.width > 1, bounds.height > 1 else { return wanted }

            var insets = UIEdgeInsets(
                top: min(wanted.top, bounds.height * 2 / 3),
                left: min(wanted.left, bounds.width * 2 / 3),
                bottom: min(wanted.bottom, bounds.height * 2 / 3),
                right: min(wanted.right, bounds.width * 2 / 3)
            )
            // Top and bottom together, and left and right, must leave room.
            if insets.top + insets.bottom > bounds.height - 40 {
                let scale = (bounds.height - 40) / max(insets.top + insets.bottom, 1)
                insets.top *= scale
                insets.bottom *= scale
            }
            if insets.left + insets.right > bounds.width - 40 {
                let scale = (bounds.width - 40) / max(insets.left + insets.right, 1)
                insets.left *= scale
                insets.right *= scale
            }
            return insets
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
    /// not setting it.
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
        /// it has not reached.
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

// MARK: - Gestures and the follow

extension TrackerMapView.Coordinator: GestureManagerDelegate {

    /// A drag takes the camera off the followed aircraft, and ends the follow.
    /// A pinch, a rotation or a tilt only pauses it: the camera glides back
    /// onto the aeroplane when the gesture is done.
    func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
        guard parent.isFollowing else { return }
        switch gestureType {
        case .pan:
            followLockedId = nil
            let ended = parent.onFollowEnded
            DispatchQueue.main.async { ended() }
        case .singleTap:
            break
        default:
            isGestureActive = true
        }
    }

    func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {
        if !willAnimate { resumeFollowAfterGesture() }
    }

    func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {
        resumeFollowAfterGesture()
    }

    private func resumeFollowAfterGesture() {
        guard isGestureActive else { return }
        isGestureActive = false
        followNeedsGlide = true
    }
}
