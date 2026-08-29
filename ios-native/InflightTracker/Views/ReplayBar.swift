import SwiftUI

/// The replay's controls, floating over the map while a flight is being played
/// back.
///
/// It sits where the toolbar would be, because for as long as a replay is
/// running it *is* the toolbar: play, scrub, pace, and a way out.
struct ReplayBar: View {

    @ObservedObject var replay: FlightReplay

    let theme: FlightInfoTheme

    var body: some View {
        VStack(spacing: 8) {
            header

            Slider(
                value: Binding(
                    get: { replay.progress },
                    set: { replay.scrub(to: $0) }
                ),
                in: 0...1
            )
            .tint(theme.accent)
            .controlSize(.small)

            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("REPLAY")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.textDim)

            Text(replay.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            Spacer(minLength: 6)

            Button {
                replay.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .flightInfoSurface(theme, in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End replay")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                replay.togglePlay()
            } label: {
                Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 34, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(replay.isPlaying ? "Pause" : "Play")

            Button {
                replay.cyclePace()
            } label: {
                Text(replay.pace.label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 38, height: 30)
                    .flightInfoSurface(theme, radius: 10, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback pace, \(replay.pace.label)")

            Spacer(minLength: 4)

            // Height and speed at the played instant, which is the whole point
            // of watching it back rather than reading the track as a line.
            if let frame = replay.frame {
                readout(Format.number(frame.altitudeFeet), "FT")
                readout(Format.number(frame.groundSpeedKnots), "KTS")
            }
        }
    }

    private func readout(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)

            Text(unit)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.textDim)
        }
        .fixedSize()
    }
}
