import SwiftUI

/// One button in the flight window's action grid.
///
/// Six of these sit under the identity block in two rows of three, and the
/// whole point of this type existing is that they are the *same* button. They
/// were previously two separate implementations — three tiles in one row and
/// three capsule chips in another — which is why they came out different
/// heights and different shapes: the tiles rendered a caption only when they
/// had one, so the clock (which has "ELAPSED" under it) stood taller than
/// Replay and Share beside it.
///
/// Two things here guarantee they match. Every tile lays out all three lines
/// whether or not it has a caption, so a missing one leaves a gap rather than
/// collapsing the tile; and every tile carries the same floor height. The
/// floor is a minimum rather than a fixed size so the grid still grows under
/// larger accessibility type instead of clipping — and because they all share
/// it, they grow together.
struct FlightInfoTile: View {

    let symbol: String

    /// The line that changes — a readout, or the verb.
    let title: String

    /// The small line under it. Nil keeps the space without drawing anything,
    /// which is what keeps a tile without one the same height as its
    /// neighbours.
    var caption: String?

    /// Filled tiles carry the accent. Used for the tile that is also a
    /// readout, and for anything currently switched on.
    var isFilled: Bool = false

    let theme: FlightInfoTheme

    private var foreground: Color { isFilled ? theme.onAccent : theme.textPrimary }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(height: 18)

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(foreground)
                .flightInfoLine(minimumScale: 0.7)

            // Always laid out. `opacity` rather than `if` on purpose: a tile
            // with no caption has to occupy the same height as one that has.
            Text(caption ?? " ")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isFilled ? theme.onAccent.opacity(0.6) : theme.textDim)
                .opacity(caption == nil ? 0 : 1)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: FlightInfoLayout.actionTileHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)

            if isFilled {
                shape.fill(theme.accent)
            } else {
                shape.fill(theme.surfaceFill)
                    .overlay { shape.strokeBorder(theme.stroke, lineWidth: 1) }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
    }
}
