import SwiftUI

/// Pieces shared by the peak state and the expanded window, so the two phases
/// can't drift apart as either one is worked on.

// MARK: - Phase chip

/// Flight phase as a neutral pill: a dot and the phase name, no colour coding.
struct FlightPhaseChip: View {

    let phase: FlightPhase
    let theme: FlightInfoTheme
    var elevated: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.phaseAccent(for: phase))
                .frame(width: 5, height: 5)

            Text(phase.rawValue)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .flightInfoSurface(theme, radius: 99, elevated: elevated)
        // Never allowed to shrink: it sits next to a callsign that may be long,
        // and the callsign is the piece that gives way.
        .fixedSize()
    }
}

// MARK: - Route track

/// The progress track: filled to `fraction`, with the plane riding the head of
/// the fill. Endpoint dots match the web tracker — filled at the origin, hollow
/// at the destination.
struct RouteTrack: View {

    let fraction: Double
    let theme: FlightInfoTheme
    var planeSize: CGFloat = 11

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.trackFill)
                    .frame(height: 3)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, width * clamped), height: 3)

                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)

                Circle()
                    .strokeBorder(theme.trackFill, lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .offset(x: max(0, width - 6))

                Image(systemName: "airplane")
                    .font(.system(size: planeSize, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    // Kept inside the track so the glyph never clips the card.
                    .offset(x: min(max(0, width * clamped - planeSize / 2), max(0, width - planeSize)))
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
        .frame(height: planeSize + 3)
    }
}

// MARK: - Aircraft photo

/// Community aircraft photo, scaled to fill its frame, with the sprite
/// placeholder underneath so the frame is never empty while the request is in
/// flight.
struct AircraftPhotoImage: View {

    let photo: AircraftPhoto?
    let spriteKey: String
    let theme: FlightInfoTheme
    var iconSize: CGFloat = 44

    var body: some View {
        ZStack {
            placeholder

            if let photo = photo {
                AsyncImage(url: photo.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color.clear
                    }
                }
            }
        }
        // Fill the frame, then clip: a resizable image reports its own
        // intrinsic size, which would otherwise widen everything around it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(theme.surfaceFill)

            if let icon = PlaneSprites.shared.icon(forKey: spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.degrees(90))
                    .opacity(0.45)
            }
        }
    }
}

/// Bottom-up gradient that carries text over a photo.
struct PhotoScrim: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.30), location: 0.32),
                .init(color: .black.opacity(0.74), location: 0.66),
                .init(color: .black.opacity(0.93), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Small readouts

/// Label-over-value readout used for the route's flown / remaining / ETE row.
struct MiniStat: View {

    let label: String
    let value: String
    let theme: FlightInfoTheme
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

// MARK: - Text helpers

extension View {

    /// One line, shrinking before it truncates. Every string in the window is
    /// user or feed supplied, so nothing may push the layout wider.
    func flightInfoLine(minimumScale: CGFloat = 0.7) -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(minimumScale)
            .truncationMode(.tail)
    }
}
