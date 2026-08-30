import MapKit
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

                Text(subtitle)
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
            Text(ref)
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
                Text(pick.map { "\(role.verb) \($0.ref)" } ?? "Pick a stand")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.8)

                Text(footnote)
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

/// `MKMapView` over imagery, with the field's pavement drawn on it and one
/// marker per stand.
///
/// Its own map rather than a mode of `TrackerMapView`: that one is the app's
/// main map, it carries the traffic, the filters, the replay and the weather,
/// and adding a "but sometimes it is a gate picker" branch to it would put all
/// of that on the path of a screen that wants none of it.
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        map.isRotateEnabled = true
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll

        map.register(
            StandMarker.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        map.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )

        // Tight enough that a terminal fills the screen, which is the scale at
        // which stand numbers mean anything.
        map.setRegion(
            MKCoordinateRegion(
                center: airport.coordinate,
                latitudinalMeters: 2_600,
                longitudinalMeters: 2_600
            ),
            animated: false
        )
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(gates: gates, on: map)
        context.coordinator.sync(layout: layout, on: map)
        context.coordinator.sync(selection: selection, focusToken: focusToken, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {

        var parent: GateChart

        private var drawnGateRefs: Set<String> = []
        private var drawnLayoutIcao: String?
        private var lastFocusToken = 0

        init(_ parent: GateChart) {
            self.parent = parent
        }

        // MARK: Contents

        func sync(gates: [Gate], on map: MKMapView) {
            let refs = Set(gates.map(\.ref))
            guard refs != drawnGateRefs else { return }

            map.removeAnnotations(map.annotations.compactMap { $0 as? StandAnnotation })
            map.addAnnotations(gates.map(StandAnnotation.init))
            drawnGateRefs = refs
        }

        func sync(layout: AirportLayout?, on map: MKMapView) {
            guard let layout = layout, layout.icao != drawnLayoutIcao else { return }

            map.removeOverlays(map.overlays)

            // Same order the main map draws a field in: the areas first, then
            // what is painted on top of them, so a taxiway sits on its apron
            // rather than under it.
            for kind in AirportLayout.drawingOrder {
                for piece in layout.pieces where piece.kind == kind {
                    map.addOverlay(Self.overlay(for: piece), level: .aboveRoads)
                }
            }
            drawnLayoutIcao = layout.icao
        }

        func sync(selection: Gate?, focusToken: Int, on map: MKMapView) {
            let marks = map.annotations.compactMap { $0 as? StandAnnotation }

            for mark in marks where mark.isPicked != (mark.gate.ref == selection?.ref) {
                mark.isPicked = (mark.gate.ref == selection?.ref)
                (map.view(for: mark) as? StandMarker)?.apply(mark)
            }

            guard focusToken != lastFocusToken else { return }
            lastFocusToken = focusToken

            guard let selection = selection else { return }
            map.setRegion(
                MKCoordinateRegion(
                    center: selection.coordinate,
                    latitudinalMeters: 420,
                    longitudinalMeters: 420
                ),
                animated: true
            )
        }

        private static func overlay(for piece: AirportLayout.Piece) -> MKOverlay {
            if piece.kind.isArea {
                let polygon = MKPolygon(coordinates: piece.coordinates, count: piece.coordinates.count)
                polygon.title = piece.kind.rawValue
                return polygon
            }
            if let pavement = GroundOverlay(piece: piece) { return pavement }
            let line = MKPolyline(coordinates: piece.coordinates, count: piece.coordinates.count)
            line.title = piece.kind.rawValue
            return line
        }

        // MARK: Delegate

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // `.imagery` throughout: this map is always a photograph, so the
            // pavement is outlined rather than painted — see the note at the
            // top of the file.
            if let pavement = overlay as? GroundOverlay {
                return GroundRenderer(overlay: pavement, ground: .imagery)
            }

            let kind = (overlay.title ?? nil)
                .flatMap(AirportLayout.Piece.Kind.init(rawValue:))

            if let area = overlay as? MKPolygon, let kind = kind {
                let renderer = MKPolygonRenderer(polygon: area)
                renderer.fillColor = AirportGroundStyle.area(for: kind, on: .imagery)
                renderer.strokeColor = .clear
                renderer.lineWidth = 0
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(
            _ map: MKMapView,
            didSelect annotation: MKAnnotation
        ) {
            // A cluster is not a stand. Tapping one zooms into what it is
            // hiding, which is the only thing it could usefully mean.
            if let cluster = annotation as? MKClusterAnnotation {
                map.deselectAnnotation(annotation, animated: false)
                let region = Self.region(covering: cluster.memberAnnotations, around: cluster.coordinate)
                map.setRegion(region, animated: true)
                return
            }

            guard let mark = annotation as? StandAnnotation else { return }
            map.deselectAnnotation(annotation, animated: false)
            parent.selection = mark.gate
        }

        /// A box around everything in a cluster, with enough margin that the
        /// markers are not against the edge of the screen.
        private static func region(
            covering members: [MKAnnotation],
            around centre: CLLocationCoordinate2D
        ) -> MKCoordinateRegion {
            var minLat = centre.latitude, maxLat = centre.latitude
            var minLon = centre.longitude, maxLon = centre.longitude
            for member in members {
                minLat = min(minLat, member.coordinate.latitude)
                maxLat = max(maxLat, member.coordinate.latitude)
                minLon = min(minLon, member.coordinate.longitude)
                maxLon = max(maxLon, member.coordinate.longitude)
            }
            return MKCoordinateRegion(
                center: centre,
                span: MKCoordinateSpan(
                    latitudeDelta: max((maxLat - minLat) * 1.8, 0.0016),
                    longitudeDelta: max((maxLon - minLon) * 1.8, 0.0016)
                )
            )
        }
    }
}

/// One stand on the picker's map.
private final class StandAnnotation: NSObject, MKAnnotation {

    let gate: Gate
    var isPicked = false

    var coordinate: CLLocationCoordinate2D { gate.coordinate }
    var title: String? { gate.ref }

    init(_ gate: Gate) {
        self.gate = gate
    }
}

/// The marker itself: the stand's own name, in the type a jetway carries it in.
///
/// A balloon with the number *in* it rather than a pin with a callout, because
/// the number is the whole content — a picker where you tap a pin to find out
/// what it is called is a picker you have to tap three hundred times.
private final class StandMarker: MKMarkerAnnotationView {

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Clustered, so an airport with three hundred stands is a readable map
        // rather than a wall of overlapping balloons.
        clusteringIdentifier = "stand"
        displayPriority = .defaultHigh
        titleVisibility = .hidden
        subtitleVisibility = .hidden
        animatesWhenAdded = false
        glyphTintColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var annotation: MKAnnotation? {
        didSet { (annotation as? StandAnnotation).map(apply) }
    }

    func apply(_ mark: StandAnnotation) {
        // Four characters is what fits in a marker balloon. Longer names are
        // real — "Cargo 3", "Remote 12A" — and the strip under the map is where
        // those are read in full.
        glyphText = String(mark.gate.ref.prefix(4))
        markerTintColor = mark.isPicked
            ? UIColor(red: 0.16, green: 0.62, blue: 1.0, alpha: 1)
            : UIColor(white: 0.14, alpha: 0.92)
        displayPriority = mark.isPicked ? .required : .defaultHigh
        zPriority = mark.isPicked ? .max : .defaultUnselected
    }
}
