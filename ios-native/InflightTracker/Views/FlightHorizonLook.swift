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
            // The web's --sr-surface, --sr-surface-hi and --sr-line, so the
            // app's own cards dropped into the window (instruments, the filed
            // route, the sim's readout) sit on it the way the web's do.
            surfaceFill: ink.opacity(light ? 0.04 : 0.035),
            elevatedFill: ink.opacity(light ? 0.055 : 0.06),
            stroke: ink.opacity(light ? 0.09 : 0.07),
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

/// What is behind the window: nothing, a picture, or a painted theme — each
/// with how much of the window's colour is laid over it.
enum HorizonBackdropSource: Equatable {
    case none
    case picture(UIImage, blur: CGFloat, dim: Double)
    /// A pilot's painted theme, as `#rrggbb` stops top to bottom.
    case painted([String], dim: Double)

    /// The viewer's own choice in Settings. `aircraftImage` is nil for real
    /// traffic: those photographs are another site's, lent on condition they
    /// are shown as they are.
    static func viewer(aircraftImage: UIImage?) -> HorizonBackdropSource {
        let appearance = FlightInfoAppearance.shared
        let dim = Double(appearance.horizonDim)
        switch appearance.horizonBackground {
        case .colour:
            return .none
        case .aircraft:
            // The web blurs the photo 18px at 640 wide before covering the
            // window with it.
            return aircraftImage.map { .picture($0, blur: 14, dim: dim) } ?? .none
        case .custom:
            return HorizonBackdropStore.shared.image.map { .picture($0, blur: 0, dim: dim) } ?? .none
        }
    }

    var isNone: Bool { self == .none }
}

/// The background, drawn behind the whole window.
///
/// Cover-fitted so it always fills the window from top to bottom, and it stays
/// put while the content scrolls over it. The window's colour goes over it at
/// the Dim strength — which is what keeps the type legible on whatever picture
/// is underneath.
struct FlightHorizonBackdrop: View {

    let theme: FlightInfoTheme
    let source: HorizonBackdropSource

    var body: some View {
        theme.windowFill
            .overlay {
                switch source {
                case .none:
                    EmptyView()
                case .picture(let image, let blur, let dim):
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: blur, opaque: true)
                            .clipped()
                    }
                    .overlay { theme.windowFill.opacity(dim) }
                    .transition(.opacity)
                case .painted(let stops, let dim):
                    // `paintedBackgroundUrl`: the stops top to bottom, with a
                    // soft glow near the top where the photo fades in.
                    LinearGradient(
                        colors: stops.map { HorizonColour(hex: $0).color },
                        startPoint: .top, endPoint: .bottom
                    )
                    .overlay {
                        GeometryReader { proxy in
                            RadialGradient(
                                colors: [Color.white.opacity(0.14), Color.white.opacity(0)],
                                center: UnitPoint(x: 0.5, y: 0.12),
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.9
                            )
                        }
                    }
                    .overlay { theme.windowFill.opacity(dim) }
                    .transition(.opacity)
                }
            }
            .animation(Motion.panel, value: source)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Settings

/// The row under Horizon in Settings › Flight window: its colour. What is
/// behind the window is `WindowBackgroundRows`, under every style.
struct HorizonSettingsRows: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var colourWell: Binding<Color> {
        Binding(
            get: { HorizonColour(hex: appearance.horizonColour).color },
            set: { appearance.horizonColour = HorizonColour($0).hex }
        )
    }

    var body: some View {
        colourRow
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
}

/// What is behind the flight window, under every style: the colour alone, the
/// aircraft's photo, or a picture of your own — and how much of the window's
/// colour sits over it.
///
/// With Pro, your own picture is also the one other pilots see behind the
/// window when they open your flight: picking one here replaces whatever
/// photo your window had for them. A pilot who has a picture of their own
/// wins on their flight — see `FlightDetailView.backdropSource`.
struct WindowBackgroundRows: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = HorizonBackdropStore.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var pick: PhotosPickerItem?
    @State private var problem: String?

    private var theme: FlightInfoTheme { appearance.theme }

    private var dim: Binding<CGFloat> {
        Binding(
            get: { appearance.horizonDim },
            set: { appearance.horizonDim = min(max($0, 0.2), 0.9) }
        )
    }

    /// Whether a picture chosen here goes up for other pilots as well.
    private var shares: Bool {
        entitlements.has(.profileBanner) && accounts.isSignedIn && profiles.profile != nil
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    range: 0.2...0.9,
                    lowSymbol: "photo",
                    highSymbol: "paintpalette",
                    value: dim
                )
            }
        }
        .onChange(of: pick) { _, item in load(item) }
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
                        // The same picture is the one other pilots see, so it
                        // comes down for them too.
                        if shares, profiles.profile?.windowPhotoPath != nil {
                            Task { await profiles.removeImage(.window) }
                        }
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

            if let problem = problem ?? profiles.problem.flatMap({ profiles.uploading == nil ? $0 : nil }) {
                Text(problem)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            } else if store.image == nil {
                Text("Until one is chosen the window is the colour on its own.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }

            Label(sharingLine, systemImage: shares ? "person.2.fill" : "sparkles")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
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
            // Pro: the same picture behind your window for everyone who opens
            // your flight, in place of whatever was there.
            if shares { await profiles.upload(image, as: .window) }
        }
    }

    private var sharingLine: String {
        if profiles.uploading == .window { return "Sharing with other pilots…" }
        if shares { return "Pilots who open your flight see this picture too." }
        if entitlements.has(.profileBanner) { return "Claim a profile to show it to pilots who open your flight." }
        return "With Inflight Pro, pilots who open your flight see it too."
    }
}
