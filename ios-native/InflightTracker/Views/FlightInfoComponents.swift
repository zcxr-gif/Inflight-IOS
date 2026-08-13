import SwiftUI
import UIKit

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

// MARK: - Route

/// Origin and destination either side of the live progress track.
struct RouteStrip: View {

    let departureIcao: String?
    let arrivalIcao: String?
    let fraction: Double
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 24
    var trackWidth: CGFloat = 92

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            port(icao: departureIcao, alignment: .leading)

            RouteTrack(fraction: fraction, theme: theme)
                .frame(width: trackWidth)
                .padding(.top, icaoSize * 0.4)

            port(icao: arrivalIcao, alignment: .trailing)
        }
    }

    private func port(icao: String?, alignment: HorizontalAlignment) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let airport = AirportStore.shared.airport(icao)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing

        return VStack(alignment: alignment, spacing: 4) {
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)

            HStack(spacing: 4) {
                if let flag = airport?.flag, !flag.isEmpty {
                    Text(flag).font(.system(size: 9))
                }
                Text((airport?.name ?? "Unknown").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }
        }
        // The track is the fixed part of the row, so the ports share what is
        // left and a long airport name can only shrink, never widen the card.
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

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

/// Where an aircraft is when there is no route to draw — parked at a gate,
/// taxiing, or airborne with no destination filed.
struct PlaceCard: View {

    let kicker: String
    let symbol: String
    let airport: Airport?
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: icaoSize * 0.52, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .frame(width: icaoSize * 1.7, height: icaoSize * 1.7)
                .background(Circle().fill(theme.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(kicker)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)

                Text(airport?.icao ?? "———")
                    .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                HStack(spacing: 4) {
                    if let flag = airport?.flag, !flag.isEmpty {
                        Text(flag).font(.system(size: 9))
                    }
                    Text((airport?.name ?? "Position unknown").uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Aircraft photo

/// Community aircraft photo with the sprite placeholder underneath, so the
/// frame is never empty while the request is in flight.
struct AircraftPhotoImage: View {

    let image: UIImage?
    let spriteKey: String
    let theme: FlightInfoTheme
    var iconSize: CGFloat = 44

    /// `.fit` keeps the whole airframe in frame — a blurred, scaled copy of
    /// the same photo fills what is left, so the frame is still edge to edge
    /// but the nose and tail are never cropped off.
    var contentMode: ContentMode = .fit

    var body: some View {
        ZStack {
            if let image = image {
                if contentMode == .fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 18, opaque: true)
                        // Blur samples past the edges, so oversize the backdrop
                        // rather than letting it fade out at the frame.
                        .scaleEffect(1.2)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder
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

/// Dissolves the bottom of the hero photo into whatever the window is sitting
/// on.
///
/// Used as a mask rather than as a black gradient painted on top: a black fade
/// leaves a dark band that belongs to neither the photo nor the window, while
/// fading the photo's own alpha lets the sheet's blur (or the carbon ground)
/// come through and the two blend into each other.
struct PhotoFadeMask: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.58),
                .init(color: .black.opacity(0.55), location: 0.82),
                .init(color: .black.opacity(0.12), location: 0.95),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Just enough shading under the identity block to keep white text off a
/// bright sky. Fades out again at the very bottom so it can't reintroduce the
/// band the mask is there to avoid.
struct PhotoScrim: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.10), location: 0.45),
                .init(color: .black.opacity(0.30), location: 0.78),
                .init(color: .black.opacity(0.10), location: 1)
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
