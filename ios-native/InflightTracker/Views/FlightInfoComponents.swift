import SwiftUI

/// Pieces shared by the peak state and the expanded window, so the two phases
/// can't drift apart as either one is worked on.

// MARK: - Phase chip

/// Flight phase as a neutral pill: a dot and the phase name, no colour coding.
struct FlightPhaseChip: View {

    let phase: FlightPhase
    let theme: FlightInfoTheme
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.phaseAccent(for: phase))
                .frame(width: 5, height: 5)

            Text(phase.rawValue)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, compact ? 8 : 11)
        .padding(.vertical, compact ? 4 : 6)
        .flightInfoSurface(theme, radius: 99)
    }
}

// MARK: - Route track

/// The progress track: filled to `fraction`, with the plane riding the head of
/// the fill. Endpoint dots match the web tracker — filled at the origin, hollow
/// at the destination.
struct RouteTrack: View {

    let fraction: Double
    let theme: FlightInfoTheme
    var planeSize: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.trackFill)
                    .frame(height: 4)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, width * clamped), height: 4)

                Circle()
                    .fill(theme.accent)
                    .frame(width: 7, height: 7)
                    .offset(x: -1)

                Circle()
                    .strokeBorder(theme.trackFill, lineWidth: 2)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, width - 6))

                Image(systemName: "airplane")
                    .font(.system(size: planeSize, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    // Kept inside the track so the glyph never clips the card.
                    .offset(x: min(max(0, width * clamped - planeSize / 2), max(0, width - planeSize)))
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
        .frame(height: max(14, planeSize + 4))
    }
}

// MARK: - Aircraft photo

/// Community aircraft photo with the sprite placeholder underneath, so the
/// frame is never empty while the request is in flight.
struct AircraftPhotoImage: View {

    let photo: AircraftPhoto?
    let spriteKey: String
    let theme: FlightInfoTheme
    var iconSize: CGFloat = 54

    var body: some View {
        ZStack {
            placeholder

            if let photo = photo {
                AsyncImage(url: photo.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.clear
                    }
                }
            }
        }
        // Fill first, then clip: without this the image lays itself out at its
        // intrinsic size and pushes the whole column wider than the sheet.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(theme.elevatedFill)

            if let icon = PlaneSprites.shared.icon(forKey: spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.degrees(90))
                    .opacity(0.5)
            }
        }
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
