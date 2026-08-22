import SwiftUI

/// The ruler's readout, over the map.
///
/// It has three jobs: say what to do before there is anything to say, carry the
/// answer once there is, and get out of the way. The instruction matters —
/// a mode with two invisible taps in it and no prompt is a mode people leave
/// without ever using.
struct MeasureBar: View {

    @Binding var measurement: MapMeasurement

    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "ruler")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            if measurement.isComplete {
                answer
            } else {
                Text(measurement.start == nil
                     ? "Tap the map to start measuring"
                     : "Tap again for the other end")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.7)
            }

            if measurement.start != nil {
                Button {
                    measurement.clear()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start again")
            }

            Button {
                measurement.isOn = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Put the ruler away")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .flightInfoChrome(theme, in: Capsule())
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .accessibilityElement(children: .contain)
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(measurement.distanceLabel ?? "—")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            Text(detail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The leg's two ends and its heading, on one line. Ends read as ICAO
    /// codes where the tap landed near a field and as a position where it
    /// did not, because "12 miles east of nothing in particular" is a
    /// coordinate and should look like one.
    private var detail: String {
        var parts: [String] = []

        if let from = measurement.endpointLabel(for: measurement.start),
           let to = measurement.endpointLabel(for: measurement.end) {
            parts.append("\(from) → \(to)")
        }

        if let bearing = measurement.bearingDegrees {
            parts.append("\(Format.heading(bearing))°")
        }

        if let time = measurement.timeLabel {
            parts.append(time)
        }

        return parts.joined(separator: "  ·  ")
    }
}
