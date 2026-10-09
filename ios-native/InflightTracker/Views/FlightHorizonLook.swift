import PhotosUI
import SwiftUI
import UIKit

/// The Horizon flight window, from the web.
///
/// On the web Horizon is the Legacy window in a softer skin: one deep ink
/// surface instead of grey bands, sentence-case labels, lighter number weights,
/// the live numbers first and then where the flight is going. Here it is the
/// cards' window told the same way — the same photograph at the top, the same
/// pilot card and actions and instruments underneath — with three things of its
/// own:
///
/// - **A colour the reader picks.** Any colour at all. The rest of the palette
///   is worked out from it so the type always reads: on a dark colour the ink
///   is white, on a light one it is black, whichever contrasts more, and every
///   text tone, surface and hairline is that ink at an opacity. The same rule,
///   to the number, as the web's `horizonTokens`.
/// - **A background.** The colour on its own, the aircraft's photograph blurred,
///   or an image of the reader's own — with the colour laid over it at the Dim
///   strength, so the contrast rules of the colour still hold.
/// - **A head of its own.** An eyebrow of operator and type over the callsign,
///   a glance row of the four live numbers, and the route as a line with the
///   aircraft's own silhouette riding it.
///
/// Free, as it is on the web: it is a skin over facts every look already shows.

// MARK: - The colour

/// The window's colour and the ink worked out from it.
struct HorizonColour: Equatable {

    static let defaultHex = "#16181c"

    struct Preset: Identifiable {
        let hex: String
        let name: String
        var id: String { hex }
    }

    /// The web's eight, in the web's order, with the web's names.
    static let presets: [Preset] = [
        Preset(hex: "#16181c", name: "Ink"),
        Preset(hex: "#101a2c", name: "Midnight"),
        Preset(hex: "#0f2226", name: "Deep sea"),
        Preset(hex: "#142019", name: "Forest"),
        Preset(hex: "#1f1726", name: "Plum"),
        Preset(hex: "#2a1a16", name: "Ember"),
        Preset(hex: "#e9ecf1", name: "Mist"),
        Preset(hex: "#f6f4ef", name: "Paper"),
    ]

    /// Always `#rrggbb`, lower case. Anything that does not parse is the
    /// default, so a corrupt synced value is a dark window rather than a crash
    /// or a transparent one.
    let hex: String
    let red: Double
    let green: Double
    let blue: Double

    init(hex raw: String) {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count != 6 || !digits.allSatisfy(\.isHexDigit) {
            digits = String(Self.defaultHex.dropFirst())
        }
        let value = UInt32(digits, radix: 16) ?? 0
        hex = "#" + digits
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    /// From a colour well, which hands back whatever space it likes.
    init(_ colour: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colour).getRed(&r, green: &g, blue: &b, alpha: &a)
        let byte = { (c: CGFloat) in Int((min(max(c, 0), 1) * 255).rounded()) }
        self.init(hex: String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b)))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG relative luminance, then contrast against black and against white;
    /// the larger one wins. Exactly the web's test, so a colour that is a light
    /// window there is a light window here.
    var isLight: Bool {
        let linear = { (c: Double) in c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05)
    }
}

extension FlightInfoTheme {

