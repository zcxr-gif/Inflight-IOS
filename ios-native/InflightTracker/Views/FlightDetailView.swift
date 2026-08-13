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

    let flightId: String

    /// Reported upward so the sheet's peak detent is exactly as tall as the
    /// peak state's content, instead of leaving a band of empty sheet below it.
    @Binding var peakHeight: CGFloat

    private var theme: FlightInfoTheme { appearance.theme }

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let expansion = sheetExpansion(for: geometry)
            let peakOpacity = 1 - ramp(expansion, from: 0.02, to: 0.46)
            let fullOpacity = ramp(expansion, from: 0.16, to: 0.68)
            let settled = expansion < 0.04

            ZStack(alignment: .top) {
                if let flight = flight {
                    FlightInfoPeak(flight: flight, image: imageLoader.image, theme: theme)
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
            .onChange(of: settled) { isCollapsed = $0 }
            .onPreferenceChange(PeakContentHeightKey.self) { measured in
                // Zero means the peak state isn't in the tree at all — the
                // aircraft stopped reporting — which is not a reason to
                // collapse the sheet around the message that replaced it.
                guard measured > 80 else { return }

                // Detents are measured from the bottom of the screen, so the
                // home indicator's inset is part of the height the sheet needs.
                let wanted = min(
                    max(measured + bottomInset, FlightInfoLayout.minimumPeakHeight),
                    FlightInfoLayout.maximumPeakHeight
                )
                if abs(wanted - peakHeight) > 1 { peakHeight = wanted }
            }
        }
        .modifier(FlightInfoWindowChrome(theme: theme))
        .environment(\.colorScheme, .dark)
        .onAppear { load(flight) }
        .onChange(of: flight?.liveryName) { _ in load(flight) }
        .onChange(of: photoLoader.photo?.url) { url in imageLoader.load(url) }
    }

    // MARK: - Phase

    /// How far the sheet is between the peak state and the full window, 0...1.
    ///
    /// The safe-area insets are added back because the sheet's content is laid
    /// out inside them: without that the peak would measure short of its own
    /// detent height and the fade would start late.
    private func sheetExpansion(for geometry: GeometryProxy) -> Double {
        let height = geometry.size.height
            + geometry.safeAreaInsets.top
            + geometry.safeAreaInsets.bottom

        let travelled = (height - peakHeight) / FlightInfoLayout.phaseTravel
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
                .onChange(of: isCollapsed) { collapsed in
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
                hero(for: flight, width: width)
                    .id(Self.topAnchor)

                VStack(spacing: 12) {
                    identity(for: flight)
                    situationCard(for: flight)
                    telemetry(for: flight)
                }
                .padding(.horizontal, 14)
                // Negative, so the identity block rides the seam where the
                // photo dissolves into the window instead of sitting inside
                // one or the other.
                .padding(.top, -Self.identityLift)
                .padding(.bottom, 26)
                // iPad and landscape keep a phone-width column rather than
                // stretching the cards across the sheet.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Hero

    private func hero(for flight: Flight, width: CGFloat) -> some View {
        AircraftPhotoImage(
            image: imageLoader.image,
            spriteKey: flight.spriteKey,
            theme: theme,
            iconSize: 64,
            // Airliner photos are wide; filling this frame would cut the nose
            // and tail off, so the whole airframe is fitted onto a blurred
            // copy of itself instead.
            contentMode: .fit
        )
        .frame(width: width, height: heroHeight(for: width))
        .overlay { PhotoScrim() }
        // The photo's own alpha is faded out at the bottom, so it melts into
        // the window's ground rather than ending on a black band.
        .mask { PhotoFadeMask() }
        .overlay(alignment: .topTrailing) { credit }
    }

    /// How far the identity block is pulled up into the photo. Roughly half
    /// its own height, which centres it on the seam.
    private static let identityLift: CGFloat = 30

    /// The hero takes the photo's own shape where it can, so a fitted photo
    /// fills the header edge to edge instead of sitting between blurred bars.
    /// Extremes are clamped — a panoramic shot may not eat the whole sheet.
    private func heroHeight(for width: CGFloat) -> CGFloat {
        guard let image = imageLoader.image,
              image.size.width > 0, image.size.height > 0 else {
            return min(max(width * 0.56, 190), 250)
        }

        let ratio = image.size.height / image.size.width
        return min(max(width * ratio, 180), 300)
    }

    @ViewBuilder
    private var credit: some View {
        if let contributor = photoLoader.photo?.contributor {
            Text("© \(contributor)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .flightInfoSurface(theme, radius: 6, elevated: true)
                .flightInfoLine(minimumScale: 0.8)
                // Clear of the drag indicator, which floats over the photo.
                .frame(maxWidth: 150, alignment: .trailing)
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
    }

    private func identity(for flight: Flight) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(flight.displayName)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
                }

                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textDim)

                    Text(flight.username ?? "Pilot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()
                }

                Text(aircraftLine(for: flight))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let tail = registration(for: flight)
            if !tail.isEmpty {
                Text(tail)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .flightInfoSurface(theme, radius: 7, elevated: true)
                    .fixedSize()
            }
        }
        // Sits in the content column now, so it carries no padding of its own
        // beyond a little breathing room against the card below it.
        .padding(.horizontal, 2)
    }

    private func aircraftLine(for flight: Flight) -> String {
        let parts = [flight.aircraftName, flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown aircraft" : parts.joined(separator: " · ")
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
            VStack(spacing: 12) {
                RouteStrip(
                    departureIcao: flight.departureIcao,
                    arrivalIcao: flight.arrivalIcao,
                    fraction: progress?.fraction ?? 0,
                    theme: theme
                )

                if let progress = progress {
                    hairline

                    HStack(spacing: 8) {
                        MiniStat(
                            label: "FLOWN",
                            value: "\(Format.number(progress.flownNM)) NM",
                            theme: theme
                        )
                        MiniStat(
                            label: "REMAINING",
                            value: "\(Format.number(progress.remainingNM)) NM",
                            theme: theme,
                            alignment: .center
                        )
                        MiniStat(
                            label: "ETE",
                            value: eteLabel(for: flight, progress: progress),
                            theme: theme,
                            alignment: .trailing
                        )
                    }
                }
            }
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

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

    private func eteLabel(for flight: Flight, progress: FlightProgress) -> String {
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—"
        }
        return Format.duration(ete)
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

/// Sheet chrome. The blur has to be the *sheet's* background rather than a
/// layer inside the content — a material inside a sheet whose background was
/// cleared has nothing behind it to sample and renders as a black slab.
private struct FlightInfoWindowChrome: ViewModifier {

    let theme: FlightInfoTheme

    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground { theme.sheetBackground }
                .presentationCornerRadius(theme.radiusLarge + 6)
        } else {
            // No sheet-background API here, so paint the opaque ground inside
            // the window instead of leaving it to system chrome that may not
            // match the window's white-on-carbon text.
            content.background { theme.windowFill.ignoresSafeArea() }
        }
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
