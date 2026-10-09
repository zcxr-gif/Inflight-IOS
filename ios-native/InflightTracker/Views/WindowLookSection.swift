import PhotosUI
import SwiftUI

/// "Your flight window" in the profile editor: how the window looks to
/// everybody else who opens this pilot's flight, on the app and on the web.
///
/// The same three things the website's editor sets (`pilotCardEditor.js`): a
/// painted theme, free; a window colour, Pro; and a photo behind the window
/// with how strongly the colour sits over it, Pro. Saved to the pilot's own
/// row; the photo goes up through `profile-image` as a `window` picture.
struct WindowLookSection: View {

    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Raised for a Pro part on a free account.
    @Binding var isShowingPaywall: Bool

    @State private var theme: BannerPreset?
    @State private var colour: String?
    @State private var dim: CGFloat = 0.6
    @State private var photoPick: PhotosPickerItem?
    @State private var hasLoaded = false

    private var panelTheme: FlightInfoTheme { appearance.theme }
    private var isPro: Bool { entitlements.has(.profileBanner) }

    private var isDirty: Bool {
        guard let profile = store.profile else { return false }
        return profile.windowTheme != theme
            || profile.windowColour != colour
            || profile.windowDim != Int((dim * 100).rounded())
    }

    var body: some View {
        PanelSection(title: "YOUR FLIGHT WINDOW") {
            VStack(alignment: .leading, spacing: 12) {
                Text("How the flight window looks to everyone who opens your flight — here and on the website.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(panelTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                preview

                themeRow

                PanelDivider()

                colourRow

                PanelDivider()

                photoRow

                if store.profile?.windowPhotoPath != nil {
                    PanelSliderRow(
                        title: "Dim",
                        symbol: "circle.lefthalf.filled",
                        detail: "How much of the window colour is laid over your photo.",
                        reading: { "\(Int(($0 * 100).rounded()))%" },
                        neutral: 0.6,
                        range: 0.2...0.9,
                        lowSymbol: "photo",
                        highSymbol: "paintpalette",
                        value: $dim
                    )
                    .padding(.horizontal, -14)
                }

                if isDirty {
                    Button {
                        Task {
                            await store.saveWindowStyle(
                                theme: theme,
                                colour: colour,
                                dim: Int((dim * 100).rounded())
                            )
                            if store.needsProFor != nil { isShowingPaywall = true }
                        }
                    } label: {
                        Text(store.isSaving ? "Saving…" : "Save window")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(panelTheme.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background { Capsule().fill(panelTheme.accent) }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSaving)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .onAppear(perform: adopt)
        .onChange(of: store.profile?.handle) { _, _ in adopt() }
        .onChange(of: photoPick) { _, item in upload(item) }
    }

    private func adopt() {
        guard let profile = store.profile else { return }
        theme = profile.windowTheme
        colour = profile.windowColour
        dim = CGFloat(profile.windowDim) / 100
        hasLoaded = true
    }

    // MARK: - Preview

    /// A strip of the window as others will see it: the photo or the theme
    /// under the colour, with a line of type over it.
    private var preview: some View {
        let hex = colour ?? theme.map { PilotWindowStyle.mix(PilotWindowStyle.stops($0)[0], "#0e1014", 0.55) } ?? HorizonColour.defaultHex
        let windowColour = HorizonColour(hex: hex)
        let source: HorizonBackdropSource = {
            if let theme = theme, colour == nil {
                return .painted(PilotWindowStyle.stops(theme), dim: 0.55)
            }
            return .none
        }()
        return ZStack(alignment: .bottomLeading) {
            FlightHorizonBackdrop(theme: .horizon(windowColour), source: source)
            if let url = store.profile?.windowPhotoURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .overlay { windowColour.color.opacity(Double(dim)) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR AIRLINE  ·  YOUR AIRCRAFT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.9)
                    .opacity(0.72)
                Text(store.profile?.ifUsername.isEmpty == false ? store.profile!.ifUsername : "Your callsign")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(windowColour.isLight ? Color.black : Color.white)
            .padding(14)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: panelTheme.radiusSmall, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - Theme (free)

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelRowLabel(title: "Theme", symbol: "paintbrush")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    swatch(selected: theme == nil, label: "None") {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(panelTheme.surfaceFill)
                            .overlay {
                                Image(systemName: "nosign")
                                    .font(.system(size: 13))
                                    .foregroundStyle(panelTheme.textDim)
                            }
                    } action: { theme = nil }

                    ForEach(BannerPreset.allCases) { preset in
                        swatch(selected: theme == preset, label: preset.label) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(preset.gradient)
                        } action: { theme = preset }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func swatch<Face: View>(
        selected: Bool,
        label: String,
        @ViewBuilder face: () -> Face,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            face()
                .frame(width: 54, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? panelTheme.textPrimary : panelTheme.stroke, lineWidth: selected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Colour (Pro)

    private var colourWell: Binding<Color> {
        Binding(
            get: { HorizonColour(hex: colour ?? HorizonColour.defaultHex).color },
            set: { colour = HorizonColour($0).hex }
        )
    }

    private var colourRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelRowLabel(title: "Colour", symbol: "paintpalette")
                Spacer()
                if colour != nil, isPro {
                    Button("Use the theme") { colour = nil }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(panelTheme.textDim)
                        .buttonStyle(.plain)
                }
            }
            if isPro {
                HStack(spacing: 8) {
                    ForEach(HorizonColour.presets) { preset in
                        Button { colour = preset.hex } label: {
                            Circle()
                                .fill(HorizonColour(hex: preset.hex).color)
                                .frame(width: 24, height: 24)
                                .overlay { Circle().strokeBorder(panelTheme.stroke, lineWidth: 1) }
                                .overlay {
                                    if colour == preset.hex {
                                        Circle().strokeBorder(panelTheme.accent, lineWidth: 2).padding(-3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                    Spacer(minLength: 0)
                    ColorPicker("Any colour", selection: colourWell, supportsOpacity: false)
                        .labelsHidden()
                }
            } else {
                proLock("Your own window colour is part of Inflight Pro")
            }
        }
    }

    // MARK: - Photo (Pro)

    private var photoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelRowLabel(title: "Photo behind the window", symbol: "photo")
            if isPro {
                let uploading = store.uploading == .window
                let paused = store.standing?.uploadsRestricted == true
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoPick, matching: .images) {
                        HStack(spacing: 6) {
                            if uploading {
                                ProgressView().controlSize(.small).tint(panelTheme.onAccent)
                            } else {
                                Image(systemName: "photo").font(.system(size: 11, weight: .bold))
                            }
                            Text(uploading ? "Uploading…" : (store.profile?.windowPhotoPath == nil ? "Use a photo" : "Change photo"))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(panelTheme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background { Capsule().fill(panelTheme.accent) }
                        .opacity(paused ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(paused || uploading)

                    if store.profile?.windowPhotoPath != nil {
                        Button { Task { await store.removeImage(.window) } } label: {
                            Text("Remove photo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(panelTheme.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                proLock("A photo behind your window is part of Inflight Pro")
            }
        }
    }

    private func proLock(_ line: String) -> some View {
        Button { isShowingPaywall = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10, weight: .bold))
                Text(line).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(panelTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func upload(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task { @MainActor in
            defer { photoPick = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                store.problem = "That picture couldn't be read."
                return
            }
            await store.upload(image, as: .window)
            if store.needsProFor != nil { isShowingPaywall = true }
        }
    }
}
