import CoreLocation
import SwiftUI
import UIKit

/// The Horizon flight window, drawn the way the website draws it.
///
/// Not the app's cards in Horizon's colours: the web's own window, piece for
/// piece, measured off `HORIZON_WINDOW_CSS` in the tracker — the photo header
/// with its eased fade into the window, the eyebrow over the callsign, the
/// route strip with the aircraft riding a dashed line, the pilot button, the
/// glance grid, the pilot status with its three timers, the destination card,
/// the sectioned cards with their icon tiles, the speed and altitude graph and
/// the Navigation and Aircraft cards. Every size, weight, opacity and radius
/// below is the stylesheet's, in points for its pixels.
///
/// What the app has that the web window does not (Keep, the instruments, the
/// filed route, the sim's readout) is fitted in where the web puts its nearest
/// equivalent, in the same card material.

// MARK: - The palette

/// The web's `--sr-*` custom properties, worked out from the chosen colour
/// exactly as `horizonTokens` and `applyHorizonColor` do.
struct HorizonPalette {

    let colour: HorizonColour

    /// The photograph's own hue, settled (see `HorizonGlow`). Nil when there
    /// is no photo, or it is too grey to mean anything.
    var glow: (red: Double, green: Double, blue: Double)?

    /// A picture is behind the window (Background › Aircraft or Your image).
    var hasImageBackground = false

    var isLight: Bool { colour.isLight }

    /// `--sr-ink-rgb`: white on a dark colour, black on a light one.
    func ink(_ opacity: Double) -> Color {
        (isLight ? Color.black : Color.white).opacity(opacity)
    }

    var bg: Color { colour.color }

    func bg(_ opacity: Double) -> Color { colour.color.opacity(opacity) }

    var text: Color {
        isLight
            ? Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1b / 255)
            : Color(red: 0xee / 255, green: 0xf0 / 255, blue: 0xf4 / 255)
    }

    var muted: Color { ink(isLight ? 0.62 : 0.6) }
    var faint: Color { ink(isLight ? 0.45 : 0.42) }

    var accent: Color {
        isLight
            ? Color(red: 0x1f / 255, green: 0x6f / 255, blue: 0xae / 255)
            : Color(red: 0x8c / 255, green: 0xc8 / 255, blue: 0xee / 255)
    }

    var accentSoft: Color {
        isLight
            ? Color(red: 31 / 255, green: 111 / 255, blue: 174 / 255).opacity(0.3)
            : Color(red: 140 / 255, green: 200 / 255, blue: 238 / 255).opacity(0.32)
    }

    var surfaceHi: Color { ink(isLight ? 0.055 : 0.06) }
    var line: Color { ink(isLight ? 0.09 : 0.07) }

    /// `--sr-tint`: the window colour lightly mixed with the photo's colour —
    /// 82 to 18 on a dark colour, 88 to 12 on a light one. Plain window colour
    /// without a glow.
    var tint: Color {
        guard let glow = glow else { return bg }
        let keep = isLight ? 0.88 : 0.82
        return Color(
            red: colour.red * keep + glow.red * (1 - keep),
            green: colour.green * keep + glow.green * (1 - keep),
            blue: colour.blue * keep + glow.blue * (1 - keep)
        )
    }

    /// The web's status colours (times, the on-time badge) are pale tints made
    /// for a dark window, and on a light one it deepens them with
    /// `brightness(0.62) saturate(1.3)`. The brightness half is what reads.
    func status(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        let k = isLight ? 0.62 : 1
        return Color(red: red * k, green: green * k, blue: blue * k)
    }
}

/// `sampleHorizonGlow`, ported: a saturation-weighted average of the photo at
/// 24 × 24, its hue kept, its saturation settled into 0.4…0.7 and its
/// lightness set to 0.55.
enum HorizonGlow {

    private final class Box {
        let value: (red: Double, green: Double, blue: Double)?
        init(_ value: (red: Double, green: Double, blue: Double)?) { self.value = value }
    }

    private static let cache = NSCache<UIImage, Box>()

    static func colour(of image: UIImage?) -> (red: Double, green: Double, blue: Double)? {
        guard let image = image else { return nil }
        if let hit = cache.object(forKey: image) { return hit.value }
        let value = sample(image)
        cache.setObject(Box(value), forKey: image)
        return value
    }

    private static func sample(_ image: UIImage) -> (red: Double, green: Double, blue: Double)? {
        guard let cg = image.cgImage else { return nil }
        let n = 24
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        // Drawn inside the closure: the buffer's address is only good there.
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: n,
                height: n,
                bitsPerComponent: 8,
                bytesPerRow: n * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]), pg = Double(pixels[i + 1]), pb = Double(pixels[i + 2])
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let weight = 0.1 + sat * sat
            r += pr * weight; g += pg * weight; b += pb * weight; w += weight
        }
        guard w > 0 else { return nil }
        let R = r / w / 255, G = g / w / 255, B = b / w / 255
        let mx = max(R, G, B), mn = min(R, G, B), l = (mx + mn) / 2
        let sat = mx == mn ? 0 : (l > 0.5 ? (mx - mn) / (2 - mx - mn) : (mx - mn) / (mx + mn))
        guard sat >= 0.08 else { return nil }

        var h: Double
        if mx == R { h = (G - B) / (mx - mn) + (G < B ? 6 : 0) }
        else if mx == G { h = (B - R) / (mx - mn) + 2 }
        else { h = (R - G) / (mx - mn) + 4 }
        h /= 6

        let s2 = min(0.7, max(0.4, sat)), l2 = 0.55
        let q = l2 < 0.5 ? l2 * (1 + s2) : l2 + s2 - l2 * s2
        let p = 2 * l2 - q
        func hue(_ t0: Double) -> Double {
            let t = (t0 + 1).truncatingRemainder(dividingBy: 1)
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }
}

// MARK: - Shared pieces

/// The web's card material: a faint top-lit gradient, a hairline, an inner
/// highlight on the top edge and a soft drop. Frosted glass over a background
/// picture, white glass on a light colour.
private struct HorizonCardMaterial: ViewModifier {

