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
/// So the layer is never on quietly. Something of this is on screen the entire
/// time the layer is, over both shapes of the world, and there is no way to
/// send it away short of turning the layer off — which is the whole point, and
/// is one tap away on the bar. The map has a second, independent answer to the
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
///
/// ## Why it folds itself away
///
/// The bar used to stay at full size for as long as the layer was on, which is
/// hours. That is the right size for a thing you have not read yet and much too
/// big for one you have: a title, a sentence and a button across the top-left
/// of the map, over the very corner an aeroplane you are watching tends to be
/// in. "It cannot be dismissed" was a good rule about *dismissal* and a bad one
/// about size — they are not the same promise.
///
/// So it says its piece and then shrinks to the smallest thing that still makes
/// the statement: the layer's own glyph, in the layer's own colour, with the
/// count beside it. The count is the half worth keeping — it is the number that
/// makes every other count in the app read strangely, and it goes on ticking.
/// Tapping it puts the bar back, with the way out on it; tapping again folds it
/// up. Nothing collapses on its own while there is something to read: a sweep
/// that failed, a map zoomed too far out, a first answer not yet in. Those hold
/// the bar open until they resolve, because those are the states somebody
/// actually needs the sentence for.
struct RealWorldTrafficBanner: View {

    let theme: FlightInfoTheme

    @ObservedObject private var traffic = RealWorldTraffic.shared

    /// Whether the bar is saying the whole thing or holding its place.
    ///
    /// Starts open, because the first thing anybody should see when the layer
    /// comes on is the sentence explaining it.
    @State private var isExpanded = true

    /// How long the open bar holds once there is nothing left to report.
    ///
    /// Long enough to read a title and a line under it without hurrying, short
    /// enough that somebody who was not reading it is not waiting on it. It is
    /// only ever spent once per thing-worth-saying — see `statusKind`.
    private static let dwell: TimeInterval = 6

    /// What the status is *saying*, as opposed to what it currently reads.
    ///
    /// The whole of why the folding is keyed on this and not on `status`
    /// itself: `live` carries a count, the count changes on every sweep, and a
    /// bar that reopened every fifteen seconds because one aeroplane left the
    /// area would be worse than one that never closed at all.
    private var statusKind: String {
        switch traffic.status {
        case .off:                return "off"
        case .tooFarOut:          return "far"
        case .waiting:            return "waiting"
        case .live:               return "live"
        case .failed(let reason): return "failed:\(reason)"
        }
    }

    /// How many real aircraft the last sweep found, when that is a number we
    /// can stand behind. Nil in every state the bar does not fold in, so the
    /// folded pill can never show a count belonging to a sweep that failed.
    private var count: Int? {
        if case .live(let found) = traffic.status { return found }
        return nil
    }

    var body: some View {
        HStack(spacing: isExpanded ? 9 : 6) {
            // The one thing on both faces, in the same place on both, so
            // folding and unfolding reads as the bar changing size rather than
            // as two different bars.
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RealWorldMark.tint)

            if isExpanded {
                sentence
                offButton
            } else {
                Text("\(count ?? 0)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()
            }
        }
        .padding(.leading, isExpanded ? 11 : 9)
        .padding(.trailing, isExpanded ? 5 : 9)
        .padding(.vertical, 6)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            // The one piece of chrome in the app wearing the layer's own
            // colour on its edge. It is what ties the bar to the mint
            // aeroplanes underneath it without a legend having to say so.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RealWorldMark.tint.opacity(0.55), lineWidth: 1)
        }
        // The whole bar is the fold, except where a control has already claimed
        // the touch — which is only ever the OFF button, and a button inside
        // this takes its own taps before this sees them.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(Motion.chrome) { isExpanded.toggle() }
        }
        // Re-run only when what the bar has to SAY changes, never when a count
        // ticks. Anything that is not the settled case holds it open: those are
        // the states the sentence exists for.
        .task(id: statusKind) {
            withAnimation(Motion.chrome) { isExpanded = true }
            guard count != nil else { return }

            try? await Task.sleep(nanoseconds: UInt64(Self.dwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.chrome) { isExpanded = false }
        }
        .environment(\.colorScheme, theme.colorScheme)
        .flightInfoLegible(theme)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Real-world traffic is on. \(traffic.status.label).")
        .accessibilityHint(
            isExpanded
                ? "Folds this away, leaving the count."
                : "Opens the bar, with the way to turn real-world traffic off."
        )
        .accessibilityAddTraits(.isButton)
    }

    private var sentence: some View {
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
        // Out sideways rather than by fading in place: the bar is closing up
        // around this, and a block that dissolves where it stands leaves the
        // pill to snap shut afterwards.
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
    }

    private var offButton: some View {
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
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
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

/// Who the real sky came from, at the foot of the window.
///
/// ## Why it is there
///
/// adsb.lol publish what their volunteers receive as open data under the ODbL,
/// and the routes come from the same place. Attribution is a condition of that
/// licence rather than a courtesy, so it is drawn rather than left to a
/// settings screen somebody may never open — and it names the *network*, since
/// what is behind every mark on that map is a few thousand people running a
/// receiver on a windowsill for nothing.
///
/// ## Why it is this small, and this far down
///
/// Because it is a credit and not a feature. It sits under the last card, in
/// the smallest type the app uses anywhere, greyed to the dimmest ink in the
/// theme: present and findable for anybody who goes looking, and never
/// competing with the aeroplane for attention. A credit that had to be scrolled
/// past would be worse than no credit at all, because it would teach people to
/// scroll past the window's foot.
///
/// Only on real traffic. The simulator's aircraft come off Infinite Flight's
/// own feed and owe adsb.lol nothing, and a line crediting a network that had
/// no part in what is on screen is a false statement about where the data came
/// from.
///
/// It opens their site, which is the other half of what the licence asks: a
/// credit nobody can follow is not really a credit.
struct RealWorldAttribution: View {

    let theme: FlightInfoTheme

    @Environment(\.openURL) private var openURL

    private static let home = URL(string: "https://adsb.lol")

    var body: some View {
        Button {
            if let home = Self.home { openURL(home) }
        } label: {
            Text(Self.credit)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                // The line wraps rather than shrinking. It is already the
                // smallest type in the app, and scaling it further would be
                // drawing something nobody can read as a way of saying it is
                // there.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel(Self.credit)
        .accessibilityHint("Opens adsb.lol")
    }

    /// Said once, here, so the wording cannot drift from what the licence
    /// actually requires.
    ///
    /// The route is named separately from the position on purpose. They arrive
    /// from the same network but they are not the same kind of fact: one is
    /// what a receiver heard, the other is a callsign matched against a
    /// database and checked for plausibility — see `RealWorldRoutes`. Calling
    /// it an estimate in the credit is the cheapest honest place to say so.
    private static let credit = """
    Live positions from adsb.lol — open data under ODbL, from volunteers \
    running receivers. Route estimated from the callsign.
    """
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
