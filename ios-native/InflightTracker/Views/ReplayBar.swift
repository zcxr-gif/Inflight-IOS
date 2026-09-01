import SwiftUI

/// The replay's controls, floating over the map while a flight is being played
/// back.
///
/// It sits where the toolbar would be, because for as long as a replay is
/// running it *is* the toolbar: play, scrub, pace, and a way out.
struct ReplayBar: View {

    /// The tallest thing in the header row: the button that ends the replay.
    static let headerHeight: CGFloat = 24

    /// How much of the screen that button actually answers to.
    ///
    /// Not the same number, and that is the whole point. Drawn, it is a
    /// twenty-four point circle with a ten point cross in it; pressed, it has
    /// to be the forty-four points Apple has asked for since there were
    /// touchscreens. It reaches that with an overlay rather than a frame, so
    /// the header row — and `reservedHeight`, and the map inset built out of
    /// it — stay the size they were.
    static let tapTarget: CGFloat = 44

    /// A small slider's track and thumb, with a little room around them —
    /// this is applied to the slider as well as counted, so the sum below is
    /// the bar's real height rather than an estimate of it.
    static let sliderHeight: CGFloat = 30

    /// The play and pace buttons, which set the height of the bottom row.
    static let controlsHeight: CGFloat = 30

    static let rowGap: CGFloat = 8
    static let verticalPadding: CGFloat = 12

    /// The gap the bar leaves under itself, above the safe area.
    static let liftOffSafeArea: CGFloat = 6

    /// How much of the map's bottom edge this bar covers, including the gap
    /// underneath it.
    ///
    /// While a replay is running this is the *only* thing standing on the
    /// bottom of the map — the dock steps aside for it, and so now does the
    /// flight window — so it is what the map keeps clear of when it frames the
    /// route. Added up from the parts rather than rounded up from a guess, the
    /// same way `MapDock.reservedHeight` is, so it cannot drift the next time
    /// one of them changes.
    static let reservedHeight: CGFloat =
        verticalPadding * 2
            + headerHeight + rowGap
            + sliderHeight + rowGap
            + controlsHeight
            + liftOffSafeArea

    @ObservedObject var replay: FlightReplay

    let theme: FlightInfoTheme

    var body: some View {
        VStack(spacing: Self.rowGap) {
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
            .frame(height: Self.sliderHeight)

            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Self.verticalPadding)
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
                    .frame(width: Self.headerHeight, height: Self.headerHeight)
                    .flightInfoSurface(theme, in: Circle(), interactive: true)
                    // What can be pressed, which is not what is drawn.
                    //
                    // A frame is layout; it is not a hit region. What makes a
                    // frame pressable is something *in* it that answers to
                    // touches, and on the glass theme there is nothing: the
                    // surface is a `glassEffect` rather than a filled shape,
                    // so the only reliably pressable thing in this button was
                    // the ten-point cross itself, inside a twenty-four point
                    // circle, in the corner of the screen. Which is why the
                    // play button — a real fill behind a thirteen point
                    // glyph — always worked and this one did not.
                    //
                    // So: the circle answers to touches, and a clear square
                    // over it brings the target up to forty-four points
                    // without moving anything. It stays inside the bar's own
                    // padding, so it cannot take a press meant for the map.
                    .contentShape(Circle())
                    .overlay {
                        Color.clear
                            .frame(width: Self.tapTarget, height: Self.tapTarget)
                            .contentShape(Rectangle())
                    }
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
                    .frame(width: 34, height: Self.controlsHeight)
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
                    .frame(width: 38, height: Self.controlsHeight)
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
