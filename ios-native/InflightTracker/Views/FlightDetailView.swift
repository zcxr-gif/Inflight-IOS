import SwiftUI
import UIKit

/// The flight info window.
///
/// Two phases, stacked and cross-faded: the peak state (`FlightInfoPeak`) the
/// sheet opens in, and the full window below.
///
/// The swap rides the sheet's measured height rather than its detent. A detent
/// binding only changes once a drag commits, so the phases used to swap on
/// their own animation curve while UIKit resized the sheet on another — which
/// is why collapsing left the big photo sitting there until the drag landed
/// and then cut. Reading the height instead makes the cross-fade track the
/// finger, and behave the same in both directions.
///
/// The flight is re-read from the feed by id on every update, so everything
/// here keeps ticking while the sheet is open.
struct FlightDetailView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @StateObject private var photoLoader = AircraftPhotoLoader()
    @StateObject private var imageLoader = RemoteImageLoader()

    /// Set when the window has settled back into the peak state, which is when
    /// the full window's scroll position is rewound.
    @State private var isCollapsed = true

    /// The path this flight has flown — the backend's history once it lands,
    /// extended by live samples. Held here so the profile redraws when it
    /// arrives.
    @State private var track: [TrackPoint] = []

    let flightId: String

    /// Reported upward so the sheet's peak detent is exactly as tall as the
    /// peak state's content, instead of leaving a band of empty sheet below it.
    @Binding var peakHeight: CGFloat

    /// Asked for from the window, carried out by the map: the replay needs the
    /// sheet out of the way and the map free, neither of which is this view's
    /// to arrange.
    var onReplay: ([TrackPoint]) -> Void = { _ in }

    private var theme: FlightInfoTheme { appearance.theme }

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        GeometryReader { geometry in
            let expansion = sheetExpansion(for: geometry)
            // While the sheet is sitting at its peak detent the peak state is
            // the only thing on screen — the full window is not faintly behind
            // it. Both phases are snapped at the foot of the travel rather
            // than left to the ramps, so no residual fraction of a point can
            // put a ghost of the hero photo behind the peak.
            let settled = expansion < 0.02
            let peakOpacity = settled ? 1 : 1 - ramp(expansion, from: 0.02, to: 0.46)
            let fullOpacity = settled ? 0 : ramp(expansion, from: 0.16, to: 0.68)

            ZStack(alignment: .top) {
                if let flight = flight {
                    FlightInfoPeak(
                        flight: flight,
                        image: imageLoader.image,
                        contributor: photoLoader.photo?.contributor,
                        registration: registration(for: flight),
                        theme: theme,
                        style: appearance.peakStyle,
                        width: geometry.size.width
                    )
                        .background {
                            GeometryReader { peak in
                                Color.clear.preference(
                                    key: PeakContentHeightKey.self,
                                    value: peak.size.height
                                )
                            }
                        }
                        // Both phases travel the same way as the sheet grows —
                        // one receding as the other arrives, rather than
                        // crossing past each other.
                        .offset(y: CGFloat(-14 * expansion))
                        .scaleEffect(CGFloat(0.985 + 0.015 * peakOpacity), anchor: .top)
                        .opacity(peakOpacity)
                        .allowsHitTesting(expansion < 0.3)

                    expanded(for: flight, width: geometry.size.width)
                        .offset(y: CGFloat(14 * (1 - fullOpacity)))
                        .scaleEffect(CGFloat(0.985 + 0.015 * fullOpacity), anchor: .top)
                        .opacity(fullOpacity)
                        .allowsHitTesting(expansion > 0.5)
                } else {
                    ended
                }
            }
            // Pins the window to the sheet's width. Feed strings are arbitrary
            // length, and without a hard width one long airport name or livery
            // widens the whole column and pushes it off both edges.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
            // Derived in the layout pass rather than read back off the proxy
            // afterwards, which is not something a GeometryProxy promises.
            .onChange(of: settled) { _, newValue in isCollapsed = newValue }
            .onPreferenceChange(PeakContentHeightKey.self) { measured in
                // Zero means the peak state isn't in the tree at all — the
                // aircraft stopped reporting — which is not a reason to
                // collapse the sheet around the message that replaced it.
                guard measured > 80 else { return }

                // The window draws into the bottom safe area — `measured` is
                // content that already runs down to the screen's edge — so the
                // peak only wants a small gap under its card. Taking the home
                // indicator's inset instead put that whole band below the
                // route block a second time, which was the dead space under
                // the peak state.
                let wanted = min(
                    max(measured + FlightInfoLayout.peakBottomGap, FlightInfoLayout.minimumPeakHeight),
                    FlightInfoLayout.maximumPeakHeight
                )
                if abs(wanted - peakHeight) > 1 { peakHeight = wanted }
            }
        }
        // The sheet's own ground already covers the home indicator, and the
        // peak's card should sit close to the bottom edge rather than above a
        // band of empty sheet the width of that inset.
        .ignoresSafeArea(edges: .bottom)
        .modifier(FlightInfoWindowChrome(theme: theme))
        .environment(\.colorScheme, .dark)
        .onAppear {
            load(flight)
            loadTrack()
        }
        .onChange(of: flight?.liveryName) { _, _ in load(flight) }
        .onChange(of: photoLoader.photo?.url) { _, url in imageLoader.load(url) }
        // Live samples extend the path between packets.
        .onChange(of: feed.lastUpdate) { _, _ in
            let latest = FlightTrailStore.shared.points(for: flightId)
            if latest.count != track.count { track = latest }
        }
    }

    // MARK: - Phase

    /// How far the sheet is between the peak state and the full window, 0...1.
    ///
    /// Only the top inset is added back. The window is laid out inside that
    /// one, so without it the sheet would measure short of its own detent and
    /// the fade would start late — but it draws *through* the bottom inset,
    /// so `size.height` already covers the ground the home indicator sits on.
    /// Adding that back counted it twice, which read as the sheet being a
    /// sixth of the way open the moment it appeared: the peak state opened
    /// washed out with the full window's photo showing faintly behind it.
    private func sheetExpansion(for geometry: GeometryProxy) -> Double {
        let height = geometry.size.height + geometry.safeAreaInsets.top

        let travelled = (height - peakHeight - FlightInfoLayout.phaseDeadZone)
            / FlightInfoLayout.phaseTravel
        return Double(min(max(travelled, 0), 1))
    }

    /// Smoothstep across a slice of the drag. The two slices overlap, so the
    /// phases dissolve through each other instead of one snapping off as the
    /// other snaps on.
    private func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func load(_ flight: Flight?) {
        guard let flight = flight else { return }
        photoLoader.load(type: flight.aircraftName, livery: flight.liveryName)
        imageLoader.load(photoLoader.photo?.url)
    }

    /// Pulls the flown path the backend already has for this flight, which
    /// covers it from departure rather than from whenever the app happened to
    /// start watching.
    private func loadTrack() {
        track = FlightTrailStore.shared.points(for: flightId)

        FlightHistoryService.shared.load(flightId: flightId) { history in
            FlightTrailStore.shared.seed(history, for: flightId)
            track = FlightTrailStore.shared.points(for: flightId)
        }
    }

    private var ended: some View {
        VStack(spacing: 6) {
            Text("Flight ended")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("This aircraft is no longer reporting.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    // MARK: - Expanded window

    private func expanded(for flight: Flight, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            scrollBody(for: flight, width: width)
                // Rewound while the full window is invisible, so coming back up
                // always starts at the photo instead of wherever the last look
                // was left scrolled to.
                .onChange(of: isCollapsed) { _, collapsed in
                    guard collapsed else { return }
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
        }
    }

    private static let topAnchor = "flightInfoTop"

    private func scrollBody(for flight: Flight, width: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Full bleed, flush with the top of the sheet: the photo is the
                // window's header, not a card inside it.
                FlightHero(
                    image: imageLoader.image,
                    spriteKey: flight.spriteKey,
                    contributor: photoLoader.photo?.contributor,
                    theme: theme,
                    width: width
                )
                .id(Self.topAnchor)

                VStack(spacing: 12) {
                    FlightIdentityBlock(
                        flight: flight,
                        registration: registration(for: flight),
                        theme: theme
                    )

                    FlightActionRow(
                        flight: flight,
                        theme: theme,
                        track: track,
                        onReplay: { onReplay(track) }
                    )

                    FlightWatchRow(flight: flight, theme: theme)

                    situationCard(for: flight)
                    telemetry(for: flight)

                    if track.count >= 4 {
                        AltitudeProfileCard(points: track, theme: theme)
                    }

                    HintStrip(placement: .flight)
                }
                .padding(.horizontal, 14)
                // Negative, so the identity block rides the seam where the
                // photo dissolves into the window instead of sitting inside
                // one or the other.
                .padding(.top, -FlightInfoLayout.heroSeamLift)
                // Clears the home indicator, which the window now draws under.
                .padding(.bottom, 40)
                // iPad and landscape keep a phone-width column rather than
                // stretching the cards across the sheet.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func registration(for flight: Flight) -> String {
        let fromFeed = flight.registration ?? ""
        if !fromFeed.isEmpty { return fromFeed }
        return photoLoader.photo?.tailNumber ?? ""
    }

    // MARK: - Route / where it is

    /// A filed destination gets the route strip. Without one, the card says
    /// where the aircraft actually is instead of drawing a route to nowhere.
    @ViewBuilder
    private func situationCard(for flight: Flight) -> some View {
        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            RouteCard(flight: flight, progress: progress, theme: theme)

        case .grounded(let airport, let isTaxiing):
            PlaceCard(
                kicker: isTaxiing ? "TAXIING AT" : "PARKED AT",
                symbol: isTaxiing ? "airplane" : "parkingsign",
                airport: airport,
                theme: theme,
                icaoSize: 24
            )
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

        case .unplanned(let departure, let nearest):
            VStack(spacing: 12) {
                PlaceCard(
                    kicker: nearest == nil ? "IN THE AIR" : "PASSING",
                    symbol: "airplane",
                    airport: nearest,
                    theme: theme,
                    icaoSize: 24
                )

                if departure != nil {
                    hairline

                    HStack(spacing: 8) {
                        MiniStat(label: "DEPARTED", value: departure?.icao ?? "—", theme: theme)
                        MiniStat(
                            label: "DESTINATION",
                            value: "NOT FILED",
                            theme: theme,
                            alignment: .trailing
                        )
                    }
                }
            }
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }

    // MARK: - Telemetry

    private func telemetry(for flight: Flight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TELEMETRY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
                .padding(.leading, 2)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                metric("ALTITUDE", "cloud", Format.number(flight.altitudeFeet), "ft")
                metric("GND SPEED", "speedometer", Format.number(flight.groundSpeedKnots), "kts")
                metric("VERTICAL", "arrow.up.arrow.down", Format.signed(flight.verticalSpeedFPM), "fpm")
                metric("HEADING", "safari", Format.heading(flight.heading), "°")
            }
        }
        .padding(.top, 2)
    }

    private func metric(_ title: String, _ symbol: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.8)

                Spacer(minLength: 2)

                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }
}

