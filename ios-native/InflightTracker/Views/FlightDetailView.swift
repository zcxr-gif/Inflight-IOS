import SwiftUI

/// Details for the tapped aircraft. Reads the flight back out of the feed by
/// id on every update, so the numbers keep ticking while the sheet is open.
struct FlightDetailView: View {

    @EnvironmentObject private var feed: LiveFeed
    let flightId: String

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        Group {
            if let flight = flight {
                content(for: flight)
            } else {
                VStack(spacing: 8) {
                    Text("Flight ended")
                        .font(.headline)
                    Text("This aircraft is no longer reporting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(for flight: Flight) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(for: flight)

            if let route = flight.route {
                Text(route)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 14) {
                metric("Altitude", format(flight.altitudeFeet, unit: "ft"))
                metric("Ground speed", format(flight.groundSpeedKnots, unit: "kt"))
                metric("Vertical speed", format(flight.verticalSpeedFPM, unit: "fpm", signed: true))
                metric("Heading", "\(Int(flight.heading.rounded()))°")
            }

            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private func header(for flight: Flight) -> some View {
        HStack(spacing: 14) {
            if let icon = PlaneSprites.shared.icon(forKey: flight.spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(flight.heading))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(flight.displayName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                if let username = flight.username, !username.isEmpty {
                    Text(username)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if !subtitle(for: flight).isEmpty {
                    Text(subtitle(for: flight))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func subtitle(for flight: Flight) -> String {
        [flight.aircraftName, flight.liveryName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ value: Double, unit: String, signed: Bool = false) -> String {
        let rounded = Int(value.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: abs(rounded))) ?? "\(abs(rounded))"
        let sign = signed && rounded > 0 ? "+" : (rounded < 0 ? "−" : "")
        return "\(sign)\(number) \(unit)"
    }
}
