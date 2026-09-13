import Combine
import SwiftUI

/// Whether the app is still behind its opening screen, and what lifts it.
///
/// ## Why a gate rather than a timer
///
/// The thing a tracker opens onto is a map, and a map is the slowest thing in
/// the app to become worth looking at: MapKit has tiles to fetch and the drawn
/// planet has a sphere to rasterise. Launching straight onto either means a few
/// hundred milliseconds of grey rectangle, or of a half-drawn world, before the
/// app looks like itself — and the first frame somebody sees is the one they
/// judge it by.
///
/// A fixed splash delay does not fix that; it only guesses. On a fast network
/// it wastes the user's time and on a slow one it lifts anyway, straight onto
/// the grey. So this waits for the map to say it has drawn, and the map is what
/// says it — `TrackerMapView` when MapKit finishes rendering, `GlobeCanvas`
/// when the planet has a world on it. Whichever is underneath reports; the
/// other never runs.
///
/// ## The two clamps
///
/// A floor, because a veil that vanishes in 90ms is a flash rather than an
/// opening, and a flash is worse than no veil at all.
///
/// A ceiling, because "wait for the map" cannot mean "wait forever". A device
/// in aeroplane mode with no cached tiles has a map that will never report, and
/// an opening screen that traps somebody there is a far worse bug than the one
/// this exists to fix. At the ceiling it lifts regardless and the app is
/// perfectly usable behind it — the map keeps loading in the open.
final class LaunchGate: ObservableObject {

    static let shared = LaunchGate()

    /// Whether the veil is still over the app.
    @Published private(set) var isCovered = true

    /// The least time the veil is up, so it is an opening rather than a blink.
    private static let floor: TimeInterval = 0.8

    /// The most, whatever the map is doing. See the note above.
    ///
    /// Six rather than something generous: MapKit reports when it has finished
    /// rendering what it *has*, not when it has everything, so even with no
    /// network this normally fires in well under a second. Reaching this at all
    /// means something is wrong, and the right answer to that is the app, not a
    /// longer look at the logo.
    private static let ceiling: TimeInterval = 6

    private var hasStarted = false
    private var hasDrawn = false
    private var isPastFloor = false

    /// The same answer as `isCovered`, as a plain `Bool`.
    ///
    /// So the hot path below can be turned away without reading a published
    /// property from the planet's draw thread. It is written only on the main
    /// queue, and the worst a stale read can do is cost one hop that then
    /// finds nothing to do.
    private var hasLifted = false

    private init() {}

    /// The veil is on screen; start its clocks.
    ///
    /// Called from the veil rather than at init, so the floor is measured from
    /// when somebody could actually see it — not from whenever the first thing
    /// in the app happened to touch this object.
    func begin() {
        guard !hasStarted, isCovered else { return }
        hasStarted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.floor) { [weak self] in
            self?.isPastFloor = true
            self?.lift()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ceiling) { [weak self] in
            // Deliberately not conditional on the map having reported. This is
            // the clamp, and a clamp that can be talked out of it is not one.
            self?.isPastFloor = true
            self?.hasDrawn = true
            self?.lift()
        }
    }

    /// Whichever map is underneath, saying it has drawn something.
    ///
    /// Safe to call on every frame — the planet does — and from any thread.
    func mapDidDraw() {
        guard !hasLifted else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.hasLifted else { return }
            self.hasDrawn = true
            self.lift()
        }
    }

    private func lift() {
        guard !hasLifted, hasDrawn, isPastFloor else { return }
        hasLifted = true
        withAnimation(.easeOut(duration: 0.45)) { isCovered = false }
    }
}

/// The opening screen.
///
/// Deliberately almost nothing: the app's mark on the same ground the terms
/// gate uses, breathing very slightly, and the name under it. No progress bar,
/// no spinner, no percentage — all three are ways of asking somebody to watch a
/// number, and none of them makes the map arrive sooner. What they do instead
/// is turn a pause into a wait.
///
/// The breath is two seconds a cycle and moves the mark by three per cent,
/// which is under what reads as motion and over what reads as a still image.
/// It exists so the screen looks alive rather than hung — that is the one
/// honest job a loading screen has, and it can be done without a number.
///
/// Under Reduce Motion it does not breathe. Somebody who has asked the system
/// for less movement is not asking for a gentler kind.
struct LaunchVeil: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isBreathing = false
    @State private var hasArrived = false

    /// The mark's size here and in `LaunchMark.imageset`, which is what the
    /// system's own launch screen draws at its natural size. The two have to
    /// agree or the handoff shows.
    private static let markSide: CGFloat = 96

    private var theme: FlightInfoTheme { appearance.theme }

    /// The breath, resolved. Written out rather than left as a ternary on
    /// `isBreathing` so that Reduce Motion rests at full size and full strength
    /// — with the animation never started, the raw flag would strand the mark
    /// at the small, dim end of a cycle it is not going to run.
    private var breathScale: CGFloat {
        guard !reduceMotion else { return 1 }
        return isBreathing ? 1.03 : 0.97
    }

    private var breathOpacity: Double {
        guard !reduceMotion else { return 1 }
        return isBreathing ? 1 : 0.88
    }

    var body: some View {
        ZStack {
            // Never faded, and never conditional. It is the only thing standing
            // between the eye and a map that is not ready to be looked at, so
            // anything that makes it briefly see-through defeats the screen.
            background

            mark
                // Faded in rather than switched on. The system's launch screen
                // is this same ground with nothing on it, so the first thing
                // that happens once the app is alive is the mark arriving —
                // which reads as the app starting rather than as one screen
                // being swapped for another.
                .opacity(hasArrived ? 1 : 0)
        }
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Inflight is starting")
        .onAppear {
            LaunchGate.shared.begin()

            withAnimation(.easeOut(duration: 0.35)) { hasArrived = true }

            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }

    /// The app's own mark, centred on its own rather than stacked with the word
    /// below it — so it sits where the eye already is when the system's launch
    /// screen hands over, instead of being pushed up by half a line of text.
    private var mark: some View {
        ZStack {
            Image("InflightLogo")
                .resizable()
                .scaledToFit()
                .frame(width: Self.markSide, height: Self.markSide)
                .scaleEffect(breathScale)
                .opacity(breathOpacity)

            Text("INFLIGHT")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3.4)
                .foregroundStyle(theme.textSecondary)
                .offset(y: Self.markSide / 2 + 22)
        }
    }

    /// The terms gate's ground, on purpose. These are the only two screens in
    /// the app that stand in front of the map, and two different first
    /// impressions is one too many.
    private var background: some View {
        LinearGradient(
            colors: theme.isLight
                ? [Color(white: 0.97), Color(white: 0.90)]
                : [Color(red: 0.03, green: 0.05, blue: 0.09),
                   Color(red: 0.06, green: 0.09, blue: 0.15)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
