import SwiftUI

/// The frame-rate meter, in the corner over everything — see `FrameMeter`.
///
/// Redrawn twice a second from what the meter has gathered, and drawn as a
/// plain dark plate rather than glass: a meter that blurred the map under it
/// would be measuring itself.
struct FrameMeterOverlay: View {

    @AppStorage(FrameMeter.settingKey) private var isOn = false

    var body: some View {
        if isOn {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                plate(FrameMeter.shared.reading())
            }
            .padding(.leading, 12)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { FrameMeter.shared.start() }
            .onDisappear { FrameMeter.shared.stop() }
        }
    }

    private func plate(_ reading: FrameMeter.Reading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(reading.framesPerSecond) fps / \(reading.targetRate) Hz")
                .foregroundStyle(colour(for: reading))
            Text(String(
                format: "hitch %.1f ms/s · %d late · worst %.0f ms",
                reading.hitchMillisecondsPerSecond,
                reading.hitches,
                reading.worstFrameMilliseconds
            ))
            if let slowest = reading.slowest {
                Text(String(format: "slowest: %@ %.1f ms", slowest.name, slowest.milliseconds))
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// Green while smooth, amber once hitches start to show, red when they
    /// are what anybody would call a stutter — Apple's thresholds.
    private func colour(for reading: FrameMeter.Reading) -> Color {
        switch reading.hitchMillisecondsPerSecond {
        case ..<5: return .green
        case ..<10: return .orange
        default: return .red
        }
    }
}
