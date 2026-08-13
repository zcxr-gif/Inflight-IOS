import SwiftUI

/// Flight info window, modelled on the web tracker's: hero photo, identity,
/// route with progress, and a live telemetry grid.
///
/// The flight is re-read from the feed by id on every update, so everything
/// here keeps ticking while the sheet is open.
struct FlightDetailView: View {

    @EnvironmentObject private var feed: LiveFeed
    @StateObject private var photoLoader = AircraftPhotoLoader()

    let flightId: String

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        ScrollView {
            if let flight = flight {
                VStack(spacing: 12) {
                    photoHeader(for: flight)
                    identity(for: flight)
                    summary(for: flight)
                    routeCard(for: flight)
                    telemetry(for: flight)
                }
                .padding(16)
                .onAppear {
                    photoLoader.load(type: flight.aircraftName, livery: flight.liveryName)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Flight ended")
                        .font(.headline)
                    Text("This aircraft is no longer reporting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            }
        }
    }

    // MARK: - Photo

    private func photoHeader(for flight: Flight) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let photo = photoLoader.photo {
                AsyncImage(url: photo.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholderArtwork(for: flight)
                    }
                }

                if let contributor = photo.contributor {
                    Text("© \(contributor)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            } else {
                placeholderArtwork(for: flight)
            }
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Shown while the photo loads, and for airframes with no community photo.
    private func placeholderArtwork(for flight: Flight) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let icon = PlaneSprites.shared.icon(forKey: flight.spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .rotationEffect(.degrees(90))
                    .opacity(0.55)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Identity

    private func identity(for flight: Flight) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(flight.displayName)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(line(flight.aircraftName, flight.username))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            Text(line(flight.liveryName, registration(for: flight)))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func registration(for flight: Flight) -> String {
        let fromFeed = flight.aircraft?.registration ?? ""
        if !fromFeed.isEmpty { return fromFeed }
        return photoLoader.photo?.tailNumber ?? ""
    }

    private func line(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Status / altitude / speed

    private func summary(for flight: Flight) -> some View {
        let phase = FlightPhase.from(flight)

        return HStack(spacing: 0) {
            summaryColumn("Status") {
                Text(phase.rawValue)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(color(for: phase))
            }
            summaryColumn("Altitude") {
                Text(Format.number(flight.altitudeFeet) + " ft")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            summaryColumn("Speed") {
                Text(Format.number(flight.groundSpeedKnots) + " kts")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
        }
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryColumn<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func color(for phase: FlightPhase) -> Color {
        switch phase {
        case .cruise: return .green
        case .climb: return .blue
        case .descent: return .orange
        case .ground: return .secondary
        }
    }

    // MARK: - Route

    @ViewBuilder
    private func routeCard(for flight: Flight) -> some View {
        let progress = FlightProgress(flight: flight)
        let departure = AirportStore.shared.airport(flight.departureIcao)
        let arrival = AirportStore.shared.airport(flight.arrivalIcao)

        if flight.departureIcao?.isEmpty == false || flight.arrivalIcao?.isEmpty == false {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    endpoint(icao: flight.departureIcao, airport: departure, alignment: .leading)

                    Image(systemName: "airplane")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white))
                        .padding(.top, 6)

                    endpoint(icao: flight.arrivalIcao, airport: arrival, alignment: .trailing)
                }

                if let progress = progress {
                    progressBar(fraction: progress.fraction)

                    HStack {
                        Text("\(Format.number(progress.flownNM)) NM")
                        Spacer()
                        Text(remainingLabel(for: flight, progress: progress))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func endpoint(icao: String?, airport: Airport?, alignment: HorizontalAlignment) -> some View {
        let code = icao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: alignment, spacing: 2) {
            Text(code.isEmpty ? "—" : code)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 4) {
                if let flag = airport?.flag, !flag.isEmpty {
                    Text(flag).font(.system(size: 11))
                }
                Text(airport?.name ?? "Unknown")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 3)

                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * fraction), height: 3)

                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .bold))
                    .offset(x: min(max(0, width * fraction - 6), max(0, width - 14)))
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 16)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Telemetry")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 10
            ) {
                metric("ALTITUDE", "cloud", Format.number(flight.altitudeFeet), "ft")
                metric("GND SPEED", "speedometer", Format.number(flight.groundSpeedKnots), "kts")
                metric("VERTICAL", "arrow.up.arrow.down", Format.signed(flight.verticalSpeedFPM), "fpm")
                metric("HEADING", "safari", Format.heading(flight.heading), "°")
            }
        }
    }

    private func metric(_ title: String, _ symbol: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

/// Number formatting shared by the detail sheet.
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
