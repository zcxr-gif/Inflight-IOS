import SwiftUI

/// One runway on a field's panel: both designators, how long, how wide, what it
/// is made of, and whether it is lit.
///
/// The end the wind favours is marked. The web tracker listed the same rows
/// (`old/www/flight.js` -> `apt-runway-card`) but left the reader to compare
/// the designators against the METAR themselves, which is the one piece of
/// arithmetic the panel is in a position to do for them.
struct RunwayCard: View {

    let runway: Runway

    /// The end the wind favours across the whole field, if any. Passed in
    /// rather than worked out here so all the rows agree on which single end
    /// is the answer.
    let favoured: FavouredRunway?

    let theme: FlightInfoTheme

    /// Whether the favoured end belongs to this runway, and which one it is.
    private var favouredEnd: String? {
        guard let favoured = favoured, favoured.end.runway.id == runway.id else { return nil }
        return favoured.end.designator
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    designators

                    if runway.isLighted {
                        tag("LIT", symbol: "lightbulb.fill")
                    }
                }

                Text("\(runway.dimensionsLabel) · \(runway.surfaceLabel)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }

            Spacer(minLength: 8)

            if let favoured = favoured, favouredEnd != nil {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "wind")
                            .font(.system(size: 9, weight: .semibold))
                        Text("FAVOURED")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(theme.textPrimary)

                    Text(favoured.componentsLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The two ends, with the favoured one filled. Written as separate runs
    /// rather than one string so only the end the wind actually favours is
    /// marked — on `09L / 27R` the wind picks one of them, not the pair.
    private var designators: some View {
        HStack(spacing: 4) {
            if !runway.lowEnd.isEmpty {
                end(runway.lowEnd)
            }

            if !runway.lowEnd.isEmpty, !runway.highEnd.isEmpty {
                Text("/")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textDim)
            }

            if !runway.highEnd.isEmpty {
                end(runway.highEnd)
            }
        }
    }

    private func end(_ designator: String) -> some View {
        let isFavoured = designator == favouredEnd

        return Text(designator)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(isFavoured ? theme.onAccent : theme.textPrimary)
            .padding(.horizontal, isFavoured ? 6 : 0)
            .padding(.vertical, isFavoured ? 2 : 0)
            .background {
                if isFavoured {
                    Capsule().fill(theme.accent)
                }
            }
            .fixedSize()
    }

    private func tag(_ text: String, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7.5))
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background { Capsule().fill(theme.elevatedFill) }
        .fixedSize()
    }

    private var accessibilityLabel: String {
        var parts = ["Runway \(runway.name)", runway.dimensionsLabel, runway.surfaceLabel]
        if runway.isLighted { parts.append("lit") }
        if let favoured = favoured, let end = favouredEnd {
            parts.append("wind favours \(end), \(favoured.componentsLabel)")
        }
        return parts.joined(separator: ", ")
    }
}
