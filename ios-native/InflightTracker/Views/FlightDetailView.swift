import SwiftUI

/// The flight info window.
///
/// Two phases, stacked and cross-faded exactly like the Capacitor build's
/// window: the peak state (`FlightInfoPeak`) that the sheet opens in, and the
/// full window below. Which one is showing follows the sheet's detent, so
/// dragging the sheet morphs small info into big info.
///
/// The flight is re-read from the feed by id on every update, so everything
/// here keeps ticking while the sheet is open.
struct FlightDetailView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @StateObject private var photoLoader = AircraftPhotoLoader()

    /// A phone in landscape presents sheets full height and ignores detents,
    /// which would strand the peak state in the middle of a full-screen sheet.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let flightId: String

    /// Owned by the presenter so the window and the sheet agree on the phase.
    @Binding var detent: PresentationDetent

    private var theme: FlightInfoTheme { appearance.theme }

    private var isPeak: Bool {
        verticalSizeClass != .compact && detent == .flightInfoPeak
    }

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if let flight = flight {
                    FlightInfoPeak(flight: flight, photo: photoLoader.photo, theme: theme)
                        .opacity(isPeak ? 1 : 0)
                        .allowsHitTesting(isPeak)

                    expanded(for: flight)
                        .opacity(isPeak ? 0 : 1)
                        .allowsHitTesting(!isPeak)
                } else {
                    ended
                }
            }
            // Pins the window to the sheet's width. Feed strings are arbitrary
            // length, and without a hard width one long airport name or livery
            // widens the whole column and pushes it off both edges.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        // Applied outside the reader so the ground covers the home-indicator
        // inset too — with the system sheet background cleared, anything it
        // misses shows the map through the bottom of the window.
        .background { theme.windowBackground.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.28), value: isPeak)
        .modifier(FlightInfoWindowChrome(theme: theme))
        .onAppear { load(flight) }
        .onChange(of: flight?.liveryName) { _ in load(flight) }
    }

    private func load(_ flight: Flight?) {
        guard let flight = flight else { return }
        photoLoader.load(type: flight.aircraftName, livery: flight.liveryName)
    }

    private var ended: some View {
        VStack(spacing: 8) {
            Text("Flight ended")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("This aircraft is no longer reporting.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Expanded window

    private func expanded(for flight: Flight) -> some View {
        VStack(spacing: 0) {
            header(for: flight)

            ScrollView {
                VStack(spacing: 12) {
                    hero(for: flight)
                    routeCard(for: flight)
                    telemetry(for: flight)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
                // iPad and landscape keep the phone-width column rather than
                // stretching the cards across the sheet.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Header

    private func header(for flight: Flight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(flight.displayName)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textDim)

                    Text((flight.username ?? "Pilot").uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    // MARK: - Hero photo

    private func hero(for flight: Flight) -> some View {
        AircraftPhotoImage(photo: photoLoader.photo, spriteKey: flight.spriteKey, theme: theme)
            // A fixed height rather than an aspect ratio: inside a ScrollView
            // the proposed height is unspecified, and a ratio resolved against
            // that collapses the frame.
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let contributor = photoLoader.photo?.contributor {
                    Text("© \(contributor)".uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .flightInfoSurface(theme, radius: 6, elevated: true)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottom) { heroCaption(for: flight) }
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(theme.stroke, lineWidth: 1)
            }
    }

    private func heroCaption(for flight: Flight) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(flight.aircraftName.isEmpty ? "Unknown type" : flight.aircraftName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine()

                if !flight.liveryName.isEmpty {
                    Text(flight.liveryName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let tail = registration(for: flight)
            if !tail.isEmpty {
                Text(tail)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .flightInfoSurface(theme, radius: 8, elevated: true)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func registration(for flight: Flight) -> String {
        let fromFeed = flight.registration ?? ""
        if !fromFeed.isEmpty { return fromFeed }
        return photoLoader.photo?.tailNumber ?? ""
    }

    // MARK: - Route

    @ViewBuilder
    private func routeCard(for flight: Flight) -> some View {
        let progress = FlightProgress(flight: flight)
        let hasRoute = flight.departureIcao?.isEmpty == false || flight.arrivalIcao?.isEmpty == false

        if hasRoute {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    endpoint(icao: flight.departureIcao, alignment: .leading)

                    Image(systemName: "airplane")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(theme.accent))
                        .padding(.top, 4)

                    endpoint(icao: flight.arrivalIcao, alignment: .trailing)
                }

                if let progress = progress {
                    VStack(spacing: 10) {
                        RouteTrack(fraction: progress.fraction, theme: theme, planeSize: 13)

                        HStack(spacing: 10) {
                            Text("\(Format.number(progress.flownNM)) NM")
                            Spacer(minLength: 8)
                            Text(remainingLabel(for: flight, progress: progress))
                        }
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine(minimumScale: 0.8)
                    }
                }
            }
            .padding(16)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private func endpoint(icao: String?, alignment: HorizontalAlignment) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let airport = AirportStore.shared.airport(icao)

        return VStack(alignment: alignment, spacing: 6) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .tracking(-1.5)
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            HStack(spacing: 4) {
                if let flag = airport?.flag, !flag.isEmpty {
                    Text(flag).font(.system(size: 11))
                }
                Text((airport?.name ?? "Unknown").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func remainingLabel(for flight: Flight, progress: FlightProgress) -> String {
        let distance = "\(Format.number(progress.remainingNM)) NM"
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return distance
        }
        return "\(distance) · ETE \(Format.duration(ete))"
    }

    // MARK: - Telemetry

    private func telemetry(for flight: Flight) -> some View {
        let progress = FlightProgress(flight: flight)

        return VStack(alignment: .leading, spacing: 8) {
            Text("LIVE TELEMETRY")
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
                .padding(.leading, 4)
                .padding(.top, 4)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                metric("ALTITUDE", "cloud", Format.number(flight.altitudeFeet), "ft")
                metric("GND SPEED", "speedometer", Format.number(flight.groundSpeedKnots), "kts")
                metric("VERTICAL", "arrow.up.arrow.down", Format.signed(flight.verticalSpeedFPM), "fpm")
                metric("HEADING", "safari", Format.heading(flight.heading), "°")

                if let progress = progress {
                    metric("DISTANCE", "map", Format.number(progress.totalNM), "NM")
                    metric("REMAINING", "hourglass", Format.percent(1 - progress.fraction), "%")
                }
            }
        }
    }

    private func metric(_ title: String, _ symbol: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.8)
                Spacer(minLength: 4)
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .tracking(-1)
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.5)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }
}

/// Sheet chrome that only exists from iOS 16.4. Clearing the system background
/// is what lets the window's own blur sample the map behind it — without it the
/// glass look flattens into plain grey.
private struct FlightInfoWindowChrome: ViewModifier {

    let theme: FlightInfoTheme

    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground(.clear)
                .presentationCornerRadius(theme.radiusLarge + 8)
        } else {
            content
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

    /// A 0...1 fraction as whole percent.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(Int((min(max(value, 0), 1) * 100).rounded()))
    }

    /// Hours and minutes, as `04:14`.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let totalMinutes = Int((interval / 60).rounded())
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
