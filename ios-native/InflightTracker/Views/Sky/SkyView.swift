import CoreLocation
import simd
import SwiftUI

/// Where the sky is being watched from.
///
/// The traffic in this app is flying in Infinite Flight, not over anybody's
/// house, so "point the phone at the sky" needs somewhere to point it *from*.
/// Your own position is the obvious answer and the one that makes the view feel
/// like a window; the other two are what make it useful when the sim's evening
/// is happening somewhere else entirely.
enum SkyVantage: Equatable {

    /// Where the phone is. The sky over your actual head, with the sim's
    /// traffic in it.
    case device

    /// The cockpit of something you are flying. Look out of the window at what
    /// is around you.
    case flight(id: String, name: String)

    /// Standing at a field. Somewhere busy is where this view is worth having.
    case airport(icao: String)
}

/// How far out to count. Anything further is a dot you could not resolve on a
/// clear day anyway.
enum SkyRange: Double, CaseIterable, Identifiable {

    case near = 40
    case medium = 120
    case far = 250

    var id: Double { rawValue }

    var label: String { "\(Int(rawValue)) NM" }
}

/// Point the camera at the sky and see what is flying in it.
///
/// The camera draws the picture; everything over it is arithmetic. Each packet
/// the feed lands is turned into a bearing, an elevation and a distance from
/// wherever the vantage is, and thirty times a second the phone's attitude
/// turns those into points on the screen. Nothing is anchored, tracked or
/// recognised — there is no ARKit session here, because a compass, a
/// gyroscope and a lens are the whole of what a sky full of aeroplanes needs.
struct SkyView: View {

    @EnvironmentObject private var feed: LiveFeed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @StateObject private var pose = SkyPose()
    @StateObject private var camera = SkyCamera()

    /// The pilot's own aircraft, so one of them can be the vantage and so the
    /// rest are picked out of the traffic.
    let myFlights: [Flight]

    /// Opening one of these on the map, which closes this.
    let onOpen: (String) -> Void

    @State private var vantage: SkyVantage = .device
    @State private var range: SkyRange = .medium
    @State private var targets: [SkyTarget] = []

    /// Where the view is being watched from, as of the last packet.
    ///
    /// Held rather than worked out on demand: the attitude redraws this view
    /// thirty times a second, and resolving an aircraft vantage means finding
    /// it in a packet of several thousand. Once every few seconds is both often
    /// enough — a vantage moves at knots, not per frame — and thousands of
    /// times cheaper.
    @State private var observer: SkyObserver?

    /// The field the most aircraft are leaving from, offered as a vantage. The
    /// sim's traffic is somewhere; this is how somebody standing in a quiet
    /// part of the world gets to look at it.
    @State private var busiestField: String?

    /// Enough to fill a sky. Past this the nearest are what matter and the rest
    /// are labels over labels.
    private static let maximumTargets = 40

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.access == .granted {
                    SkyCameraPreview(session: camera.session, rotation: camera.previewRotation)
                        .ignoresSafeArea()
                }

                sky(in: proxy.size)
                chrome

