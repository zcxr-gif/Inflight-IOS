import SwiftUI

/// The key to the coloured field, over the map while one is on.
///
/// ## Why this is not optional
///
/// A heat map without a scale is decoration. The whole claim of the layer is
/// that a colour means a number — that the magenta over the Atlantic is a
/// hundred and eighty knots and not merely "a lot" — and a wash with no key is
/// a wash somebody has to guess at, which is worse than no wash at all because
/// it looks like information.
///
/// So it appears with the layer and goes with it, in the same column as the
/// radar's timestamp and for the same reason: both of them exist because a
/// picture of weather that does not say what it is of is a picture nobody can
/// use.
///
/// ## Three numbers, not eight
///
/// The ramp has seven or eight stops in it and naming all of them would be a
/// ruler across the top of the map. What anybody actually reads off a scale
/// like this is the shape of it — where the interesting end is — so it carries
/// the two ends and the middle, and the gradient does the rest.
struct WeatherFieldLegend: View {

    let product: WeatherHeat
    let level: WindLevel
    let theme: FlightInfoTheme

    @ObservedObject private var preferences = WeatherPreferences.shared

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: product.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .tracking(0.6)

                LinearGradient(
                    colors: WeatherRamp.legend(for: product).map(Color.init(uiColor:)),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 118, height: 6)
                .clipShape(Capsule())

                HStack(spacing: 0) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                        Text(mark)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                        if index < marks.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 118)
            }

            Button {
                preferences.windHeat = .off
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn the field off")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(product.label) at \(level.longLabel), \(marks.first ?? "") to \(marks.last ?? "")")
    }

    /// What the field is of, and at what height — because the same colour means
    /// a different thing at FL050 and FL390, and the level is set somewhere
    /// else entirely.
    private var title: String {
        "\(product.label.uppercased()) · \(level.longLabel)"
    }

    /// The two ends of the ramp and its middle, written in the units this
    /// person reads.
    private var marks: [String] {
        let stops = WeatherRamp.stops(for: product)
        guard let first = stops.first, let last = stops.last else { return [] }
        let middle = (first.value + last.value) / 2

        return [first.value, middle, last.value].map {
            product.reading(
                $0,
                wind: preferences.windUnit,
                temperature: preferences.temperatureUnit
            )
        }
    }
}
