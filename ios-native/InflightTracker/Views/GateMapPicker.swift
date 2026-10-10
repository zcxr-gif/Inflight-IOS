import MapboxMaps
import SwiftUI

/// The field, its stands, and a tap. Inflight Pro.
///
/// Everything a free account can record about a gate, this records too — a
/// name, and nothing that could not have been typed. What it changes is
/// finding the name: at a field with three hundred stands, "which pier is 543
/// on" is a question nobody can answer from a text box, and the answer has been
/// on the device all along. `GateStore` already knows where every mapped stand
/// is, because the field's own panel uses it to say which ones are occupied.
/// This draws them.
///
/// ## Two kinds of field
///
/// OpenStreetMap's apron coverage is excellent at large European airports and
/// thin almost everywhere else, and a picker that is empty at half the world's
/// fields is a picker people stop opening. So there are two modes, and the
/// screen says plainly which one it is in:
///
/// - **Mapped** — the field drawn on imagery with a marker on every stand.
/// - **Named only** — no survey, but the backend's community stand list has
///   this field's numbering (see `StandDirectory`). A list of real names to
///   pick from, and no map, because there is nothing honest to draw.
///
/// A stand picked in the first mode carries its position into the plan; one
/// picked in the second carries only its name, exactly as a typed one does.
///
/// ## Why imagery
///
/// The pavement layer is drawn as outlines over a photograph rather than as
/// painted concrete — see `AirportGroundStyle.Ground.imagery`. That is the
/// right call here for a reason beyond looks: what somebody is actually doing
/// on this screen is matching a stand number to a place they recognise, and
/// they recognise the terminal roof, not the polygon. The chart lines say which
/// strip of the picture is a runway; the picture says everything else.
struct GateMapPicker: View {

    let airport: Airport

    /// Which end of the plan is being filled in, for the header to say so. The
    /// picker is otherwise identical either way.
    let role: Role

    /// The stand already chosen, so reopening the picker starts where it was
    /// left rather than throwing the choice away.
    var selected: PlannedFlight.Stand?

    /// Handed the stand, with its position when there was one to have.
    let onPick: (PlannedFlight.Stand) -> Void

    enum Role {
        case departure
        case arrival

        var title: String {
            switch self {
            case .departure: return "DEPARTURE STAND"
            case .arrival: return "ARRIVAL STAND"
            }
        }

        var verb: String {
            switch self {
            case .departure: return "Push back from"
            case .arrival: return "Shut down on"
            }
        }

        var word: String {
            switch self {
            case .departure: return "departure"
            case .arrival: return "arrival"
            }
        }
    }

    /// What is currently picked, and how it was found.
    ///
    /// One value rather than two pieces of state, because the footer, the
    /// highlight and the answer handed back all have to agree about it — and
    /// because the difference between the two cases is exactly the difference
    /// the plan itself records: a mapped stand knows where it is, a named one
    /// only knows what it is called.
    private enum Choice: Equatable {
        case mapped(Gate)
        case named(String)

        var ref: String {
            switch self {
            case .mapped(let gate): return gate.ref
            case .named(let ref): return ref
            }
        }

        var stand: PlannedFlight.Stand {
            switch self {
            case .mapped(let gate): return PlannedFlight.Stand(gate)
            case .named(let ref): return PlannedFlight.Stand(ref: ref)
            }
        }