    let palette: HorizonPalette
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                if palette.hasImageBackground {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(palette.bg(0.55))
                    }
                } else if palette.isLight {
                    shape.fill(LinearGradient(
                        colors: [Color.white.opacity(0.7), Color.white.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    ))
                } else {
                    shape.fill(LinearGradient(
                        colors: [palette.ink(0.055), palette.ink(0.025)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
            }
            .overlay {
                // The hairline, with the inner highlight folded into its top.
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: palette.isLight ? Color.white.opacity(0.8) : palette.ink(0.13), location: 0),
                            .init(color: palette.line, location: 0.12),
                            .init(color: palette.line, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.06 : 0.14), radius: palette.isLight ? 11 : 13, y: palette.isLight ? 8 : 10)
    }
}

extension View {
    fileprivate func horizonCard(_ palette: HorizonPalette, radius: CGFloat = 20) -> some View {
        modifier(HorizonCardMaterial(palette: palette, radius: radius))
    }
}

/// A section heading: an accent icon tile, the title, and a hairline that runs
/// out to the edge.
struct HorizonSectionHeading: View {

    let title: String
    let symbol: String
    let palette: HorizonPalette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 26, height: 26)
                .background(palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .fixedSize()

            LinearGradient(colors: [palette.line, palette.line.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(minWidth: 20, maxWidth: .infinity)
                .frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What the route strip and the timers both need: the route, the times either
/// side of it, and how long is left.
struct HorizonRouteFacts {

    let flight: Flight
    let track: [TrackPoint]

    var progress: FlightProgress? { FlightProgress(flight: flight) }

    var departureIcao: String { progress?.departure.icao ?? flight.departureIcao ?? "----" }
    var arrivalIcao: String { progress?.arrival.icao ?? flight.arrivalIcao ?? "----" }

    var takeoff: Date? { TrackPoint.lastTakeoff(in: track) }

    var firstSeen: Date? {
        track.compactMap(\.date).min() ?? FlightTrailStore.shared.firstSeen(for: flight.id)
    }

    /// When the clock started: the take-off when the path shows one, the first
    /// sight of the aircraft otherwise.
    var started: Date? { takeoff ?? firstSeen }

    /// `ETE`: the route, speed profile and landing queue — see
    /// `EnrouteEstimator` — once the aircraft is fast enough to mean anything.
    var remaining: TimeInterval? {
        progress?.estimatedTimeEnroute(for: flight)
    }

    /// The ETE as a clock time, or — while it is too slow to have one — the
    /// web's `computeArrivalTimeInfo`: remaining distance at 400 kt.
    var arrival: Date? {
        if let remaining = remaining { return Date().addingTimeInterval(remaining) }
        guard let progress = progress, progress.remainingNM > 0 else { return nil }
        let speed = flight.groundSpeedKnots > 150 ? flight.groundSpeedKnots : 400
        let hours = progress.remainingNM / speed
        guard hours > 0, hours < 48 else { return nil }
        return Date().addingTimeInterval(hours * 3600)
    }

    static func zulu(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func clock(_ interval: TimeInterval?) -> String {
        guard let interval = interval, interval.isFinite, interval >= 0 else { return "--:--" }
        let minutes = Int((interval / 60).rounded())
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// The web's phase colours: climb green, cruise blue, descent amber, ground
/// grey.
private func horizonPhaseColour(_ phase: FlightPhase) -> Color {
    switch phase {
    case .climb: return Color(red: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255)
    case .cruise: return Color(red: 0x38 / 255, green: 0xbd / 255, blue: 0xf8 / 255)
    case .descent: return Color(red: 0xfb / 255, green: 0xbf / 255, blue: 0x24 / 255)
    case .ground: return Color(red: 0x94 / 255, green: 0xa3 / 255, blue: 0xb8 / 255)
    }
}

// MARK: - The header

/// The photo header: the photograph full width at its own height, a soft scrim
/// at the top, an eased fade into the window at the bottom, and the identity
/// on the photo's lower edge.
struct FlightHorizonHeader: View {

    let flight: Flight
    let palette: HorizonPalette
    let image: UIImage?
    let contributor: String?
    var photos: [AircraftPhoto] = []
    var isAutoplaying = true
    let width: CGFloat

    /// The tallest the photo may be drawn (the peek sets one).
    var maxPhotoHeight: CGFloat = .greatestFiniteMagnitude

    /// The round glass buttons at the top right. Nil in the peek, which is a
    /// drag target from edge to edge.
    var actions: AnyView? = nil

    /// A real photograph's credit, which is a control and has to stay one.
    var realCredit: AnyView? = nil
    var realLink: URL? = nil

    @State private var page = 0

    /// Where the controls in the photograph's top corners start: under the
    /// window's pull band, which runs the full width of the top edge and
    /// would otherwise take the touches meant for them.
    static let controlTop: CGFloat = WindowGrabber.bandHeight + 6

    /// `fitHorizonHero`: full width, never zoomed past it, the band clamped
    /// between 120 and 300.
    private var photoHeight: CGFloat {
        let natural: CGFloat
        if let image = image, image.size.width > 0 {
            natural = width * image.size.height / image.size.width
        } else {
            natural = 220
        }
        return min(min(max(natural, 120), 300), maxPhotoHeight)
    }

    private var headerHeight: CGFloat { photoHeight + 48 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            photo
                .frame(width: width, height: photoHeight)
                .clipped()
                .mask { photoMask }
                .onTapGesture {
                    guard let link = realLink else { return }
                    UIApplication.shared.open(link)
                }

            overlay
                .frame(width: width, height: headerHeight)
                .allowsHitTesting(false)

            identity
                .frame(width: width, height: headerHeight, alignment: .bottomLeading)
                .allowsHitTesting(false)

            if photos.count > 1 {
                dots
                    .frame(width: width, height: headerHeight, alignment: .bottomTrailing)
            }

            if let realCredit = realCredit {
                realCredit
                    .padding(.top, Self.controlTop)
                    .padding(.leading, 16)
            } else if let contributor = currentContributor {
                credit(contributor)
                    .padding(.top, 16)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }

            if let actions = actions {
                actions
                    .padding(.top, Self.controlTop)
                    .padding(.trailing, 16)
                    .frame(width: width, alignment: .topTrailing)
            }
        }
        .frame(width: width, height: headerHeight, alignment: .top)
        .background(palette.hasImageBackground ? Color.clear : palette.tint)
        .onChange(of: photos.count) { _, count in
            if page >= count { page = 0 }
        }
    }

    @ViewBuilder
    private var photo: some View {
        if photos.count > 1 {
            AircraftPhotoPager(
                photos: photos,
                preloaded: image,
                spriteKey: flight.spriteKey,
                theme: .horizon(palette.colour),
                isAutoplaying: isAutoplaying,
                page: $page
            )
        } else {
            AircraftPhotoImage(
                image: image,
                spriteKey: flight.spriteKey,
                theme: .horizon(palette.colour),
                iconSize: 64,
                contentMode: .fill
            )
        }
    }

    /// Over a background picture the photo itself fades out (the window's
    /// picture shows through); over a colour the overlay does the fading.
    @ViewBuilder
    private var photoMask: some View {
        if palette.hasImageBackground {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Rectangle()
        }
    }

    /// `.ac-header-overlay`: rgba(12,14,18,.34) easing to nothing over the top
    /// 72 points, then the tint eased in along a curve from 36% of the photo
    /// down to its foot, so it melts into the window with no band.
    private var overlay: some View {
        let total = headerHeight
        let h = photoHeight
        let scrim = Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255)
        let at = { (y: CGFloat) in min(max(y / total, 0), 1) }

        let stops: [Gradient.Stop]
        if palette.hasImageBackground {
            stops = [
                .init(color: scrim.opacity(0.34), location: 0),
                .init(color: scrim.opacity(0), location: at(72)),
                .init(color: palette.bg(0), location: at(h * 0.45)),
                .init(color: palette.bg(Double(FlightInfoAppearance.shared.horizonDim) * 0.5), location: at(h)),
                .init(color: palette.bg(0), location: 1),
            ]
        } else {
            let tint = palette.tint
            stops = [
                .init(color: scrim.opacity(0.34), location: 0),
                .init(color: scrim.opacity(0), location: at(72)),
                .init(color: tint.opacity(0), location: at(h * 0.36)),
                .init(color: tint.opacity(0.06), location: at(h * 0.46)),
                .init(color: tint.opacity(0.16), location: at(h * 0.56)),
                .init(color: tint.opacity(0.32), location: at(h * 0.66)),
                .init(color: tint.opacity(0.52), location: at(h * 0.76)),
                .init(color: tint.opacity(0.72), location: at(h * 0.85)),
                .init(color: tint.opacity(0.89), location: at(h * 0.93)),
                .init(color: tint, location: at(h)),
                .init(color: tint, location: 1),
            ]
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    /// One eyebrow line — airline and aircraft type in small spaced capitals —
    /// then the callsign.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.05)
                    .foregroundStyle(palette.ink(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: textShadow(0.4), radius: palette.hasImageBackground ? 6 : 4, y: 1)
            }

            Text(flight.displayName)
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.21)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .shadow(color: textShadow(0.35), radius: palette.hasImageBackground ? 6 : 5, y: 1)
                .motionWords(flight.displayName)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .padding(.trailing, photos.count > 1 ? 70 : 0)
    }

    private func textShadow(_ opacity: Double) -> Color {
        if palette.isLight { return .clear }
        return palette.hasImageBackground ? palette.bg(0.9) : Color.black.opacity(opacity)
    }

    private var eyebrow: String {
        let livery = flight.liveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let aircraft = flight.aircraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [livery, aircraft].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private var currentContributor: String? {
        guard photos.count > 1, photos.indices.contains(page) else { return contributor }
        return photos[page].contributor
    }

    /// A quiet glass tag at the photo's top left.
    private func credit(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.86))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.34))
            }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: width * 0.52, alignment: .leading)
    }

    /// The swipe dots, bottom right, level with the callsign. The active one
    /// stretches into a short pill.
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(photos.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == page ? 0.95 : 0.45))
                    .frame(width: index == page ? 16 : 6, height: 6)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.35)) { page = index } }
            }
        }
        .invertedWhen(palette.isLight)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: page)
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
}