/// Sheet chrome. The glass has to be the *sheet's* background rather than a
/// layer inside the content — anything that samples what is behind it, drawn
/// inside a sheet whose background was cleared, has nothing to sample and
/// renders as a black slab.
private struct FlightInfoWindowChrome: ViewModifier {

    let theme: FlightInfoTheme

    func body(content: Content) -> some View {
        content
            .presentationBackground { theme.sheetBackground }
            .presentationCornerRadius(theme.radiusLarge + 6)
    }
}

/// Loads the community photo for one aircraft type + livery.
final class AircraftPhotoLoader: ObservableObject {

    @Published private(set) var photo: AircraftPhoto?

    private var requestedKey: String?

    func load(type: String, livery: String) {
        let key = "\(type)|\(livery)"
        guard requestedKey != key else { return }
        requestedKey = key

        AircraftPhotoService.shared.photo(type: type, livery: livery) { [weak self] resolved in
            guard let self = self, self.requestedKey == key else { return }
            self.photo = resolved
        }
    }
}

/// Number formatting shared by the info window.
enum Format {

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        return decimal.string(from: NSNumber(value: rounded)) ?? String(Int(rounded))
    }

    static func signed(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = Int(value.rounded())
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(number(value))" : "−\(number(abs(value)))"
    }

    static func heading(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        var degrees = Int(value.rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return String(format: "%03d", degrees)
    }

    /// Hours and minutes, as `04:14`.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let totalMinutes = Int((interval / 60).rounded())
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
