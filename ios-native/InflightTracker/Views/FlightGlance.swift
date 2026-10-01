import SwiftUI

/// The four numbers every tracker puts under a flight before you open it.
///
/// Height, speed, how far is left and when it lands — in that order, because
/// that is the order somebody reads a flight they have just tapped: is it up,
/// is it moving, how far to go, when does it get in. Anything the feed cannot
/// answer is swapped for the next most useful thing rather than drawn as a
/// dash: an aeroplane with no route shows its heading instead of a distance,
/// and one too slow to estimate shows its vertical speed instead of a time.
///
/// A model rather than a view, so the peeks that draw it on the window's own
/// ground and the one that draws it over a photograph cannot disagree about a
/// single number — they differ only in ink.
struct FlightGlance {

    struct Cell: Identifiable {
        /// The label doubles as identity: it is what the cell *is*, and it only
        /// changes when the cell becomes a different cell.
        var id: String { label }

        let value: String
        let unit: String
        let label: String

        /// The number the value was made from, so it rolls rather than cuts.
        /// Nil for a value that is words or a clock, which cross-fades instead.
        let figure: Double?

        var trend: Trend = .level
    }

    enum Trend: Equatable {
        case up
        case down
        case level
    }

    let cells: [Cell]

    /// When it gets in at the speed it is doing now, if that is a question
    /// with an answer.
    let arrival: Date?

    /// How long until then.
    let remaining: TimeInterval?

    init(flight: Flight, progress: FlightProgress?) {
        let remaining = progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)
        self.remaining = remaining
        self.arrival = remaining.map { Date().addingTimeInterval($0) }

        let vs = flight.verticalSpeedFPM.isFinite ? flight.verticalSpeedFPM : 0
        let trend: Trend = vs > 300 ? .up : (vs < -300 ? .down : .level)

        var cells: [Cell] = [
            Cell(
                value: Format.number(flight.altitudeFeet),
                unit: "ft",
                label: "ALTITUDE",
                figure: flight.altitudeFeet,
                trend: trend
            ),
            Cell(
                value: Format.number(flight.groundSpeedKnots),
                unit: "kt",
                label: "SPEED",
                figure: flight.groundSpeedKnots
            )
        ]

        if let progress = progress {
            cells.append(Cell(
                value: Format.number(progress.remainingNM),
                unit: "NM",
                label: "TO GO",
                figure: progress.remainingNM
            ))
        } else {
            cells.append(Cell(
                value: Format.heading(flight.heading),
                unit: "°",
                label: "HEADING",
                figure: flight.heading
            ))
        }

        if let remaining = remaining, let arrival = arrival {
            cells.append(Cell(
                value: Self.countdown(remaining),
                unit: "",
                label: "ETA \(Self.clock(arrival))",
                figure: nil
            ))
        } else {
            cells.append(Cell(
                value: Format.signed(vs),
                unit: "fpm",
                label: "VERTICAL",
                figure: vs
            ))
        }

        self.cells = cells
    }

    // MARK: - Clocks

    /// "7h 52m", or "18m" under the hour. Shorter than the window's `07:52`,
    /// which is a duration dressed as a time of day — beside a real clock in
    /// the same cell the two would be easy to confuse.
    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int((interval / 60).rounded()))
        let hours = total / 60
        let minutes = total % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// The device's clock, in the reader's own 12 or 24 hour style. See
    /// `FlightInfoBoard.clock` for why it is not the field's local time.
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()
}

/// The glance, as one row of four cells with hairlines between them.
///
/// Inks are handed in rather than taken from a theme: the same strip sits on
/// the window's ground in one peek and on a darkened photograph in another, and
/// only the caller knows which.
struct FlightGlanceStrip: View {

    let glance: FlightGlance

    let ink: Color
    let secondary: Color
    let dim: Color
    let divider: Color

    /// The climb and descent arrows, which are the only coloured thing here.
    let accent: Color

    var valueSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(glance.cells.enumerated()), id: \.element.id) { index, cell in
                if index > 0 {
                    Rectangle()
                        .fill(divider)
                        .frame(width: 1)
                        .padding(.vertical, 10)
                }

                cellView(cell)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func cellView(_ cell: FlightGlance.Cell) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if cell.trend != .level {
                    Image(systemName: cell.trend == .up ? "arrow.up" : "arrow.down")
                        .font(.system(size: valueSize * 0.62, weight: .heavy))
                        .foregroundStyle(accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }

                value(cell)

                if !cell.unit.isEmpty {
                    Text(cell.unit)
                        .font(.system(size: valueSize * 0.66, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondary)
                        .fixedSize()
                }
            }
            .motion(Motion.control, value: cell.trend)

            Text(cell.label)
                .font(FlightInfoType.kicker)
                .tracking(0.6)
                .foregroundStyle(dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .motionWords(cell.label)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func value(_ cell: FlightGlance.Cell) -> some View {
        let text = Text(cell.value)
            .font(FlightInfoType.figure(valueSize))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)

        if let figure = cell.figure {
            text.motionFigure(figure)
        } else {
            text.motionWords(cell.value)
        }
    }

    private var spoken: String {
        glance.cells
            .map { cell in
                let unit = cell.unit.isEmpty ? "" : " \(cell.unit)"
                return "\(cell.label.capitalized) \(cell.value)\(unit)"
            }
            .joined(separator: ", ")
    }
}
