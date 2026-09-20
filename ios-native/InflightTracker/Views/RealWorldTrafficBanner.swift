import SwiftUI

/// The bar that says real aeroplanes are on your map.
///
/// ## Why this exists at all
///
/// Real-world traffic is the one layer in the app that can make everything
/// else on screen look wrong. Every count the tracker shows is about Infinite
/// Flight — the aircraft on the server, the fields it ranks as busy, the
/// traffic around a field — and a map carrying two hundred ADS-B contacts on
/// top of them reads as a server having a very strange evening. Somebody who
/// switched the layer on last Tuesday and forgot has no way to work that out
/// from the map, because an aeroplane looks like an aeroplane.
///
/// So the layer is never on quietly. This bar is up the entire time it is,
/// over both shapes of the world, and it cannot be dismissed — the only way to
/// put it away is to turn the layer off, which is the whole point and is one
/// tap away on the bar itself. The map has a second, independent answer to the
/// same question, which is that real aircraft are painted a colour nothing
/// else on the map uses; this is the one that also says *why*.
///
/// ## Why it is not a warning
///
/// No red, no exclamation mark, no "are you sure". Drawing real traffic is a
/// feature somebody deliberately asked for, and an app that nags about its own
/// features teaches people to stop reading it. It is simply the most legible
/// statement of fact the chrome can make: what is on, how much of it there is,
/// and the way out.
struct RealWorldTrafficBanner: View {

    let theme: FlightInfoTheme

    @ObservedObject private var traffic = RealWorldTraffic.shared

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RealWorldMark.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("REAL-WORLD TRAFFIC")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textPrimary)

                Text(traffic.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
                    // Capped, because this line is sometimes a sentence — a
                    // network refusing the request, say — and a bar that grows
                    // to fit one is a banner across the top of the map.
                    .frame(maxWidth: 190, alignment: .leading)
            }

            Button {
                traffic.isOn = false
            } label: {
                Text("OFF")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    // The layer's own colour, so the way out is visibly part
                    // of the thing it turns off rather than a grey chip that
                    // could be anything.
                    .background(Capsule().fill(RealWorldMark.tint.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(RealWorldMark.tint.opacity(0.5), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn real-world traffic off")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            // The one piece of chrome in the app wearing the layer's own
            // colour on its edge. It is what ties the bar to the mint
            // aeroplanes underneath it without a legend having to say so.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RealWorldMark.tint.opacity(0.55), lineWidth: 1)
        }
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Real-world traffic is on. \(traffic.status.label).")
    }
}