private extension View {
    @ViewBuilder
    func invertedWhen(_ on: Bool) -> some View {
        if on { self.colorInvert() } else { self }
    }
}

/// One round glass button on the photo.
struct HorizonHeroButtonFace: View {

    let symbol: String
    var isOn = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isOn
                ? Color(red: 0x8c / 255, green: 0xc8 / 255, blue: 0xee / 255)
                : Color.white.opacity(0.92))
            .frame(width: 34, height: 34)
            .background {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color(red: 18 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.34))
            }
            .overlay {
                Circle().strokeBorder(
                    isOn
                        ? Color(red: 140 / 255, green: 200 / 255, blue: 238 / 255).opacity(0.55)
                        : Color.white.opacity(0.14),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.16), radius: 7, y: 4)
            .environment(\.colorScheme, .dark)
            .contentShape(Circle())
    }
}

/// The hero buttons: Keep (the web's pin), Replay and Share.
struct FlightHorizonActions: View {

    let flight: Flight
    let track: [TrackPoint]
    let onReplay: () -> Void

    @ObservedObject private var entitlements = Entitlements.shared
    @State private var isShowingPaywall = false

    private var canReplay: Bool { track.count >= FlightReplay.minimumPoints }

    var body: some View {
        HStack(spacing: 8) {
            FlightKeepMenu(flight: flight, theme: .horizon(HorizonColour(hex: HorizonColour.defaultHex)), heroButton: true)

            Button {
                if entitlements.has(.replay) { onReplay() } else { isShowingPaywall = true }
            } label: {
                HorizonHeroButtonFace(symbol: entitlements.has(.replay) ? "play.fill" : "lock.fill")
            }
            .buttonStyle(.plain)
            .disabled(!canReplay)
            .opacity(canReplay ? 1 : 0.45)
            .accessibilityLabel("Replay flight")

            ShareLink(item: FlightActionRow.summary(for: flight)) {
                HorizonHeroButtonFace(symbol: "camera.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share this flight")
        }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .replay) }
    }
}

// MARK: - The route strip

/// Two airports side by side, one full-width progress line under them, then
/// distance · phase · time left in a single row. Part of the header, not a
/// card: it ends on a hairline across the window.
struct FlightHorizonRouteStrip: View {

    let flight: Flight
    let track: [TrackPoint]
    let palette: HorizonPalette
    var onSelectAirport: (Airport) -> Void = { _ in }

    private var facts: HorizonRouteFacts { HorizonRouteFacts(flight: flight, track: track) }

    var body: some View {
        let facts = self.facts
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                node(
                    icao: facts.departureIcao,
                    airport: facts.progress?.departure,
                    time: departureTime(facts),
                    alignment: .leading
                )
                node(
                    icao: facts.arrivalIcao,
                    airport: facts.progress?.arrival,
                    time: arrivalTime(facts),
                    alignment: .trailing
                )
            }

