import SwiftUI

/// One aircraft, drawn where it is in the sky.
///
/// A photograph of the aircraft, where there is one.
///
/// It used to be the map's own sprite — the little white plan-view drawing,
/// turned to the aircraft's heading. That is exactly right on a map, where you
/// are looking down at the traffic from above and a shape pointing the way it
/// is flying is the whole of what you need. Held up at the sky it is the wrong
/// drawing: you are looking at the *side* of an aeroplane, from underneath, and
/// a plan view of it tells you nothing you can match against what is up there.
/// A picture of the type does.
///
/// The sprite is still the fallback, for the moment before the photograph
/// arrives and for the types nobody has photographed. A shape in the right
/// place beats nothing in the right place.
struct SkyMarker: View {

    let target: SkyTarget
    let theme: FlightInfoTheme

    /// The photograph of this type, when one has been found.
    let photo: UIImage?

    /// Which way the phone is facing, so the sprite can be turned relative to
    /// it rather than to north.
    let azimuthDegrees: Double

    /// Dimmed with distance, so a screen with forty aircraft in it still reads
    /// front to back.
    let prominence: Double

    let action: () -> Void

    /// The sprite as it is drawn on the map, at the size the sky wants it.
    private static let spriteSize: CGFloat = 30

    /// The photograph's frame. Wide, because aeroplanes are: this is roughly
    /// the shape a side-on shot of an airliner comes in, so the picture fills
    /// it rather than being cropped to a square.
    private static let photoWidth: CGFloat = 76
    private static let photoHeight: CGFloat = 44

    /// White rather than the theme's own ink, and the accent for your own
    /// aircraft. What is behind this is a photograph of the outdoors at
    /// whatever the weather is doing, not a surface the app chose the colour
    /// of — a light theme's near-black text would be drawn on a dark plate
    /// against a bright sky, which is the worst of both.
    private var tint: Color { target.isMine ? theme.accent : .white }

    var body: some View {
        Button(action: action) {
            ZStack {
                face

                reading
                    .offset(y: photo == nil ? 32 : 40)
            }
            .frame(width: 132, height: 112)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(prominence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOver)
        .accessibilityHint("Opens this aircraft on the map")
    }

    /// The photograph, or the sprite until there is one.
    @ViewBuilder
    private var face: some View {
        if let photo = photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: Self.photoWidth, height: Self.photoHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    // A hairline, so the picture has an edge against a bright
                    // sky as well as against a dark one.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            target.isMine ? theme.accent : Color.white.opacity(0.75),
                            lineWidth: target.isMine ? 2 : 1
                        )
                }
                .shadow(color: .black.opacity(0.5), radius: 3)
        } else {
            sprite
        }
    }

    @ViewBuilder
    private var sprite: some View {
        if let icon = PlaneSprites.shared.rawIcon(forKey: target.spriteKey, pointSize: Self.spriteSize) {
            Image(uiImage: icon)
                .resizable()
                .frame(width: Self.spriteSize, height: Self.spriteSize)
                // The artwork points north at zero, which is the convention the
                // map's own annotations are rotated under.
                .rotationEffect(.degrees(target.headingDegrees - azimuthDegrees))
                // Your own aircraft keeps the accent, so it is findable in a
                // sky of identical white shapes.
                .overlay {
                    if target.isMine {
                        Circle()
                            .strokeBorder(theme.accent, lineWidth: 1.5)
                            .frame(width: 26, height: 26)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 2)
        } else {
            // The catalogue has no drawing for this one. A ring is still a
            // position, which is the half of this that matters.
            Circle()
                .strokeBorder(tint, lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.55), radius: 2)
        }
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
    /// shape in the sky is being asked.
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
