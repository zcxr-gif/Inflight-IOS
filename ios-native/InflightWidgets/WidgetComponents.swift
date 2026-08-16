import SwiftUI
import WidgetKit

/// The route line: two ICAO codes with the aircraft riding between them.
///
/// The one piece of drawing every surface shares — small tile, large tile,
/// lock screen banner and Dynamic Island — so it is written once and sized by
/// its caller. Everything scales off `scale` rather than reading the geometry,
/// because the same view has to be right at 120 points wide and at 320.
struct RouteStrip: View {

    let departure: String
    let arrival: String
    let progress: Double?
    let isLanded: Bool

    /// Point size for the ICAO codes. Everything else is derived from it.
    var icaoSize: CGFloat = 22

    /// Monochrome surfaces — the lock screen and Dynamic Island — get no
    /// accent colour, because the system will flatten it anyway.
    var tint: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: icaoSize * 0.34) {
            Text(departure.isEmpty ? "———" : departure)
                .font(WidgetType.icao(icaoSize))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()

            track
                .frame(maxWidth: .infinity)

            Text(arrival.isEmpty ? "———" : arrival)
                .font(WidgetType.icao(icaoSize))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()
        }
    }

    /// A dashed line for the whole route, a solid one for the part flown, and
    /// the aircraft at the join. Without a resolvable route the solid part and
    /// the aircraft are both omitted — a progress bar pinned at zero reads as
    /// "hasn't left yet", which is a claim we can't make.
    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let y = h / 2
            let glyph = icaoSize * 0.62
            let inset = glyph * 0.5
            let usable = max(0, w - inset * 2)
            let p = min(max(progress ?? 0, 0), 1)
            let planeX = inset + usable * p

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: inset, y: y))
                    path.addLine(to: CGPoint(x: inset + usable, y: y))
                }
                .stroke(
                    WidgetPalette.track,
                    style: StrokeStyle(lineWidth: max(1, icaoSize * 0.07),
                                       lineCap: .round,
                                       dash: [icaoSize * 0.11, icaoSize * 0.16])
                )

                if progress != nil {
                    Path { path in
                        path.move(to: CGPoint(x: inset, y: y))
                        path.addLine(to: CGPoint(x: planeX, y: y))
                    }
                    .stroke(tint.opacity(0.95),
                            style: StrokeStyle(lineWidth: max(1.5, icaoSize * 0.1), lineCap: .round))

                    Image(systemName: isLanded ? "checkmark.circle.fill" : "airplane")
                        .font(.system(size: glyph, weight: .bold))
                        .foregroundStyle(isLanded ? WidgetPalette.success : tint)
                        // Lifts the aircraft off a busy photo without a box
                        // around it.
                        .shadow(color: .black.opacity(0.55), radius: glyph * 0.22)
                        .position(x: planeX, y: y)
                }
            }
        }
        .frame(height: icaoSize * 0.9)
    }
}

/// A labelled readout — "37,000 FT" over "ALTITUDE".
struct WidgetStat: View {

    let value: String
    let label: String
    var alignment: HorizontalAlignment = .leading
    var valueSize: CGFloat = 13

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(value)
                .font(WidgetType.readout(valueSize))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()
            Text(label)
                .font(.system(size: valueSize * 0.58, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(WidgetPalette.dim)
        }
    }
}

/// The small capsule that says what an aircraft is doing.
struct PhaseChip: View {

    let symbol: String
    let text: String
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: size * 0.35) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.95, weight: .bold))
            Text(text)
                .font(.system(size: size, weight: .bold, design: .rounded))
        }
        .foregroundStyle(WidgetPalette.text)
        .padding(.horizontal, size * 0.7)
        .padding(.vertical, size * 0.34)
        .background {
            Capsule().fill(.black.opacity(0.35))
                .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
        }
    }
}

/// The wordmark, bottom or top right depending on the tile.
struct Wordmark: View {
    var size: CGFloat = 9
    var body: some View {
        Text("inflight")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(WidgetPalette.dim)
    }
}

extension View {

    /// One line, shrinking rather than truncating. Long liveries and
    /// four-letter ICAO codes both want this, and a widget has no room to
    /// wrap.
    func flightInfoWidgetLine(minimumScale: CGFloat = 0.65) -> some View {
        lineLimit(1).minimumScaleFactor(minimumScale)
    }
}

extension WidgetFlight {

    /// The same flight, carried forward to `date` on its last known speed.
    ///
    /// A widget is re-rendered on the system's schedule, which can be an hour
    /// after the app last saw the aircraft. Drawing the stored position for
    /// that whole hour leaves a 777 apparently parked mid-Atlantic; advancing
    /// it at its own ground speed keeps the tile alive between app launches
    /// and is right to within a few miles for anything that isn't
    /// manoeuvring.
    ///
    /// Only distance moves. Altitude, speed and phase are left exactly as
    /// they were read, because guessing at a climb profile would be inventing
    /// telemetry rather than extending it — and the tile labels those
    /// readouts with how old they are.
    func advanced(to date: Date) -> WidgetFlight {
        let elapsed = date.timeIntervalSince(capturedAt)
        guard elapsed > 0, groundSpeedKt >= 40, totalNM > 1 else { return self }

        let travelled = Double(groundSpeedKt) * (elapsed / 3600)
        var copy = self
        copy.flownNM = min(flownNM + travelled, totalNM)
        copy.remainingNM = max(0, totalNM - copy.flownNM)
        copy.eta = copy.remainingNM > 0
            ? date.addingTimeInterval(copy.remainingNM / Double(groundSpeedKt) * 3600)
            : date
        return copy
    }

    /// Airborne enough to be worth drawing as flying.
    var isAirborne: Bool { altitudeFt >= 1_000 || groundSpeedKt >= 40 }
}

/// Formatting shared by the tiles.
enum WidgetFormat {

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    /// "3h 15m", or "15m" under the hour.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// How old a reading is, said plainly. Widgets are refreshed on the
    /// system's schedule, not ours, so a tile that has been sitting there for
    /// half an hour should admit it rather than presenting an old altitude as
    /// the current one.
    static func staleness(since date: Date, now: Date = Date()) -> String? {
        let age = now.timeIntervalSince(date)
        guard age > 12 * 60 else { return nil }
        if age > 6 * 3600 { return "Last seen \(clock(date))" }
        return "\(duration(age)) ago"
    }
}
