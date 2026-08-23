import SwiftUI

/// The strip over the map while a weather layer is on: what it is, what time
/// the frame is from, and a scrubber through the two hours behind it.
///
/// It exists because a radar frame with no timestamp is a lie by omission —
/// tiles ten minutes old look exactly like tiles from now, and the difference
/// is the whole reason anybody is looking. When the service has nothing to
/// serve, this is also where that gets said, rather than leaving a switch that
/// appears to do nothing.
struct MapWeatherBar: View {

    @ObservedObject var model: MapWeatherModel
    @ObservedObject private var preferences = WeatherPreferences.shared

    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: preferences.mapLayer.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            if let message = model.unavailable {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.7)
            } else {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()

                if let progress = model.progress {
                    scrubber(progress)
                }
            }

            Button {
                preferences.mapLayer = .off
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn the weather layer off")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .flightInfoChrome(theme, in: Capsule())
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
    }

    /// The frame's own time, in the phone's timezone, because a radar frame is
    /// something you compare against the window rather than against UTC.
    ///
    /// Two scales, because the two layers work on two: radar frames are ten
    /// minutes apart and are read in minutes, and the satellite's are whole
    /// days. "−1440 MIN" is technically the truth about yesterday's imagery and
    /// no use to anybody.
    private var label: String {
        guard let time = model.frameTime else { return preferences.mapLayer.label.uppercased() }

        let minutes = Int(Date().timeIntervalSince(time) / 60)
        guard minutes < 360 else { return dayLabel(for: time) }

        switch minutes {
        case ..<(-1): return "+\(-minutes) MIN"
        case -1...1: return "NOW"
        default: return "−\(minutes) MIN"
        }
    }

    private func dayLabel(for time: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: time),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0

        switch days {
        case ..<1: return "TODAY"
        case 1: return "YESTERDAY"
        default: return "−\(days) DAYS"
        }
    }

    /// Drag anywhere along it to move through the frames. Deliberately not a
    /// `Slider`: this is chrome floating over a map at the height of a caption,
    /// and a system slider is three times as tall as the bar it would sit in.
    private func scrubber(_ progress: Double) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.trackFill)
                    .frame(height: 3)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: width * progress, height: 3)

                Circle()
                    .fill(theme.accent)
                    .frame(width: 9, height: 9)
                    .offset(x: (width - 9) * progress)
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.scrub(to: min(max(value.location.x / width, 0), 1))
                    }
            )
        }
        .frame(width: 96, height: 18)
        .accessibilityLabel("Radar frame")
        .accessibilityValue(label)
    }
}