            progressLine(fraction: facts.progress?.fraction ?? 0)
                .padding(.top, 16)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Text(facts.progress.map { "\(Int($0.remainingNM.rounded())) NM" } ?? "--- NM")
                    .frame(maxWidth: .infinity, alignment: .leading)
                phasePill
                Text("ETE: \(HorizonRouteFacts.clock(facts.remaining))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .padding(.top, 8)
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hasImageBackground ? palette.ink(0.1) : palette.line)
                .frame(height: 1)
        }
    }

    private struct TimeInfo {
        let text: String
        let label: String
        let colour: Color
    }

    /// `computeDepartureTimeInfo`: the take-off off the path is ACTUAL, blue;
    /// anything worked out is ESTIMATED, grey.
    private func departureTime(_ facts: HorizonRouteFacts) -> TimeInfo {
        if let takeoff = facts.takeoff {
            return TimeInfo(text: "\(HorizonRouteFacts.zulu(takeoff)) Z", label: "actual", colour: palette.status(0x38 / 255, 0xbd / 255, 0xf8 / 255))
        }
        if let seen = facts.firstSeen {
            return TimeInfo(text: "\(HorizonRouteFacts.zulu(seen)) Z", label: "estimated", colour: palette.status(0x94 / 255, 0xa3 / 255, 0xb8 / 255))
        }
        return TimeInfo(text: "--:--", label: "", colour: palette.status(0x64 / 255, 0x74 / 255, 0x8b / 255))
    }

    private func arrivalTime(_ facts: HorizonRouteFacts) -> TimeInfo {
        if let arrival = facts.arrival {
            return TimeInfo(text: "\(HorizonRouteFacts.zulu(arrival)) Z", label: "estimated", colour: palette.status(0x94 / 255, 0xa3 / 255, 0xb8 / 255))
        }
        return TimeInfo(text: "--:--", label: "", colour: palette.status(0x64 / 255, 0x74 / 255, 0x8b / 255))
    }

    /// ICAO and flag, the field's name, "21:37 Z · estimated", the gate tag.
    private func node(icao: String, airport: Airport?, time: TimeInfo, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing
        return VStack(alignment: alignment, spacing: 0) {
            Button {
                if let airport = airport { onSelectAirport(airport) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(icao)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(0.66)
                        .foregroundStyle(palette.text)
                        .shadow(color: palette.hasImageBackground && !palette.isLight ? palette.bg(0.9) : .clear, radius: 6, y: 1)
                    if let flag = airport?.flag, !flag.isEmpty {
                        Text(flag).font(.system(size: 11))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .disabled(airport == nil)

            if let name = airport?.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            } else {
                Spacer().frame(height: 4)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(time.text)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                if !time.label.isEmpty {
                    Text("·").font(.system(size: 11, weight: .medium)).opacity(0.7)
                    Text(time.label).font(.system(size: 11, weight: .medium)).opacity(0.7)
                }
            }
            .foregroundStyle(time.colour)
            .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: alignment == .leading ? "door.left.hand.open" : "door.left.hand.closed")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.faint)
                Text("Gate ---")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(palette.ink(0.06), in: Capsule())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    /// Origin dot filled, the flown part solid in the accent with the aircraft
    /// riding its end, the rest dashed, the destination dot hollow.
    private func progressLine(fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = width * CGFloat(min(max(fraction, 0), 1))
            let mid = proxy.size.height / 2

            ZStack(alignment: .topLeading) {
                // Still to fly: dashed, 6 on and 5 off.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: mid))
                    path.addLine(to: CGPoint(x: width, y: mid))
                }
                .stroke(palette.ink(0.26), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))

                Capsule()
                    .fill(LinearGradient(colors: [palette.accentSoft, palette.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x, 0), height: 4)
                    .shadow(color: palette.accent.opacity(0.55), radius: 5)
                    .offset(y: mid - 2)

                Circle()
                    .fill(palette.accent)
                    .frame(width: 8, height: 8)
                    .position(x: 0, y: mid)

                Circle()
                    .fill(palette.hasImageBackground ? palette.bg : palette.tint)
                    .overlay { Circle().strokeBorder(palette.ink(0.35), lineWidth: 1.5) }
                    .frame(width: 8, height: 8)
                    .position(x: width, y: mid)

                silhouette
                    .frame(width: 24, height: 24)
                    .position(x: x, y: mid)
            }
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of the way")
    }

    /// The aircraft's own map silhouette, turned to face along the line, in
    /// the text colour.
    @ViewBuilder
    private var silhouette: some View {
        if let icon = PlaneSprites.shared.icon(
            forKey: flight.spriteKey,
            selected: false,
            tint: UIColor(palette.text)
        ) {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(90))
        } else {
            Image(systemName: "airplane")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
        }
    }

    private var phasePill: some View {
        let phase = FlightPhase.from(flight)
        // The organised track, when the aircraft is flying one, in the
        // track's own colour — re-read on every packet, as the flight is.
        let track = NatTrackService.shared.track(for: flight)
        return HStack(spacing: 6) {
            Circle()
                .fill(track.map { Color(uiColor: NatTrackStyle.colour(for: $0.name)) } ?? horizonPhaseColour(phase))
                .frame(width: 6, height: 6)
            Text(track.map { "\(phase.label) · Track \($0.name)" } ?? phase.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink(0.88))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(palette.ink(0.06), in: Capsule())
        .fixedSize()
    }
}

// MARK: - The peek

/// The top of the window, which is what the peek shows: the photo header and
/// the route strip, on the tint.
struct FlightHorizonPeek: View {

    let flight: Flight
    let palette: HorizonPalette
    let image: UIImage?
    let contributor: String?
    var photos: [AircraftPhoto] = []
    var isAutoplaying = true
    let width: CGFloat
    var heroCeiling: CGFloat = .greatestFiniteMagnitude
    var track: [TrackPoint] = []
    var realCredit: AnyView? = nil
    var realLink: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            FlightHorizonHeader(
                flight: flight,
                palette: palette,
                image: image,
                contributor: contributor,
                photos: photos,
                isAutoplaying: isAutoplaying,
                width: width,
                maxPhotoHeight: heroCeiling,
                realCredit: realCredit,
                realLink: realLink
            )
            FlightHorizonRouteStrip(flight: flight, track: track, palette: palette)
                .allowsHitTesting(false)
        }
        // No gap of its own under the strip: the strip ends on the same 18
        // points the other peeks do, and the dock adds the home indicator's
        // band underneath.
        .frame(width: width)
        .background(palette.hasImageBackground ? Color.clear : palette.tint)
    }
}

// MARK: - The pilot button

/// The pilot, as the web's tab-bar button: their picture (or initials), their
/// name and "View profile ›" — and, when they have a profile, their banner
/// behind it all under a scrim, the way everybody else sees it on the web.
struct FlightHorizonPilotButton: View {

    let flight: Flight
    let palette: HorizonPalette

