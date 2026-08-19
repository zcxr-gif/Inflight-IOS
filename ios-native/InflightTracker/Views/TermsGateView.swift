import CoreLocation
import SwiftUI

/// The first thing anybody sees, and the only thing between them and the app.
///
/// The world turns for a moment and then asks. Both halves are deliberate: the
/// spin is what says "this is a flight tracker" before a single word does, and
/// the ask is what has to happen before anything is tracked at all.
///
/// ## Why the globe is drawn rather than mapped
///
/// This runs on a first launch, before any permission has been granted and
/// possibly before there is a network. A map view here would be a grey
/// rectangle waiting on tiles, which is a poor first impression and an
/// avoidable dependency. So the planet is drawn from the airport dataset the
/// app already ships — every field in the world as one point — which needs
/// nothing, fails at nothing, and happens to say exactly what the app is for.
struct TermsGateView: View {

    /// Called once the terms have been agreed to. The caller is what actually
    /// records it; this view's job ends at the tap.
    let onAccept: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var points: [CLLocationCoordinate2D] = []
    @State private var hasArrived = false

    private var theme: FlightInfoTheme { appearance.theme }

    /// How long the world turns before the question appears.
    private static let approach: TimeInterval = 2.4

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                globe
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 32)

                Spacer(minLength: 12)

                if hasArrived {
                    panel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // Every other surface in the app stamps this on itself, and this screen
        // needs it for the same reason plus one of its own: the wordmark is an
        // asset with a light and a dark artwork, and the catalog picks between
        // them by the resolved scheme. Without this the gate would draw its
        // background from `theme` and its logo from whatever the phone happens
        // to be set to — which, for somebody running the app in Light on a
        // phone in Dark, is a white logo on a white card.
        .environment(\.colorScheme, theme.colorScheme)
        .task {
            // Off the main actor: on a cold launch this is the first thing to
            // touch the dataset, and parsing eighteen thousand rows in front of
            // the first frame is exactly the stutter this screen must not have.
            let sampled = await Task.detached(priority: .userInitiated) {
                AirportStore.shared.sample(limit: 2600)
            }.value

            points = sampled

            if reduceMotion {
                hasArrived = true
            } else {
                try? await Task.sleep(nanoseconds: UInt64(Self.approach * 1_000_000_000))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                    hasArrived = true
                }
            }
        }
    }

    // MARK: - The world

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

    @ViewBuilder
    private var globe: some View {
        if reduceMotion {
            // One frame, no timeline. The same drawing, held still.
            Canvas { context, size in
                draw(in: context, size: size, spin: 0.35)
            }
            .aspectRatio(1, contentMode: .fit)
        } else {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    draw(in: context, size: size, spin: seconds / 26)
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    /// Orthographic projection of the airport set onto a sphere.
    ///
    /// The far hemisphere is dropped rather than drawn faintly — a sphere whose
    /// back you can see reads as a disc of noise, and the whole point of the
    /// image is that it is obviously a planet.
    private func draw(in context: GraphicsContext, size: CGSize, spin: Double) {
        let radius = min(size.width, size.height) / 2 * 0.92
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        // The globe itself, so the points sit on something rather than floating.
        let sphere = Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))

        context.fill(sphere, with: .radialGradient(
            Gradient(colors: theme.isLight
                ? [Color(white: 0.86), Color(white: 0.78)]
                : [Color(red: 0.10, green: 0.16, blue: 0.26),
                   Color(red: 0.04, green: 0.07, blue: 0.13)]),
            center: CGPoint(x: centre.x - radius * 0.25, y: centre.y - radius * 0.3),
            startRadius: 0,
            endRadius: radius * 1.5
        ))

        context.stroke(sphere, with: .color(theme.accent.opacity(0.22)), lineWidth: 1)

        // A slight tilt, so it reads as a planet seen from somewhere rather
        // than a diagram of one.
        let tilt = 0.38
        let rotation = spin * 2 * .pi

        for point in points {
            let latitude = point.latitude * .pi / 180
            let longitude = point.longitude * .pi / 180 + rotation

            // Standard sphere to Cartesian, then tilted about the x-axis.
            let x = cos(latitude) * sin(longitude)
            let yRaw = sin(latitude)
            let zRaw = cos(latitude) * cos(longitude)

            let y = yRaw * cos(tilt) - zRaw * sin(tilt)
            let z = yRaw * sin(tilt) + zRaw * cos(tilt)

            // Behind the horizon.
            guard z > 0 else { continue }

            let screen = CGPoint(
                x: centre.x + CGFloat(x) * radius,
                y: centre.y - CGFloat(y) * radius
            )

            // Points near the limb are seen at a glancing angle and are dimmer
            // and smaller, which is what stops the edge looking like a wall.
            let depth = z
            let dot = 1.1 + 1.5 * depth
            let alpha = 0.20 + 0.65 * depth

            context.fill(
                Path(ellipseIn: CGRect(
                    x: screen.x - dot / 2, y: screen.y - dot / 2,
                    width: dot, height: dot
                )),
                with: .color(theme.accent.opacity(alpha))
            )
        }
    }

    // MARK: - The question

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {

            // The mark, before the sentence. This is the screen somebody agrees
            // to something on, and the first thing it should establish is whose
            // terms they are.
            InflightWordmark(height: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(TermsStore.shared.isUpdate ? "We've updated our terms" : "Welcome to Inflight")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                Text(TermsStore.shared.isUpdate
                     ? "Have another look before carrying on — the same link, the same place."
                     : "Live Infinite Flight traffic, your own logbook, and a profile other pilots can find you by.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                link("Terms of Service", AppConfig.termsURL)
                Divider().overlay(theme.stroke)
                link("Privacy Policy", AppConfig.privacyURL)
            }
            .flightInfoSurface(theme, radius: theme.radiusMedium)

            Button {
                onAccept()
            } label: {
                Text("Agree and continue")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)

            Text("By continuing you agree to the Terms of Service and the Privacy Policy.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func link(_ title: String, _ url: URL?) -> some View {
        Link(destination: url ?? URL(string: "https://inflight.info")!) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}