    /// The Horizon window in a colour.
    ///
    /// Solid rather than glass, whatever the app's glass switch says: the
    /// colour is the whole of what was chosen, and glass would hand it back as
    /// whatever the map underneath made of it.
    static func horizon(_ colour: HorizonColour) -> FlightInfoTheme {
        let light = colour.isLight
        let ink: Color = light ? .black : .white

        return FlightInfoTheme(
            isGlass: false,
            isLight: light,
            windowFill: colour.color,
            scrim: .clear,
            chromeTint: .clear,
            surfaceTint: .clear,
            elevatedTint: .clear,
            // The web's surfaces are barely there — one deep surface rather
            // than grey bands is the point of the look. A shade heavier than
            // its 0.035 here, because a card on a phone is also a target.
            surfaceFill: ink.opacity(0.05),
            elevatedFill: ink.opacity(light ? 0.08 : 0.09),
            stroke: ink.opacity(light ? 0.09 : 0.08),
            strokeStrong: ink.opacity(light ? 0.16 : 0.14),
            textPrimary: light
                ? Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1b / 255)
                : Color(red: 0xee / 255, green: 0xf0 / 255, blue: 0xf4 / 255),
            textSecondary: ink.opacity(light ? 0.62 : 0.60),
            textDim: ink.opacity(light ? 0.45 : 0.42),
            // The web's muted sky blue, and its deeper twin on a light colour.
            accent: light
                ? Color(red: 0x1f / 255, green: 0x6f / 255, blue: 0xae / 255)
                : Color(red: 0x8c / 255, green: 0xc8 / 255, blue: 0xee / 255),
            onAccent: light ? .white : Color(red: 0.04, green: 0.10, blue: 0.15),
            trackFill: ink.opacity(light ? 0.10 : 0.12),
            groundOpacity: 1,
            textHalo: .clear
        )
    }
}

// MARK: - The background

/// What is behind the Horizon window.
enum HorizonBackground: String, CaseIterable, Identifiable {

    /// The colour, and nothing else.
    case colour

    /// The aircraft's first photograph, blurred, under the colour.
    case aircraft

    /// An image the reader picked, under the colour. It stays on this device —
    /// a photograph has no business in synced settings — so on another device
    /// the same choice is the colour until one is picked there too.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colour: return "Colour"
        case .aircraft: return "Aircraft"
        case .custom: return "Your image"
        }
    }

    var detail: String {
        switch self {
        case .colour: return "The window is the colour above."
        case .aircraft: return "The aircraft's own photo, blurred, behind the window. The colour is laid over it."
        case .custom: return "An image of your own behind the window, kept on this device. The colour is laid over it."
        }
    }
}

/// The reader's own background image, kept in Application Support.
///
/// A file rather than a default, for the same reason the web keeps it in
/// IndexedDB rather than localStorage: it is a photograph, and a photograph in
/// the defaults is a photograph read into memory on every launch.
final class HorizonBackdropStore: ObservableObject {

    static let shared = HorizonBackdropStore()

    @Published private(set) var image: UIImage?

    /// Long edge, in pixels. It is drawn behind a phone-sized window with the
    /// colour over it, so anything bigger is memory for nothing.
    private static let longEdge: CGFloat = 1600