    @State private var profile: PilotProfile?
    @State private var opened: ProfileLink?
    @State private var atcRank: Int?
    @StateObject private var banner = RemoteImageLoader()

    /// MOD and IFATC, as they apply.
    private var roles: [PilotRole] {
        PilotRole.roles(
            username: flight.username,
            atcRank: atcRank ?? ControllerDirectory.shared.rank(forUsername: flight.username)
        )
    }

    private var pilot: String? {
        guard let username = flight.username, !username.isEmpty else { return nil }
        return username
    }

    var body: some View {
        Group {
            if let pilot = pilot {
                Button {
                    if let handle = profile?.handle {
                        opened = .handle(handle)
                    } else {
                        opened = .pilot(pilot)
                    }
                } label: {
                    face(pilot)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(pilot). View profile")
            }
        }
        .task(id: flight.username) {
            profile = nil
            banner.load(nil)
            guard let pilot = pilot else { return }
            let card = await PilotDirectory.shared.card(ifUsername: pilot)
            guard !Task.isCancelled else { return }
            profile = card
            banner.load(card?.bannerURL)
        }
        .task(id: flight.userId ?? flight.username ?? "") {
            atcRank = nil
            guard flight.origin == .infiniteFlight else { return }
            let stats = await PilotStatsService.shared.stats(for: flight)
            guard !Task.isCancelled else { return }
            atcRank = stats?.atcRank
        }
        .sheet(item: $opened) { link in PublicProfileView(link: link) }
    }

    private var hasProfile: Bool { profile != nil }

    private var textColour: Color { hasProfile ? .white : palette.text }

    private func face(_ pilot: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return HStack(spacing: 12) {
            avatar(pilot)

            Text(profile?.displayName ?? pilot)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(0.135)
                .foregroundStyle(textColour)
                .lineLimit(1)

            ForEach(roles, id: \.badge) { role in
                PilotRoleBadge(role: role, isLight: palette.isLight && !hasProfile)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("View profile")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(textColour.opacity(0.75))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255))
            }
        }
        .shadow(color: hasProfile ? .black.opacity(0.6) : .clear, radius: 2, y: 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { ground(shape) }
        .clipShape(shape)
        .overlay {
            if !hasProfile { shape.strokeBorder(palette.line, lineWidth: 1) }
        }
        .shadow(color: .black.opacity(palette.isLight ? 0.08 : 0.2), radius: palette.isLight ? 9 : 12, y: palette.isLight ? 6 : 8)
        .contentShape(shape)
        .animation(.easeOut(duration: 0.45), value: hasProfile)
        .animation(.easeOut(duration: 0.45), value: banner.image != nil)
    }

