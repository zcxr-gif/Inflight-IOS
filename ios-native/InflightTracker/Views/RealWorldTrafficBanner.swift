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

/// The badge that says an aeroplane is a real one.
///
/// ## Why the window needs this and the map does not
///
/// On the map the colour does the job: real traffic is mint and nothing else
/// is, so the distinction is visible without a word on it. A flight window is
/// a different problem — it is one aircraft, filling the screen, with no second
/// aeroplane beside it to be a different colour *from*. Somebody who opens a
/// window on a real 777 and one on a simulated 777 is looking at two screens
/// with the same shape, and the only honest way to tell them apart is to say
/// so.
///
/// So it is a word rather than a tint, it sits with the callsign rather than
/// in a corner, and it says "real life" rather than "ADS-B" — the distinction
/// being drawn is not which protocol the position arrived over, it is whether
/// this aeroplane exists.
struct RealWorldBadge: View {

    let theme: FlightInfoTheme

    /// Small enough to sit inside a row of chips, for the peak state.
    var isCompact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: isCompact ? 8 : 9, weight: .bold))

            Text("REAL LIFE")
                .font(.system(size: isCompact ? 8.5 : 9.5, weight: .bold))
                .tracking(0.7)
        }
        .foregroundStyle(RealWorldMark.tint)
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 3 : 4)
        .background {
            Capsule().fill(RealWorldMark.tint.opacity(0.16))
        }
        .overlay {
            Capsule().strokeBorder(RealWorldMark.tint.opacity(0.45), lineWidth: 1)
        }
        .accessibilityLabel("Real-world aircraft")
        .accessibilityHint("This aeroplane is flying in the real world, not on the Infinite Flight server.")
    }
}

/// The line that says whose photograph this is, and opens it.
///
/// ## Why this is a control rather than a caption
///
/// Planespotters' terms of use make both halves of this mandatory, and they are
/// specific about the second: the picture must lead back to its page at
/// Planespotters using the link the API returned, reachable by the viewer in a
/// single action, and — in their words — a tap target the user has no way of
/// discovering does not count. A grey caption under a photograph is not a way
/// to reach anything.
///
/// So the credit is drawn as what it is: a button, with an arrow on it, that
/// opens the photographer's own page. The photograph itself carries the same
/// tap, because that is what their terms actually ask for; this is the part
/// that makes it *findable*.
struct PlanespottersCredit: View {

    let photographer: String
    let link: URL
    let theme: FlightInfoTheme

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(link)
        } label: {
            HStack(spacing: 4) {
                Text("© \(photographer)")
                    .font(.system(size: 9, weight: .semibold))
                    .flightInfoLine(minimumScale: 0.8)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .flightInfoSurface(theme, radius: 6, elevated: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photograph by \(photographer)")
        .accessibilityHint("Opens the original on Planespotters.net")
    }
}
