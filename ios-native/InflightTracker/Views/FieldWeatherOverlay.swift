import SwiftUI

/// What the map cannot draw of the weather close in over a field: a storm's
/// lightning, and fog's haze. The rain and snow are Mapbox's own particles —
/// see `TrackerMapView.syncPrecipitation`.
///
/// Deaf to touches, and never animated for somebody who has asked for less
/// movement. The lightning is a soft brightening rather than a strobe: it is
/// a few flickers every several seconds, at most a third of the way to white.
struct FieldWeatherOverlay: View {

    let weather: FieldWeather.Local

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash: Double = 0

    var body: some View {
        ZStack {
            if weather.kind == .fog {
                haze
                    .transition(.opacity)
            }

            Color.white
                .opacity(flash)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: weather.kind == .thunderstorm && !reduceMotion) {
            guard weather.kind == .thunderstorm, !reduceMotion else { return }
            await strike()
        }
        .animation(.easeInOut(duration: 0.8), value: weather.kind)
    }

    /// Fog thickest at the foot of the screen, where the near ground is, and
    /// thinning towards the top. Light fog and mist are a veil; heavy fog
    /// takes most of the map away, the way it takes the field away.
    private var haze: some View {
        let strength: Double
        switch weather.intensity {
        case .light: strength = 0.22
        case .moderate: strength = 0.34
        case .heavy: strength = 0.5
        }
        return LinearGradient(
            colors: [
                Color(white: 0.85).opacity(strength * 0.45),
                Color(white: 0.85).opacity(strength)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Flickers of lightning at irregular intervals, until the storm is no
    /// longer the weather here — the task is cancelled with it.
    private func strike() async {
        while !Task.isCancelled {
            let wait = Double.random(in: 3.5...9)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let peak = weather.intensity == .heavy ? 0.34 : 0.26
            withAnimation(.linear(duration: 0.04)) { flash = peak }
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.easeOut(duration: 0.12)) { flash = peak * 0.15 }
            try? await Task.sleep(nanoseconds: 140_000_000)
            // Most strokes come back once or twice.
            if Bool.random() {
                withAnimation(.linear(duration: 0.04)) { flash = peak * 0.8 }
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeOut(duration: 0.1)) { flash = peak * 0.1 }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
            withAnimation(.easeOut(duration: 0.7)) { flash = 0 }
        }
        flash = 0
    }
}

/// A field's weather as a picture, for behind its report in the airport panel:
/// rain streaking down, snow drifting, a storm flickering, fog moving across.
///
/// Drawn by `Canvas` from the time alone — every particle's position is a
/// function of the clock and its own index — so there is no state to keep and
/// nothing to reset. Still for somebody who has asked for less movement.
struct FieldWeatherScene: View {

    let kind: Metar.Precipitation
    let intensity: Metar.Intensity
    let isLight: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var amount: Double {
        switch intensity {
        case .light: return 0.5
        case .moderate: return 0.8
        case .heavy: return 1.2
        }
    }

    private var ink: Color { isLight ? Color(red: 0.25, green: 0.45, blue: 0.75) : Color(red: 0.6, green: 0.78, blue: 1) }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        switch kind {
        case .rain: rain(in: &context, size: size, time: time, count: Int(70 * amount), length: 14, speed: 380)
        case .drizzle: rain(in: &context, size: size, time: time, count: Int(60 * amount), length: 6, speed: 220)
        case .thunderstorm:
            lightning(in: &context, size: size, time: time)
            rain(in: &context, size: size, time: time, count: Int(110 * amount), length: 18, speed: 460)
        case .snow: snow(in: &context, size: size, time: time)
        case .fog: fog(in: &context, size: size, time: time)
        }
    }

    /// A stable pseudo-random number for a particle, 0..<1.
    private func seed(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index * 127 + salt * 311) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private func rain(in context: inout GraphicsContext, size: CGSize, time: Double, count: Int, length: Double, speed: Double) {
        let slant = 0.18
        var path = Path()
        for index in 0..<count {
            let laneSpeed = speed * (0.75 + 0.5 * seed(index, 1))
            let travel = size.height + length
            let y = (time * laneSpeed + seed(index, 2) * travel).truncatingRemainder(dividingBy: travel) - length
            let x = seed(index, 3) * (size.width + size.height * slant) - size.height * slant + y * slant
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length * slant, y: y + length))
        }
        context.stroke(path, with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    private func snow(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let count = Int(55 * amount)
        let flake = isLight ? Color(white: 0.55) : Color.white
        for index in 0..<count {
            let fall = 28 + 30 * seed(index, 1)
            let travel = size.height + 8
            let y = (time * fall + seed(index, 2) * travel).truncatingRemainder(dividingBy: travel) - 4
            let sway = sin(time * (0.8 + seed(index, 4)) + seed(index, 5) * 6.28) * 10
            let x = seed(index, 3) * size.width + sway
            let radius = 1.2 + 1.8 * seed(index, 6)
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(flake.opacity(0.55 + 0.35 * seed(index, 7)))
            )
        }
    }

    private func lightning(in context: inout GraphicsContext, size: CGSize, time: Double) {
        // A flicker for a fraction of a second every few seconds, at a rhythm
        // that never quite repeats.
        let phase = (time / 5.3).truncatingRemainder(dividingBy: 1)
        let second = (time / 7.9).truncatingRemainder(dividingBy: 1)
        let flash = max(phase < 0.03 ? 1 - phase / 0.03 : 0, second < 0.02 ? 0.7 * (1 - second / 0.02) : 0)
        guard flash > 0 else { return }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.white.opacity((isLight ? 0.35 : 0.22) * flash))
        )
    }

    private func fog(in context: inout GraphicsContext, size: CGSize, time: Double) {
        var blurred = context
        blurred.addFilter(.blur(radius: 18))
        let veil = isLight ? Color(white: 0.6) : Color(white: 0.85)
        for index in 0..<6 {
            let width = size.width * (0.6 + 0.5 * seed(index, 1))
            let height = size.height * (0.25 + 0.2 * seed(index, 2))
            let speed = 6 + 10 * seed(index, 3)
            let span = size.width + width
            let x = (time * speed + seed(index, 4) * span).truncatingRemainder(dividingBy: span) - width
            let y = size.height * seed(index, 5) - height / 2
            blurred.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: width, height: height)),
                with: .color(veil.opacity(0.22 * amount))
            )
        }
    }
}
