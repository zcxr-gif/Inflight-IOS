import SwiftUI

/// One aircraft, drawn where it is in the sky.
///
/// A ring on the exact point and the reading underneath it. The ring is what
/// the projection actually places — the label hangs off it, so a name being
/// long never moves the thing it names.
struct SkyMarker: View {

    let target: SkyTarget
    let theme: FlightInfoTheme

    /// Dimmed with distance, so a screen with forty aircraft in it still reads
    /// front to back.
    let prominence: Double

    let action: () -> Void

    /// White rather than the theme's own ink, and the accent for your own
    /// aircraft. What is behind this is a photograph of the outdoors at
    /// whatever the weather is doing, not a surface the app chose the colour
    /// of — a light theme's near-black text would be drawn on a dark plate
    /// against a bright sky, which is the worst of both.
    private var tint: Color { target.isMine ? theme.accent : .white }

    var body: some View {
        Button(action: action) {
            ZStack {
                ring

                reading
                    .offset(y: 30)
            }
            .frame(width: 132, height: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(prominence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOver)
        .accessibilityHint("Opens this aircraft on the map")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: 1.5)
                .frame(width: 18, height: 18)

            Circle()
                .fill(tint)
                .frame(width: 4, height: 4)
        }
        // The sky behind this is a photograph of whatever is out there, and a
        // hairline over a bright cloud is a hairline nobody can see.
        .shadow(color: .black.opacity(0.55), radius: 2)
    }

    private var reading: some View {
        VStack(spacing: 1) {
            Text(target.callsign)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .flightInfoLine(minimumScale: 0.7)

            Text(detail)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.45))
        }
        .frame(width: 130)
    }

    /// How far away and how high, which between them is the whole of what a
    /// dot in the sky is being asked.
    private var detail: String {
        "\(Format.number(target.distanceNauticalMiles)) NM · \(Format.number(target.altitudeFeet)) ft"
    }

    private var voiceOver: String {
        let bearing = Format.heading(target.bearingDegrees)
        let distance = Format.number(target.distanceNauticalMiles)
        let altitude = Format.number(target.altitudeFeet)
        return "\(target.callsign), \(target.aircraftName), bearing \(bearing), "
            + "\(distance) nautical miles, \(altitude) feet"
    }
}