    private var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("horizon-background.jpg")
    }

    private init() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        image = UIImage(data: data)
    }

    func save(_ picked: UIImage) {
        let scaled = Self.downscaled(picked)
        image = scaled
        guard let url = url, let data = scaled.jpegData(compressionQuality: 0.85) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    func remove() {
        image = nil
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longEdge, longest > 0 else { return image }
        let scale = longEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The background, drawn behind the whole window.
///
/// Cover-fitted so it always fills the window from top to bottom, and it stays
/// put while the content scrolls over it. The window's colour goes over it at
/// the Dim strength — which is what keeps the type legible on whatever picture
/// is underneath.
struct FlightHorizonBackdrop: View {

    let theme: FlightInfoTheme

    /// The aircraft's photograph, when there is one this window may draw
    /// blurred. Nil for real traffic: those photographs are another site's,
    /// lent on condition they are shown as they are.
    let aircraftImage: UIImage?

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = HorizonBackdropStore.shared

    private var picture: UIImage? {
        switch appearance.horizonBackground {
        case .colour: return nil
        case .aircraft: return aircraftImage
        case .custom: return store.image
        }
    }

    var body: some View {
        theme.windowFill
            .overlay {
                if let picture = picture {
                    GeometryReader { proxy in
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: appearance.horizonBackground == .aircraft ? 22 : 0, opaque: true)
                            .clipped()
                    }
                    .overlay { theme.windowFill.opacity(Double(appearance.horizonDim)) }
                    .transition(.opacity)
                }
            }
            .animation(Motion.panel, value: picture)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The head

/// Who this is: an eyebrow of operator and type, then the callsign.
///
/// The web's "cinematic identity". The registration is not here — it lives with
/// the aircraft, further down — and neither is the pilot, who has the card
/// directly underneath.
struct FlightHorizonIdentity: View {

    let flight: Flight
    let theme: FlightInfoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.75)
                    .motionWords(eyebrow)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(flight.displayName)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
                    .motionWords(flight.displayName)

                Spacer(minLength: 0)

                FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// "Ethiopian Airlines · Boeing 787-9", or whichever half there is.
    private var eyebrow: String {
        let livery = flight.liveryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let aircraft = flight.aircraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [livery, aircraft].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The four live numbers, at a glance.
///
/// First in the window, as on the web: the story starts with what the
/// aeroplane is doing now. Sentence-case labels and a lighter weight than the
/// telemetry grid it replaces, which is most of what "calmer" means.
struct FlightHorizonGlance: View {

    let flight: Flight
    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 0) {
            cell("Altitude", symbol: "arrow.up", value: Format.number(flight.altitudeFeet), unit: "ft", figure: flight.altitudeFeet)
            divider
            cell("Ground speed", symbol: "gauge.with.needle", value: Format.number(flight.groundSpeedKnots), unit: "kts", figure: flight.groundSpeedKnots)
            divider
            cell("Vertical", symbol: "arrow.up.arrow.down", value: Format.signed(flight.verticalSpeedFPM), unit: "fpm", figure: flight.verticalSpeedFPM)
            divider
            cell("Heading", symbol: "location.north.fill", value: Format.heading(flight.heading), unit: "°", figure: flight.heading, turns: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(width: 1, height: 30)
    }

    /// One reading. The heading's glyph is a needle and turns with the
    /// aeroplane, which is the web's one flourish and worth keeping.
    private func cell(
        _ title: String,
        symbol: String,
        value: String,
        unit: String,
        figure: Double,
        turns: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .rotationEffect(.degrees(turns && flight.heading.isFinite ? flight.heading : 0))

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
                    .motionFigure(figure)

                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Where it is going: both ends, and a line between them with the aircraft's
/// own silhouette at the point it has reached.
struct FlightHorizonRoute: View {

    let flight: Flight
    let progress: FlightProgress
    let theme: FlightInfoTheme
    var onSelectAirport: (Airport) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                end(progress.departure, label: "From", alignment: .leading)
                Spacer(minLength: 8)
                end(progress.arrival, label: "To", alignment: .trailing)
            }

            track

            HStack {
                Text("\(Format.number(progress.flownNM)) nm flown")
                Spacer(minLength: 8)
                Text(remaining)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.textDim)
            .flightInfoLine(minimumScale: 0.75)
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var remaining: String {
        let left = "\(Format.number(progress.remainingNM)) nm to go"
        guard let ete = progress.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return left
        }
        return "\(left) · \(Format.duration(ete))"
    }

    private func end(_ airport: Airport, label: String, alignment: HorizontalAlignment) -> some View {
        Button { onSelectAirport(airport) } label: {
            VStack(alignment: alignment, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)

                Text(airport.icao)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                Text(airport.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(airport.icao), \(airport.name)")
    }

    /// The line, filled to where the aeroplane is, with the aeroplane on it.
    private var track: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(progress.fraction)
            let plane: CGFloat = 20
            let x = min(max(proxy.size.width * fraction, plane / 2), proxy.size.width - plane / 2)

            ZStack(alignment: .leading) {
                Capsule().fill(theme.trackFill).frame(height: 3)
                Capsule().fill(theme.accent).frame(width: x, height: 3)

                silhouette
                    .frame(width: plane, height: plane)
                    .position(x: x, y: proxy.size.height / 2)
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("\(Int((progress.fraction * 100).rounded())) percent of the way")
    }

    /// The map's own sprite for this type, turned to fly along the line. The
    /// SF aeroplane when there is none, which is what the web falls back to.
    @ViewBuilder
    private var silhouette: some View {
        if let icon = PlaneSprites.shared.icon(
            forKey: flight.spriteKey,
            selected: false,
            tint: UIColor(theme.accent)
        ) {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(90))
        } else {
            Image(systemName: "airplane")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Settings

/// The rows under Horizon in Settings › Flight window: the colour, the
/// background, and how much of the colour sits over it.
struct HorizonSettingsRows: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = HorizonBackdropStore.shared

    @State private var pick: PhotosPickerItem?
    @State private var problem: String?

    private var theme: FlightInfoTheme { appearance.theme }

    private var colourWell: Binding<Color> {
        Binding(
            get: { HorizonColour(hex: appearance.horizonColour).color },
            set: { appearance.horizonColour = HorizonColour($0).hex }
        )
    }

    private var dim: Binding<CGFloat> {
        Binding(
            get: { appearance.horizonDim },
            set: { appearance.horizonDim = min(max($0, 0), 1) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            colourRow

            PanelDivider()

            PanelPickerRow(
                title: "Background",
                symbol: "photo",
                options: HorizonBackground.allCases,
                label: { $0.label },
                detail: appearance.horizonBackground.detail,
                selection: $appearance.horizonBackground
            )

            if appearance.horizonBackground == .custom {
                imageRow
            }

            if appearance.horizonBackground != .colour {
                PanelDivider()

                PanelSliderRow(
                    title: "Dim",
                    symbol: "circle.lefthalf.filled",
                    detail: "How much of the colour is laid over the picture. More keeps the text crisper.",
                    reading: { "\(Int(($0 * 100).rounded()))%" },
                    neutral: 0.6,
                    range: 0...1,
                    lowSymbol: "photo",
                    highSymbol: "paintpalette",
                    value: dim
                )
            }
        }
        .onChange(of: pick) { _, item in load(item) }
    }

    private var colourRow: some View {
        let current = appearance.horizonColour.lowercased()
        let isPreset = HorizonColour.presets.contains { $0.hex == current }

        return VStack(alignment: .leading, spacing: 10) {
            PanelRowLabel(title: "Colour", symbol: "paintpalette")

            HStack(spacing: 8) {
                ForEach(HorizonColour.presets) { preset in
                    Button {
                        appearance.horizonColour = preset.hex
                    } label: {
                        Circle()
                            .fill(HorizonColour(hex: preset.hex).color)
                            .frame(width: 26, height: 26)
                            .overlay { Circle().strokeBorder(theme.stroke, lineWidth: 1) }
                            .overlay {
                                if preset.hex == current {
                                    Circle()
                                        .strokeBorder(theme.accent, lineWidth: 2)
                                        .padding(-3)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(preset.hex == current ? .isSelected : [])
                }

                Spacer(minLength: 0)

                ColorPicker("Any colour", selection: colourWell, supportsOpacity: false)
                    .labelsHidden()
                    .overlay {
                        if !isPreset {
                            Circle()
                                .strokeBorder(theme.accent, lineWidth: 2)
                                .padding(-3)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Text("Text and panels adjust by themselves so the window always reads.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var imageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(store.image == nil ? "Choose an image" : "Replace image", systemImage: "photo.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .flightInfoSurface(theme, radius: theme.radiusSmall, interactive: true)
                }

                if store.image != nil {
                    Button(role: .destructive) {
                        store.remove()
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .flightInfoSurface(theme, radius: theme.radiusSmall, interactive: true)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }

            if let problem = problem {
                Text(problem)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            } else if store.image == nil {
                Text("Until one is chosen the window is the colour on its own.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @MainActor
    private func load(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task { @MainActor in
            // Cleared either way, so picking the same image twice still fires.
            defer { pick = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                problem = "That picture couldn't be read."
                return
            }
            problem = nil
            store.save(image)
        }
    }
}