                if let notice = notice {
                    SkyNoticeCard(notice: notice, theme: theme) { dismiss() }
                }
            }
        }
        // The chrome is white-on-picture whatever the app is set to: the
        // background here is a photograph of the outdoors, not a surface with
        // an appearance.
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: scenePhase) { _, phase in
            // Backgrounded with the camera running is both a battery bill and
            // a thing no app should be doing.
            if phase == .active { begin() } else { end() }
        }
        .onChange(of: feed.lastUpdate) { _, _ in rebuild() }
        .onChange(of: range) { _, _ in rebuild() }
        .onChange(of: vantage) { _, _ in rebuild() }
        // The first fix, which is what a device vantage has been waiting for.
        .onChange(of: pose.location != nil) { _, _ in rebuild() }
    }

    // MARK: - Running

    private func begin() {
        camera.start()
        pose.start()
        rebuild()
    }

    private func end() {
        camera.stop()
        pose.stop()
    }

    // MARK: - The sky

    @ViewBuilder
    private func sky(in size: CGSize) -> some View {
        if size.width > size.height {
            // The projection is written for a phone held upright: the picture's
            // long axis runs down the screen, which is what the focal length is
            // worked out from and what the device's own X and Y mean here.
            // Turned on its side — which only an iPad can be, the phone build
            // being portrait — the honest thing is to say so rather than to
            // draw aeroplanes in the wrong part of the sky.
            SkyChip(
                text: "Hold it upright to look at the sky",
                symbol: "rotate.right.fill",
                theme: theme
            )
        } else if let rotation = pose.rotation, camera.fieldOfViewDegrees > 0 {
            let focal = SkyGeometry.focalLength(fieldOfViewDegrees: camera.fieldOfViewDegrees, in: size)

            ZStack {
                ForEach(horizon(rotation: rotation, focal: focal, in: size)) { mark in
                    Text(mark.label)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .position(mark.point)
                }

                ForEach(placed(rotation: rotation, focal: focal, in: size)) { placement in
                    SkyMarker(
                        target: placement.target,
                        theme: theme,
                        prominence: prominence(of: placement.target)
                    ) {
                        onOpen(placement.target.id)
                    }
                    .position(placement.point)
                }
            }
            .allowsHitTesting(notice == nil)
        }
    }

    /// One aircraft, and where on the screen it lands.
    private struct Placement: Identifiable {
        let target: SkyTarget
        let point: CGPoint
        var id: String { target.id }
    }

    /// A cardinal point, drawn on the horizon where it actually is.
    private struct HorizonMark: Identifiable {
        let label: String
        let point: CGPoint
        var id: String { label }
    }

    private func placed(rotation: simd_double3x3, focal: Double, in size: CGSize) -> [Placement] {
        // Generous, so a marker whose ring is just off the edge still shows the
        // half of itself that is on.
        let margin: CGFloat = 80

        return targets.compactMap { target in
            guard let point = SkyGeometry.project(
                target.direction,
                rotation: rotation,
                focalLength: focal,
                in: size
            ),
                point.x > -margin, point.x < size.width + margin,
                point.y > -margin, point.y < size.height + margin
            else { return nil }

            return Placement(target: target, point: point)
        }
    }

    private func horizon(rotation: simd_double3x3, focal: Double, in size: CGSize) -> [HorizonMark] {
        let cardinals: [(String, Double)] = [("N", 0), ("E", 90), ("S", 180), ("W", 270)]

        return cardinals.compactMap { label, bearing in
            let direction = SkyGeometry.direction(bearingDegrees: bearing, elevationDegrees: 0)
            guard let point = SkyGeometry.project(
                direction,
                rotation: rotation,
                focalLength: focal,
                in: size
            ),
                point.x > 0, point.x < size.width, point.y > 0, point.y < size.height
            else { return nil }

            return HorizonMark(label: label, point: point)
        }
    }

    /// Nearer is brighter. Never all the way down — something at the edge of
    /// the range is still something, and a ghost of a label is worse than a
    /// dim one.
    private func prominence(of target: SkyTarget) -> Double {
        let share = min(target.distanceNauticalMiles / range.rawValue, 1)
        return 1 - 0.5 * share
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .flightInfoChrome(theme, in: Circle())
            .environment(\.colorScheme, theme.colorScheme)
            .accessibilityLabel("Close the sky view")

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                if let rotation = pose.rotation {
                    SkyChip(
                        text: heading(of: rotation),
                        symbol: "location.north.line.fill",
                        theme: theme
                    )
                }

                if pose.trouble == .uncalibrated {
                    SkyChip(
                        text: "Wave the phone in a figure of eight",
                        symbol: "arrow.triangle.2.circlepath",
                        theme: theme
                    )
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if targets.isEmpty, notice == nil {
                SkyChip(
                    text: "Nothing flying within \(range.label) of \(vantageName)",
                    symbol: "binoculars.fill",
                    theme: theme
                )
            }

            HStack(spacing: 8) {
                vantageMenu
                rangeMenu
                Spacer(minLength: 0)
                SkyChip(text: "\(targets.count)", symbol: "airplane", theme: theme)
            }
        }
    }

    private var vantageMenu: some View {
        Menu {
            Button { vantage = .device } label: {
                Label("Where I am", systemImage: "location.fill")
            }

            if !myFlights.isEmpty {
                Section("My aircraft") {
                    ForEach(myFlights) { flight in
                        Button {
                            vantage = .flight(id: flight.id, name: flight.displayName)
                        } label: {
                            Label(flight.displayName, systemImage: "airplane")
                        }
                    }
                }
            }

            if let field = busiestField {
                Section("Busiest right now") {
                    Button {
                        vantage = .airport(icao: field)
                    } label: {
                        Label("Stand at \(field)", systemImage: "mappin.and.ellipse")
                    }
                }
            }
        } label: {
            SkyChip(text: vantageName, symbol: vantageSymbol, theme: theme)
        }
        .accessibilityLabel("Looking from \(vantageName)")
    }

    private var rangeMenu: some View {
        Menu {
            ForEach(SkyRange.allCases) { option in
                Button {
                    range = option
                } label: {
                    Label(option.label, systemImage: option == range ? "checkmark" : "scope")
                }
            }
        } label: {
            SkyChip(text: range.label, symbol: "scope", theme: theme)
        }
        .accessibilityLabel("Range, \(range.label)")
    }

    private func heading(of rotation: simd_double3x3) -> String {
        let bearing = SkyGeometry.azimuth(of: rotation)
        return "\(Format.heading(bearing))° \(Self.compassPoint(bearing))"
    }

    /// The sixteen-point name for a bearing, which is how a heading is read out
    /// loud even by people who navigate in degrees.
    private static func compassPoint(_ bearing: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((bearing / 22.5).rounded()) % names.count
        return names[index < 0 ? index + names.count : index]
    }

    private var vantageName: String {
        switch vantage {
        case .device: return "Where I am"
        case .flight(_, let name): return name
        case .airport(let icao): return icao
        }
    }

    private var vantageSymbol: String {
        switch vantage {
        case .device: return "location.fill"
        case .flight: return "airplane"
        case .airport: return "mappin.and.ellipse"
        }
    }

    // MARK: - What is stopping it

    private var notice: SkyNotice? {
        switch camera.access {
        case .refused: return .cameraRefused
        case .unavailable: return .noCamera
        case .waiting, .granted: break
        }

        if let trouble = pose.trouble {
            switch trouble {
            case .noSensors: return .noSensors
            case .locationRefused: return .locationRefused
            case .waiting, .uncalibrated: break
            }
        }

        // A vantage with nowhere to stand: no fix yet, or an aircraft that has
        // landed and left the feed while its cockpit was being looked out of.
        if observer == nil {
            switch vantage {
            case .device: return .findingYou
            case .flight: return .flightGone
            case .airport: return .fieldGone
            }
        }

        return nil
    }

    // MARK: - The arithmetic

    /// Where the vantage actually is right now. An aircraft one moves with the
    /// aircraft; the device one moves with whoever is holding the phone.
    private func resolvedObserver() -> SkyObserver? {
        switch vantage {
        case .device:
            guard let fix = pose.location else { return nil }
            return SkyObserver(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                altitudeFeet: fix.altitude / SkyGeometry.metersPerFoot
            )

        case .flight(let id, _):
            guard let flight = feed.flights.first(where: { $0.id == id }) else { return nil }
            return SkyObserver(
                latitude: flight.latitude,
                longitude: flight.longitude,
                altitudeFeet: flight.altitudeFeet
            )

        case .airport(let icao):
            guard let field = AirportStore.shared.airport(icao) else { return nil }
            // Field elevation is not in the dataset, so this stands at sea
            // level. It costs a degree or so of elevation angle on traffic
            // right overhead at a high-altitude field, and nothing at all on
            // anything far enough away to be worth pointing at.
            return SkyObserver(
                latitude: field.coordinate.latitude,
                longitude: field.coordinate.longitude,
                altitudeFeet: 0
            )
        }
    }

    /// Turns the packet into a sky.
    ///
    /// Runs once per packet rather than per frame — the aircraft move at a few
    /// hundred knots and the phone turns much faster than that, so what is
    /// redrawn thirty times a second is the projection and not this.
    private func rebuild() {
        let observer = resolvedObserver()
        self.observer = observer

        guard let observer = observer else {
            targets = []
            busiestField = busiest(among: feed.flights)
            return
        }

        var tally: [String: Int] = [:]
        tally.reserveCapacity(256)

        let mine = Set(myFlights.map(\.id))
        let limit = range.rawValue

        // A degree of latitude is sixty miles anywhere; a degree of longitude
        // is sixty times the cosine of where you are. Both are cheap enough to
        // do for every aircraft on the server, which is the point — the trig
        // below only runs for the handful that could possibly be in range.
        let latitudeSpan = limit / 60
        let scale = max(cos(observer.latitude * .pi / 180), 0.01)
        let longitudeSpan = latitudeSpan / scale

        var found: [SkyTarget] = []
        found.reserveCapacity(64)

        for flight in feed.flights {
            if let departure = flight.departureIcao, !departure.isEmpty {
                tally[departure, default: 0] += 1
            }

            guard abs(flight.latitude - observer.latitude) <= latitudeSpan else { continue }

            var deltaLongitude = abs(flight.longitude - observer.longitude)
            if deltaLongitude > 180 { deltaLongitude = 360 - deltaLongitude }
            guard deltaLongitude <= longitudeSpan else { continue }

            // Standing in something's cockpit, that something is not traffic.
            if case .flight(let id, _) = vantage, flight.id == id { continue }

            let target = SkyGeometry.target(
                for: flight,
                from: observer,
                isMine: mine.contains(flight.id)
            )

            guard target.distanceNauticalMiles <= limit else { continue }
            found.append(target)
        }

        found.sort { $0.distanceNauticalMiles < $1.distanceNauticalMiles }
        targets = Array(found.prefix(Self.maximumTargets))
        busiestField = tally.max { $0.value < $1.value }?.key
    }

    /// The busiest field on its own, for the pass that bailed before the sky
    /// was built — the vantage menu still has to have something to offer, and
    /// somewhere to stand is exactly what a view with no vantage needs.
    private func busiest(among flights: [Flight]) -> String? {
        var tally: [String: Int] = [:]
        tally.reserveCapacity(256)

        for flight in flights {
            guard let departure = flight.departureIcao, !departure.isEmpty else { continue }
            tally[departure, default: 0] += 1
        }

        return tally.max { $0.value < $1.value }?.key
    }
}