    /// Their banner photo over their painted preset, under a scrim so the
    /// name reads on any photograph. The window's own surface without a
    /// profile.
    @ViewBuilder
    private func ground(_ shape: RoundedRectangle) -> some View {
        if let profile = profile {
            ZStack {
                BannerPreset.resolved(profile.bannerPreset).gradient
                if let image = banner.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.62), Color.black.opacity(0.28)],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        } else if palette.hasImageBackground {
            ZStack { shape.fill(.ultraThinMaterial); shape.fill(palette.bg(0.55)) }
        } else {
            shape.fill(palette.surfaceHi)
        }
    }

    private func avatar(_ pilot: String) -> some View {
        let initials = String(pilot.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        return ZStack {
            Circle().fill(palette.isLight && !hasProfile
                ? Color(red: 0xd9 / 255, green: 0xdc / 255, blue: 0xe2 / 255)
                : Color(red: 0x3a / 255, green: 0x40 / 255, blue: 0x4b / 255))
            if let url = profile?.avatarURL {
                PilotAvatar(url: url, initials: initials, side: 40)
            } else {
                Text(initials)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.isLight && !hasProfile ? Color(red: 0x1b / 255, green: 0x1e / 255, blue: 0x24 / 255) : .white)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .overlay {
            // A Pro pilot's accent on the ring.
            Circle().strokeBorder(
                profile?.accentColor
                    ?? (palette.isLight && !hasProfile ? Color.black.opacity(0.12) : Color.white.opacity(0.7)),
                lineWidth: profile?.accentColor == nil ? 1 : 2
            )
        }
    }
}

/// A quiet line under the pilot whenever the window is wearing the pilot's
/// look rather than the viewer's: who styled it, a way to stop seeing pilots'
/// styles, and a report — the web's `mountOwnerStyleNote`.
struct FlightHorizonOwnerNote: View {

    let handle: String
    let palette: HorizonPalette

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @State private var isReporting = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 10))
                .opacity(0.8)
            Text("Window styled by \(Text("@\(handle)").fontWeight(.semibold))")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Button {
                    appearance.showsPilotStyles = false
                } label: {
                    Label("Hide pilots' window styles", systemImage: "eye.slash")
                }
                Button(role: .destructive) {
                    isReporting = true
                } label: {
                    Label("Report @\(handle)", systemImage: "flag")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 20)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Window style options")
        }
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 2)
        .sheet(isPresented: $isReporting) {
            ReportProfileSheet(handle: handle) { reason, detail in
                do {
                    try await PilotDirectory.shared.report(handle: handle, reason: reason, detail: detail)
                    return nil
                } catch {
                    return (error as? SupabaseData.Failure)?.message ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - At a glance

/// The four live numbers in one quiet card — two by two on a phone, as the
/// web lays them out under 400 points.
struct FlightHorizonGlance: View {

    let flight: Flight
    let palette: HorizonPalette

    var body: some View {
        VStack(spacing: 14) {
            row(
                cell("Altitude", symbol: "arrow.up", value: Format.number(flight.altitudeFeet), unit: "ft", figure: flight.altitudeFeet),
                cell("Ground speed", symbol: "gauge.open.with.lines.needle.33percent", value: Format.number(flight.groundSpeedKnots), unit: "kt", figure: flight.groundSpeedKnots)
            )
            row(
                cell("Vertical speed", symbol: "arrow.up.arrow.down", value: Format.signed(flight.verticalSpeedFPM), unit: "fpm", figure: flight.verticalSpeedFPM),
                cell("Heading", symbol: "location.north.fill", value: "\(Format.heading(flight.heading))°", unit: nil, figure: flight.heading, turns: true)
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .horizonCard(palette)
    }

    private func row<A: View, B: View>(_ a: A, _ b: B) -> some View {
        HStack(spacing: 0) {
            a
            Rectangle().fill(palette.line).frame(width: 1)
            b
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(
        _ title: String,
        symbol: String,
        value: String,
        unit: String?,
        figure: Double,
        turns: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent.opacity(0.9))
                    .rotationEffect(.degrees(turns && flight.heading.isFinite ? flight.heading : 0))
                    .animation(.easeOut(duration: 0.8), value: flight.heading)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .motionFigure(figure)
                if let unit = unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.faint)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pilot status and timers

/// Status on top — the state's icon on a wash of its colour, the state, a live
/// dot — then Elapsed, Remaining and Total in a row under a hairline.
struct FlightHorizonStatus: View {

    let flight: Flight
    let track: [TrackPoint]
    let palette: HorizonPalette

    @State private var pinging = false

    private struct StateLook {
        let title: String
        let detail: String
        let symbol: String
        let colour: Color
    }

    /// The web's four: ACTIVE green, AWAY yellow, PARKED slate, AP+ blue.
    private var look: StateLook {
        switch flight.pilotState {
        case .active:
            return StateLook(title: "Active", detail: "Pilot is active", symbol: "person.fill.checkmark",
                             colour: Color(red: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255))
        case .away:
            return StateLook(title: "Away", detail: "Online (no input)", symbol: "airplane.departure",
                             colour: Color(red: 0xfa / 255, green: 0xcc / 255, blue: 0x15 / 255))
        case .parked:
            return StateLook(title: "Parked", detail: "Away (on ground)", symbol: "parkingsign.circle.fill",
                             colour: Color(red: 0x94 / 255, green: 0xa3 / 255, blue: 0xb8 / 255))
        case .autopilotPlus:
            return StateLook(title: "Auto-pilot+", detail: "Cloud session", symbol: "icloud.and.arrow.up.fill",
                             colour: Color(red: 0x60 / 255, green: 0xa5 / 255, blue: 0xfa / 255))
        }
    }

    var body: some View {
        let look = self.look
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: look.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(look.colour)
                    .frame(width: 38, height: 38)
                    .background(look.colour.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(look.colour.opacity(0.22), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Pilot Status")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                    Text(look.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text(look.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .fill(look.colour.opacity(0.6))
                        .scaleEffect(pinging ? 2.6 : 1)
                        .opacity(pinging ? 0 : 0.6)
                    Circle().fill(look.colour)
                }
                .frame(width: 6, height: 6)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pinging = true }
                }
            }

            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
                .padding(.vertical, 14)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                timers(now: context.date)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .horizonCard(palette)
    }

    private func timers(now: Date) -> some View {
        let facts = HorizonRouteFacts(flight: flight, track: track)
        let elapsed = facts.started.map { now.timeIntervalSince($0) }
        let remaining = facts.remaining
        let total: TimeInterval? = {
            guard let elapsed = elapsed, let remaining = remaining else { return nil }
            return elapsed + remaining
        }()

        return HStack(spacing: 0) {
            timer("Elapsed", symbol: "stopwatch.fill", value: elapsed, accent: false)
                .padding(.trailing, 12)
            Rectangle().fill(palette.line).frame(width: 1)
            timer("Remaining", symbol: "hourglass", value: remaining, accent: true)
                .padding(.horizontal, 12)
            Rectangle().fill(palette.line).frame(width: 1)
            timer("Total", symbol: nil, value: total, accent: false)
                .padding(.leading, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timer(_ title: String, symbol: String?, value: TimeInterval?, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(accent ? palette.accent : palette.faint)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent ? palette.accent : palette.muted)
            }
            Text(HorizonRouteFacts.clock(value))
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(accent ? palette.accent : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The destination

/// "RJTT — Arriving at · tap for info", which opens the field.
struct FlightHorizonDestination: View {

    let airport: Airport
    let palette: HorizonPalette
    var onOpen: (Airport) -> Void = { _ in }

    var body: some View {
        Button { onOpen(airport) } label: {
            HStack(spacing: 11) {
                Image(systemName: "airplane.arrival")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0xee / 255, green: 0xc0 / 255, blue: 0x7e / 255))

                VStack(alignment: .leading, spacing: 2) {
                    Text(airport.icao)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(0.48)
                        .foregroundStyle(palette.text)
                    Text("Arriving at · tap for info")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(palette.muted)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .horizonCard(palette)
        .accessibilityLabel("Arriving at \(airport.icao), \(airport.name)")
        .accessibilityHint("Opens the airport")
    }
}

// MARK: - Speed & altitude

/// `flight-graph.js`, drawn natively: barometric altitude in blue on the left
/// axis, ground speed in amber on the right, five gridlines, six UTC times.
struct FlightHorizonGraph: View {

    let points: [TrackPoint]
    let palette: HorizonPalette

    private static let altColour = Color(red: 0x38 / 255, green: 0xbd / 255, blue: 0xf8 / 255)
    private static let gsColour = Color(red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255)
    private static let textColour = Color(red: 0x94 / 255, green: 0xa3 / 255, blue: 0xb8 / 255)

    private struct Sample {
        let t: TimeInterval
        let alt: Double
        let gs: Double
    }

    private var samples: [Sample] {
        points.compactMap { point in
            guard let date = point.date else { return nil }
            return Sample(
                t: date.timeIntervalSince1970,
                alt: point.altitudeFeet.isFinite ? max(point.altitudeFeet, 0) : 0,
                gs: point.groundSpeedKnots.isFinite ? max(point.groundSpeedKnots, 0) : 0
            )
        }
        .sorted { $0.t < $1.t }
    }

    var body: some View {
        let samples = self.samples
        return VStack(spacing: 6) {
            if samples.count < 2 {
                Text("Awaiting flight history…")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(Self.textColour)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            } else {
                HStack(spacing: 14) {
                    legend(Self.altColour, "Barometric Altitude")
                    legend(Self.gsColour, "Ground Speed")
                }
                chart(samples)
                    .frame(height: 150)
            }
        }
        .padding(18)
        .horizonCard(palette)
    }

    private func legend(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 14, height: 3)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Self.textColour)
        }
    }

    private func chart(_ s: [Sample]) -> some View {
        Canvas { context, size in
            let padTop: CGFloat = 14, padBottom: CGFloat = 26, padLeft: CGFloat = 52, padRight: CGFloat = 46
            let x0 = padLeft, x1 = size.width - padRight, y0 = padTop, y1 = size.height - padBottom
            let plotW = max(1, x1 - x0), plotH = max(1, y1 - y0)

            let tMin = s[0].t
            var tMax = s[s.count - 1].t
            if tMax <= tMin { tMax = tMin + 1 }
            let altMax = max(1000, (s.map(\.alt).max() ?? 0) * 1.03)
            let gsMax = max(60, (s.map(\.gs).max() ?? 0) * 1.03)

            let xOf = { (t: TimeInterval) in x0 + CGFloat((t - tMin) / (tMax - tMin)) * plotW }
            let yAlt = { (v: Double) in y1 - CGFloat(v / altMax) * plotH }
            let yGs = { (v: Double) in y1 - CGFloat(v / gsMax) * plotH }

            let mono = Font.system(size: 9, design: .monospaced)
            let grid = palette.ink(0.08)

            for i in 0...5 {
                let y = y0 + plotH * CGFloat(i) / 5
                var line = Path()
                line.move(to: CGPoint(x: x0, y: y))
                line.addLine(to: CGPoint(x: x1, y: y))
                context.stroke(line, with: .color(grid), lineWidth: 1)

                let altLabel = Format.number(altMax * Double(5 - i) / 5)
                context.draw(
                    Text(altLabel).font(mono).foregroundColor(Self.altColour.opacity(0.85)),
                    at: CGPoint(x: x0 - 6, y: y), anchor: .trailing
                )
                let gsLabel = String(Int((gsMax * Double(5 - i) / 5).rounded()))
                context.draw(
                    Text(gsLabel).font(mono).foregroundColor(Self.gsColour.opacity(0.85)),
                    at: CGPoint(x: x1 + 6, y: y), anchor: .leading
                )
            }

            for i in 0...5 {
                let t = tMin + (tMax - tMin) * Double(i) / 5
                let anchor: UnitPoint = i == 0 ? .leading : (i == 5 ? .trailing : .center)
                context.draw(
                    Text(HorizonRouteFacts.zulu(Date(timeIntervalSince1970: t))).font(mono).foregroundColor(Self.textColour),
                    at: CGPoint(x: xOf(t), y: y1 + 13), anchor: anchor
                )
            }

            var alt = Path(), gs = Path()
            for (index, sample) in s.enumerated() {
                let a = CGPoint(x: xOf(sample.t), y: yAlt(sample.alt))
                let g = CGPoint(x: xOf(sample.t), y: yGs(sample.gs))
                if index == 0 { alt.move(to: a); gs.move(to: g) } else { alt.addLine(to: a); gs.addLine(to: g) }
            }
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            context.stroke(alt, with: .color(Self.altColour), style: style)
            context.stroke(gs, with: .color(Self.gsColour), style: style)

            context.draw(
                Text("FEET").font(.system(size: 8)).foregroundColor(Self.altColour.opacity(0.7)),
                at: CGPoint(x: x0 - 6, y: y0 - 3), anchor: .bottomTrailing
            )
            context.draw(
                Text("KTS").font(.system(size: 8)).foregroundColor(Self.gsColour.opacity(0.7)),
                at: CGPoint(x: x1 + 6, y: y0 - 3), anchor: .bottomLeading
            )
        }
        .accessibilityLabel("Speed and altitude over the flight")
    }
}

// MARK: - Navigation

/// Turns a position into the name of where it is, a cell at a time, the way
/// the web's "Currently over" line does.
@MainActor
final class HorizonPlaceName: ObservableObject {

    @Published private(set) var text = "Scanning..."

    private var key = ""
    private let geocoder = CLGeocoder()

    func update(_ coordinate: CLLocationCoordinate2D) {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }
        // A quarter of a degree: close enough to be right, far enough apart
        // not to ask on every packet.
        let next = "\(Int((coordinate.latitude * 4).rounded()))|\(Int((coordinate.longitude * 4).rounded()))"
        guard next != key else { return }
        key = next
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] marks, _ in
            let mark = marks?.first
            var parts: [String] = []
            for part in [mark?.locality, mark?.administrativeArea, mark?.country] {
                if let part = part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
            }
            let name = parts.isEmpty
                ? (mark?.ocean ?? mark?.inlandWater ?? "Ocean / Remote Area")
                : parts.joined(separator: ", ")
            Task { @MainActor in self?.text = name }
        }
    }
}

/// Position; atmosphere and plan; the next waypoint and the nearest field; and
/// where the aircraft is over.
struct FlightHorizonNavigation: View {

    let flight: Flight
    let plan: [PlanWaypoint]
    let sim: PilotLiveStatus?
    let palette: HorizonPalette

    @StateObject private var place = HorizonPlaceName()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel("Position", first: true)
            grid([
                ("Latitude", String(format: "%.4f°", flight.latitude), nil),
                ("Longitude", String(format: "%.4f°", flight.longitude), nil),
                ("Altitude", Format.number(flight.altitudeFeet), "ft"),
                ("Heading", "\(Format.heading(flight.heading))°", nil),
                ("Ground speed", Format.number(flight.groundSpeedKnots), "kt"),
                ("Vertical speed", Format.signed(flight.verticalSpeedFPM), "fpm"),
            ])

            groupLabel("Atmosphere & plan", first: false)
            grid([
                ("Wind", wind, nil),
                ("Outside air", sim?.temperatureC.map { "\($0)°C" } ?? "--°C", nil),
                ("True airspeed", sim?.trueAirspeedKnots.map { String($0) } ?? "---", "kt"),
                ("Cruise", "---", nil),
                ("Off cruise", "---", nil),
            ])

            VStack(spacing: 0) {
                row("Next waypoint", nextWaypoint)
                row("Nearest airport", nearestAirport)
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 3) {
                Text("Currently over")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                Text(place.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
            .padding(.top, 14)
        }
        .padding(18)
        .horizonCard(palette)
        .onAppear { place.update(flight.coordinate) }
        .onChange(of: flight.latitude) { _, _ in place.update(flight.coordinate) }
    }

    private var wind: String {
        guard let direction = sim?.windDirection, let speed = sim?.windVelocityKnots else { return "---/--" }
        return String(format: "%03d/%02d", direction, speed)
    }

    /// The fix after the one the aircraft is nearest, and how far it is.
    private var nextWaypoint: String {
        guard !plan.isEmpty else { return "--- · --.- NM" }
        let here = flight.coordinate
        let nearest = plan.indices.min {
            FlightProgress.distanceNM(from: here, to: plan[$0].coordinate)
                < FlightProgress.distanceNM(from: here, to: plan[$1].coordinate)
        } ?? 0
        let next = plan[min(nearest + 1, plan.count - 1)]
        let distance = FlightProgress.distanceNM(from: here, to: next.coordinate)
        return "\(next.name) · \(String(format: "%.1f", distance)) NM"
    }

    /// Within two degrees, as the web looks.
    private var nearestAirport: String {
        guard let airport = AirportStore.shared.nearestAirport(to: flight.coordinate, withinNM: 120) else {
            return "--- · --.- NM"
        }
        let distance = FlightProgress.distanceNM(from: flight.coordinate, to: airport.coordinate)
        return "\(airport.icao) · \(String(format: "%.1f", distance)) NM"
    }

    @ViewBuilder
    private func groupLabel(_ title: String, first: Bool) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(palette.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? 0 : 13)
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(palette.line).frame(height: 1) }
            }
            .padding(.top, first ? 0 : 16)
            .padding(.bottom, 10)
    }

    private func grid(_ cells: [(String, String, String?)]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: 3),
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(cell.1)
                            .font(.system(size: 14.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(palette.text)
                        if let unit = cell.2 {
                            Text(unit)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.muted)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

// MARK: - Aircraft

/// Registration and class, as label-value rows with hairlines between.
struct FlightHorizonAircraft: View {

    let flight: Flight
    let registration: String
    let palette: HorizonPalette

    /// The web's `category`, which reads "Commercial" for an airliner.
    private var className: String {
        switch AircraftCategory.from(spriteKey: flight.spriteKey) {
        case .airliner: return "Commercial"
        case .regional: return "Regional"
        case .light: return "General aviation"
        case .military: return "Military"
        case .helicopter: return "Helicopter"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            row("Registration", registration.isEmpty ? "N/A" : registration, mono: true, first: true)
            row("Class", className, mono: false, first: false)
        }
        .padding(18)
        .horizonCard(palette)
    }

    private func row(_ label: String, _ value: String, mono: Bool, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
        .padding(.top, first ? 0 : 9)
        .padding(.bottom, first ? 9 : 0)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }
}

// MARK: - The window

/// The open window, top to bottom in the web's order.
struct FlightHorizonWindow: View {

    let flight: Flight
    let registration: String
    let palette: HorizonPalette
    let image: UIImage?
    let contributor: String?
    var photos: [AircraftPhoto] = []
    var isAutoplaying = true
    let width: CGFloat
    let track: [TrackPoint]
    let plan: [PlanWaypoint]
    let sim: PilotLiveStatus?
    let isRealWorld: Bool
    var instrumentsRunning = true
    var realCredit: AnyView? = nil
    var realLink: URL? = nil
    /// The handle of the pilot whose own look this window is wearing, if it
    /// is wearing one.
    var styledBy: String? = nil
    var backRow: AnyView? = nil
    var partnerLine: AnyView? = nil
    var foot: AnyView? = nil
    var onReplay: () -> Void = {}
    var onSelectAirport: (Airport) -> Void = { _ in }

    @ObservedObject private var instruments = InstrumentPreferences.shared

    /// The app's own theme for the app's own cards dropped into the window, so
    /// they take its colour.
    private var theme: FlightInfoTheme { .horizon(palette.colour) }

    var body: some View {
        VStack(spacing: 0) {
            FlightHorizonHeader(
                flight: flight,
                palette: palette,
                image: image,
                contributor: contributor,
                photos: photos,
                isAutoplaying: isAutoplaying,
                width: width,
                actions: AnyView(FlightHorizonActions(flight: flight, track: track, onReplay: onReplay)),
                realCredit: realCredit,
                realLink: realLink
            )

            FlightHorizonRouteStrip(flight: flight, track: track, palette: palette, onSelectAirport: onSelectAirport)

            if !isRealWorld, flight.username?.isEmpty == false {
                VStack(spacing: 10) {
                    FlightHorizonPilotButton(flight: flight, palette: palette)
                    if let styledBy = styledBy {
                        FlightHorizonOwnerNote(handle: styledBy, palette: palette)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .frame(maxWidth: 560)
            }

            column
                .padding(.top, 10)
                .padding(.horizontal, 14)
                // The web's 20, plus the home indicator the window draws under.
                .padding(.bottom, 60)
                .frame(maxWidth: 560)
        }
        .frame(width: width)
        .background(alignment: .top) { ambient }
    }

    /// The tint behind the header, fading into the window colour over the
    /// first screen and scrolling with the content.
    @ViewBuilder
    private var ambient: some View {
        if !palette.hasImageBackground {
            LinearGradient(
                stops: [
                    .init(color: palette.tint, location: 0),
                    .init(color: palette.tint, location: 420.0 / 900.0),
                    .init(color: palette.bg, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 900)
        }
    }

    private var column: some View {
        VStack(spacing: 12) {
            if let backRow = backRow { backRow }

            FlightHorizonGlance(flight: flight, palette: palette)

            if !isRealWorld {
                FlightHorizonStatus(flight: flight, track: track, palette: palette)
            }

            // Draws nothing unless this is the aeroplane the pilot is flying
            // and Connect is attached to it.
            ConnectFrequencyCard(flightId: flight.id, theme: theme)

            if let arrival = FlightProgress(flight: flight)?.arrival {
                FlightHorizonDestination(airport: arrival, palette: palette, onOpen: onSelectAirport)
            }

            FileThisFlightRow(flight: flight, theme: theme)

            instrumentSections

            sections
        }
    }

    @ViewBuilder
    private var instrumentSections: some View {
        if instruments.isEnabled {
            HorizonSectionHeading(title: "Instruments", symbol: "gauge.with.dots.needle.33percent", palette: palette)
            InstrumentsCard(flightId: flight.id, theme: theme, isRunning: instrumentsRunning)
        }

        if !plan.isEmpty {
            HorizonSectionHeading(title: "Flight plan", symbol: "list.bullet", palette: palette)
            FiledRouteCard(flight: flight, waypoints: plan, theme: theme)
        }

        if let partnerLine = partnerLine { partnerLine }
    }

    @ViewBuilder
    private var sections: some View {
        HorizonSectionHeading(title: "Speed & altitude", symbol: "chart.xyaxis.line", palette: palette)
        FlightHorizonGraph(points: track, palette: palette)

        HorizonSectionHeading(title: "Navigation", symbol: "safari", palette: palette)
        FlightHorizonNavigation(flight: flight, plan: plan, sim: sim, palette: palette)

        if let sim = sim {
            HorizonSectionHeading(title: "Fuel", symbol: "drop", palette: palette)
            SimReadoutCard(status: sim, theme: theme)
        }

        HorizonSectionHeading(title: "Aircraft", symbol: "airplane", palette: palette)
        FlightHorizonAircraft(flight: flight, registration: registration, palette: palette)

        if let foot = foot { foot }
    }
}