        var gate: Gate? {
            guard case .mapped(let gate) = self else { return nil }
            return gate
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var gateStore = GateStore.shared
    @ObservedObject private var layoutStore = AirportLayoutStore.shared
    @ObservedObject private var directory = StandDirectory.shared

    @State private var pick: Choice?
    @State private var query = ""

    /// Bumped every time the map should be re-centred on the pick — choosing
    /// out of the strip, rather than tapping the map, which is already where
    /// you are looking.
    @State private var focusToken = 0

    private var theme: FlightInfoTheme { appearance.theme }

    /// The mapped stands, in the field's own order.
    private var gates: [Gate] {
        gateStore.gates(for: airport.icao)
            .sorted { GateOccupancy.naturalOrder($0.ref, $1.ref) }
    }

    /// Whether the field has a survey behind it at all. Everything on this
    /// screen branches on this one answer.
    private var isMapped: Bool {
        if case .ready(let mapped) = gateStore.state(for: airport.icao) { return !mapped.isEmpty }
        return false
    }

    /// Whether the stand lookup has finished, either way.
    private var hasMapAnswer: Bool {
        switch gateStore.state(for: airport.icao) {
        case .idle, .loading: return false
        case .ready, .failed: return true
        }
    }

    /// The names to offer, filtered by what has been typed.
    ///
    /// `localizedCaseInsensitiveContains` rather than a prefix match: people
    /// look for "24" as often as they look for "B", and a prefix search finds
    /// neither B24 nor 124 for the first.
    private func matches(_ refs: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return refs }
        return refs.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        SheetWindow(theme: theme) {
            header
        } content: {
            VStack(spacing: 0) {
                if !hasMapAnswer {
                    waiting
                } else if isMapped {
                    chart
                    strip(matches(gates.map(\.ref)), pickIsMapped: true)
                    footer
                } else {
                    unmapped
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(\.colorScheme, theme.colorScheme)
        .onAppear {
            gateStore.load(airport)
            // The pavement is a second Overpass query and the picker is usable
            // without it — the stands are the point, the chart lines are
            // context — so it is asked for alongside rather than waited on.
            layoutStore.load(airport)
            restoreSelection()

            // A field opened twice in one session has its stands from disk
            // already, so `hasMapAnswer` is true before the change watcher
            // below ever gets to fire. Without this, the second visit to an
            // unmapped field shows the empty state the first visit had.
            if hasMapAnswer, !isMapped { directory.load(airport.icao) }
        }
        // And again when either list lands. On a field being opened for the
        // first time `onAppear` runs against nothing at all, so a stand chosen
        // earlier could only be restored from its own stored coordinate — and a
        // *typed* gate has none. This is what puts the marker on B24 for
        // somebody who typed B24 and then opened the map.
        .onChange(of: gates.count) { _, _ in restoreSelection() }
        .onChange(of: hasMapAnswer) { _, answered in
            // Only asked for once the survey has come back empty, so a mapped
            // field never pays for a request it has no use for.
            if answered, !isMapped { directory.load(airport.icao) }
        }
        .onChange(of: directory.names(for: airport.icao).count) { _, _ in restoreSelection() }
    }

    /// Puts the picker back on the stand the plan already names.
    ///
    /// By mapped name first, so a typed gate finds its surveyed twin and gains
    /// a position; by the stored coordinate second, so a stand picked at a
    /// field OpenStreetMap has since stopped mapping is still shown where it
    /// was; by name alone last, which is all an unmapped field ever has.
    private func restoreSelection() {
        guard pick == nil, let selected = selected else { return }

        if let mapped = gates.first(where: { $0.ref == selected.ref }) {
            pick = .mapped(mapped)
            focusToken += 1
            return
        }

        if let coordinate = selected.coordinate {
            pick = .mapped(Gate(ref: selected.ref, coordinate: coordinate, kind: .gate))
            focusToken += 1
            return
        }

        if directory.names(for: airport.icao).contains(selected.ref) {
            pick = .named(selected.ref)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(airport.icao) · \(role.title)")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.textPrimary)

                Text(L(subtitle))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }

            Spacer(minLength: 8)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .flightInfoSurface(theme, in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the gate picker")
        }
    }

    /// Says which of the two modes this is, and where the answer came from.
    /// Naming the source is not pedantry: one of them is a survey with
    /// positions in it and the other is a list of names, and somebody choosing
    /// a stand should know which they are looking at.
    private var subtitle: String {
        guard hasMapAnswer else { return airport.name }
        if isMapped { return "\(gates.count) stands mapped · OpenStreetMap" }

        let names = directory.names(for: airport.icao)
        if !names.isEmpty { return "\(names.count) stands listed · no map for this field" }
        return airport.name
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Reading \(airport.icao)'s stands…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trouble(title: String, detail: String) -> some View {
        PanelEmptyState(symbol: "mappin.slash", title: title, detail: detail)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The rule between the map and the strip, and above the footer.
    ///
    /// An overlay pinned to the top edge rather than a background: a
    /// one-point background is centred in whatever it is behind, which puts the
    /// line through the middle of the row instead of above it.
    private var hairline: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }

    // MARK: - Mapped fields

    private var chart: some View {
        GateChart(
            airport: airport,
            gates: gates,
            layout: layoutStore.layout(for: airport.icao),
            selection: Binding(
                get: { pick?.gate },
                set: { gate in pick = gate.map(Choice.mapped) }
            ),
            focusToken: focusToken
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { search }
    }

    /// Filtering by name, over the map rather than beside it.
    ///
    /// A field with three hundred stands is a field where scrolling a list is
    /// the slow way and reading the map is the fast one — so the search is a
    /// small thing in a corner that gets out of the way, not a bar that takes a
    /// band off the top of the picture.
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textDim)

            TextField("Gate", text: $query)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .frame(width: 68)

            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .flightInfoSurface(theme, in: Capsule(), elevated: true)
        .padding(12)
    }

    /// Every stand, as a row of chips under the map.
    ///
    /// The map answers "where is B24"; this answers "what is this field's
    /// numbering like at all", which is the question at an unfamiliar airport.
    /// Choosing one selects it and takes the map there — see `focusToken`.
    private func strip(_ refs: [String], pickIsMapped: Bool) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if refs.isEmpty {
                        Text("No stand matches “\(query)”.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .padding(.vertical, 8)
                    }

                    ForEach(refs, id: \.self) { ref in
                        chip(ref, mapped: pickIsMapped).id(ref)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: pick?.ref) { _, ref in
                guard let ref = ref else { return }
                withAnimation(Motion.content) { scroller.scrollTo(ref, anchor: .center) }
            }
        }
        .overlay(alignment: .top) { hairline }
    }

    private func chip(_ ref: String, mapped: Bool) -> some View {
        let isPicked = pick?.ref == ref

        return Button {
            if mapped, let gate = gates.first(where: { $0.ref == ref }) {
                pick = .mapped(gate)
            } else {
                pick = .named(ref)
            }
            focusToken += 1
        } label: {
            Text(L(ref))
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isPicked ? theme.onAccent : theme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(isPicked ? theme.accent : theme.elevatedFill)
                }
        }
        .buttonStyle(.pressable(scale: 0.95))
        .motion(Motion.control, value: isPicked)
        .accessibilityLabel("Stand \(ref)")
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    // MARK: - Fields with no map

    /// No survey. Either the backend's stand list has this field's numbering,
    /// or nobody has it and the honest thing is to say so.
    @ViewBuilder
    private var unmapped: some View {
        switch directory.state(for: airport.icao) {
        case .idle, .loading:
            waiting

        case .ready(let names) where !names.isEmpty:
            standList(matches(names))
            footer

        case .failed:
            trouble(
                title: "No stands for \(airport.icao)",
                detail: "Nobody has mapped this field, and the stand list could not be reached. Type the gate by hand — a plan does not need the map."
            )

        case .ready:
            trouble(
                title: "No stands for \(airport.icao)",
                detail: "Neither OpenStreetMap nor our own stand list has this field's gates. Type the gate by hand — a plan does not need the map."
            )
        }
    }

    /// The names, as a grid rather than a strip.
    ///
    /// There is no map to sit under here, so the list is the screen and gets
    /// the room: a wall of chips is read at a glance in a way a single
    /// horizontal row of three hundred is not.
    private func standList(_ refs: [String]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)

                Text("Names only — nobody has mapped where these are.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                // Inline here rather than floating over the list, which is what
                // it does on the map. There is no picture underneath to keep
                // clear, and a field that hovers over a grid of chips covers
                // the ones in the corner.
                search
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.top, 4)

            ScrollView(.vertical) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 62), spacing: 7)],
                    spacing: 7
                ) {
                    ForEach(refs, id: \.self) { ref in
                        chip(ref, mapped: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Taking the answer

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(pick.map { "\(role.verb) \($0.ref)" } ?? "Pick a stand"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.8)

                Text(L(footnote))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button {
                guard let pick = pick else { return }
                onPick(pick.stand)
                dismiss()
            } label: {
                Text("Use it")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(pick == nil ? theme.textDim : theme.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(pick == nil ? theme.elevatedFill : theme.accent)
                    }
            }
            .buttonStyle(.pressable(scale: 0.97))
            .disabled(pick == nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { hairline }
        .flightInfoLegible(theme)
    }

    private var footnote: String {
        guard let pick = pick else {
            return isMapped
                ? "Every marker is a gate, stand or parking position somebody has mapped at \(airport.icao)."
                : "Pick the stand you want for your \(role.word)."
        }

        switch pick {
        case .mapped(let gate):
            return Self.describe(gate)
        case .named:
            return "From the community stand list. Its name goes on the plan; nobody has recorded where it is."
        }
    }

    /// What kind of spot this is, in the mapper's own terms translated into
    /// something a pilot would say.
    private static func describe(_ gate: Gate) -> String {
        switch gate.kind {
        case .gate: return "Terminal gate."
        case .stand: return "Marked stand."
        case .parkingPosition: return "Parking position."
        case .apron: return "Apron — a named area rather than a single spot."
        }
    }
}

// MARK: - The map itself

/// A Mapbox map over imagery, with the field's pavement drawn on it and one
/// marker per stand.
///
/// Its own map rather than a mode of `TrackerMapView`: that one is the app's
/// main map, it carries the traffic, the filters, the replay and the weather,
/// and adding a "but sometimes it is a gate picker" branch to it would put all
/// of that on the path of a screen that wants none of it.
///
/// The stands are a clustered GeoJSON source, so a field with three hundred of
/// them is a readable map at every zoom rather than a wall of overlapping
/// balloons, and Mapbox does the clustering on its worker thread.
private struct GateChart: UIViewRepresentable {

    let airport: Airport
    let gates: [Gate]
    let layout: AirportLayout?

    @Binding var selection: Gate?

    /// Changes when the selection was made somewhere other than the map, and
    /// the map should therefore go to it. A tap on the map must *not* re-centre
    /// — the thing you tapped is already under your finger, and moving the map
    /// out from under it is the most disorienting thing a map can do.
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MapView {
        let options = MapInitOptions(
            // Imagery with the place names on it: what somebody matching a
            // stand number to a place recognises is the terminal roof.
            mapStyle: .standardSatellite(
                showPointOfInterestLabels: false,
                showTransitLabels: false
            ),
            // Tight enough that a terminal fills the screen, which is the
            // scale at which stand numbers mean anything.
            cameraOptions: CameraOptions(
                center: airport.coordinate,
                zoom: Coordinator.zoom(spanning: 2_600, at: airport.coordinate.latitude, across: 390)
            )
        )
        let map = MapView(frame: .zero, mapInitOptions: options)
        map.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        map.gestures.options.rotateEnabled = true
        map.gestures.options.pitchEnabled = false
        map.ornaments.options.scaleBar.visibility = .hidden
        map.ornaments.options.compass.visibility = .hidden

        context.coordinator.attach(to: map)
        return map
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ map: MapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    final class Coordinator {

        var parent: GateChart

        private weak var mapView: MapView?
        private var cancelables: Set<AnyCancelable> = []
        private var isStyleLoaded = false

        private var drawnGates: String?
        private var drawnLayoutIcao: String?
        private var lastFocusToken = 0

        private static let standsSource = "gate-stands"
        private static let clusterLayer = "gate-clusters"
        private static let clusterCountLayer = "gate-cluster-counts"
        private static let standLayer = "gate-stands"
        private static let standLabelLayer = "gate-stand-labels"

        init(_ parent: GateChart) {
            self.parent = parent
        }

        func attach(to mapView: MapView) {
            self.mapView = mapView
            mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
                self?.styleDidLoad()
            }.store(in: &cancelables)
            let tap = mapView.mapboxMap.addInteraction(TapInteraction { [weak self] context in
                self?.tapped(at: context.point)
                return true
            })
            cancelables.insert(AnyCancelable(tap.cancel))
        }

        func detach() {
            cancelables.removeAll()
        }

        private func styleDidLoad() {
            guard let map = mapView?.mapboxMap else { return }
            isStyleLoaded = true

            // The main map's own ground layers, so the field is drawn exactly
            // as it is there — over imagery, outlined rather than painted.
            MapLayerStyle.install(on: map, labelMinZoom: 22)

            let source = """
            {"type": "geojson", "data": {"type": "FeatureCollection", "features": []},
             "cluster": true, "clusterRadius": 38, "clusterMaxZoom": 17}
            """
            if !map.sourceExists(withId: Self.standsSource),
               let properties = MapLayerStyle.parse(source) as? [String: Any] {
                try? map.addSource(withId: Self.standsSource, properties: properties)
            }

            let bold = MapLayerStyle.json(MapLayerStyle.boldFont)
            let layers = """
            [
                {
                    "id": "\(Self.clusterLayer)", "type": "circle", "source": "\(Self.standsSource)",
                    "filter": ["has", "point_count"],
                    "paint": {
                        "circle-color": "rgba(36,36,36,0.92)",
                        "circle-radius": ["interpolate", ["linear"], ["get", "point_count"], 2, 14, 40, 22],
                        "circle-stroke-color": "rgba(255,255,255,0.85)",
                        "circle-stroke-width": 1.5
                    }
                },
                {
                    "id": "\(Self.clusterCountLayer)", "type": "symbol", "source": "\(Self.standsSource)",
                    "filter": ["has", "point_count"],
                    "layout": {
                        "text-field": ["to-string", ["get", "point_count"]],
                        "text-font": \(bold),
                        "text-size": 11,
                        "text-allow-overlap": true
                    },
                    "paint": {"text-color": "#ffffff"}
                },
                {
                    "id": "\(Self.standLayer)", "type": "circle", "source": "\(Self.standsSource)",
                    "filter": ["!", ["has", "point_count"]],
                    "layout": {"circle-sort-key": ["get", "rank"]},
                    "paint": {
                        "circle-color": ["case", ["to-boolean", ["get", "picked"]], "rgb(41,158,255)", "rgba(36,36,36,0.92)"],
                        "circle-radius": ["case", ["to-boolean", ["get", "picked"]], 15, 13],
                        "circle-stroke-color": "rgba(255,255,255,0.9)",
                        "circle-stroke-width": 1.5
                    }
                },
                {
                    "id": "\(Self.standLabelLayer)", "type": "symbol", "source": "\(Self.standsSource)",
                    "filter": ["!", ["has", "point_count"]],
                    "layout": {
                        "text-field": ["get", "short"],
                        "text-font": \(bold),
                        "text-size": 10,
                        "text-allow-overlap": true,
                        "text-ignore-placement": true,
                        "symbol-sort-key": ["get", "rank"]
                    },
                    "paint": {"text-color": "#ffffff"}
                }
            ]
            """
            for layer in (MapLayerStyle.parse(layers) as? [[String: Any]]) ?? [] {
                guard let id = layer["id"] as? String, !map.layerExists(withId: id) else { continue }
                try? map.addLayer(with: layer, layerPosition: nil)
            }

            drawnGates = nil
            drawnLayoutIcao = nil
            update()
        }

        func update() {
            guard isStyleLoaded, let mapView = mapView, let map = mapView.mapboxMap else { return }

            syncLayout(on: map)
            syncStands(on: map)

            guard parent.focusToken != lastFocusToken else { return }
            lastFocusToken = parent.focusToken
            guard let selection = parent.selection else { return }

            let width = Double(max(mapView.bounds.width, 200))
            mapView.camera.ease(
                to: CameraOptions(
                    center: selection.coordinate,
                    zoom: Self.zoom(spanning: 420, at: selection.coordinate.latitude, across: width)
                ),
                duration: 0.6
            )
        }

        /// The field's pavement, drawn once per field.
        private func syncLayout(on map: MapboxMap) {
            guard let layout = parent.layout, layout.icao != drawnLayoutIcao else { return }
            drawnLayoutIcao = layout.icao
            let features = GroundLayoutFeatures.features(
                for: layout,
                on: .imagery,
                latitude: parent.airport.coordinate.latitude
            )
            map.updateGeoJSONSource(
                withId: MapLayerStyle.Source.ground,
                geoJSON: .featureCollection(FeatureCollection(features: features))
            )
        }

        /// One marker per stand, the picked one in blue and on top.
        private func syncStands(on map: MapboxMap) {
            let picked = parent.selection?.ref
            let key = parent.gates.map(\.ref).joined(separator: ",") + "|" + (picked ?? "-")
            guard key != drawnGates else { return }
            drawnGates = key

            let features = parent.gates.map { gate -> Feature in
                var feature = Feature(geometry: .point(Point(gate.coordinate)))
                let isPicked = gate.ref == picked
                feature.properties = [
                    "ref": .string(gate.ref),
                    // Four characters is what fits in a marker. Longer names
                    // are real — "Cargo 3", "Remote 12A" — and the strip under
                    // the map is where those are read in full.
                    "short": .string(String(gate.ref.prefix(4))),
                    "picked": .boolean(isPicked),
                    "rank": .number(isPicked ? 1 : 0),
                ]
                return feature
            }
            map.updateGeoJSONSource(
                withId: Self.standsSource,
                geoJSON: .featureCollection(FeatureCollection(features: features))
            )
        }

        private func tapped(at point: CGPoint) {
            guard let mapView = mapView, let map = mapView.mapboxMap else { return }
            let box = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
            let options = RenderedQueryOptions(layerIds: [Self.standLayer, Self.clusterLayer], filter: nil)

            _ = map.queryRenderedFeatures(with: box, options: options) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, let hit = ((try? result.get()) ?? []).first else { return }
                    let feature = hit.queriedFeature.feature

                    // A cluster is not a stand. Tapping one zooms into what it
                    // is hiding, which is the only thing it could usefully mean.
                    if case .number? = feature.properties?["point_count"] ?? nil {
                        guard case .point(let position)? = feature.geometry else { return }
                        let zoom = map.cameraState.zoom
                        mapView.camera.ease(
                            to: CameraOptions(center: position.coordinates, zoom: min(zoom + 2, 19)),
                            duration: 0.45
                        )
                        return
                    }

                    guard case .string(let ref)? = feature.properties?["ref"] ?? nil,
                          let gate = self.parent.gates.first(where: { $0.ref == ref })
                    else { return }
                    self.parent.selection = gate
                }
            }
        }

        /// The zoom at which `metres` of ground fill `points` of screen.
        static func zoom(spanning metres: Double, at latitude: Double, across points: Double) -> CGFloat {
            let circumference = 40_075_016.686 * max(cos(latitude * .pi / 180), 0.01)
            let zoom = log2(circumference * points / (512 * max(metres, 1)))
            return CGFloat(min(max(zoom, 1), 20))
        }
    }
}
