import PhotosUI
import SwiftUI

/// Setting up, and changing, your own profile.
///
/// The first thing it asks for is a handle, and until there is one there is no
/// profile at all — no row, nothing for anybody to follow, nothing in the
/// directory. That is deliberate: a profile is something somebody chooses to
/// have, not something an account quietly acquires by existing, and an account
/// that never opens this screen is never listed anywhere.
///
/// Every refusal here comes from the server. The handle rules, the safe-for-work
/// filter, the 30-day cooldown on changing a handle and the Pro gate on the
/// banner are all enforced by `pilot_profiles`' write guard, and this screen
/// shows what it said rather than re-implementing any of it — a client-side
/// copy of a rule is a client-side copy to disagree with.
struct ProfileEditorView: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var identity = PilotIdentity.shared

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProfileStore.Editable()
    @State private var hasLoaded = false

    /// nil = not asked yet or unanswerable. The editor says as much rather
    /// than guessing either way.
    @State private var handleAvailable: Bool?
    @State private var isCheckingHandle = false

    @State private var avatarPick: PhotosPickerItem?
    @State private var bannerPick: PhotosPickerItem?

    @State private var isShowingPaywall = false
    @State private var preview: ProfileLink?

    private var theme: FlightInfoTheme { appearance.theme }

    /// A profile that has never been saved, so the screen can say "claim a
    /// handle" rather than "save changes" and can leave out everything that
    /// needs a row to exist first — a picture has nothing to attach to.
    private var isNew: Bool { !store.hasProfile }

    var body: some View {
        MapPanel(
            title: isNew ? "Claim a handle" : "Your profile",
            subtitle: isNew ? "This is how pilots find you" : "@\(draft.handle)",
            accessory: isNew ? nil : previewButton
        ) {
            if !accounts.isSignedIn {
                signedOut
            } else {
                if draft.isHidden { hiddenNotice }

                identitySection
                if !isNew { picturesSection }
                aboutSection
                favouriteSection
                privacySection

                if let problem = store.problem { message(problem, isProblem: true) }
                if let notice = store.notice { message(notice, isProblem: false) }

                saveButton
                if !isNew { footnote }
            }
        }
        .task { await firstLoad() }
        .onChange(of: store.profile) { _, _ in adoptStored() }
        .onChange(of: store.needsProFor) { _, feature in
            if feature != nil { isShowingPaywall = true }
        }
        .sheet(isPresented: $isShowingPaywall, onDismiss: { store.needsProFor = nil }) {
            ProPanel(highlighted: store.needsProFor ?? .profileBanner)
        }
        .sheet(item: $preview) { link in
            PublicProfileView(link: link)
        }
        .onChange(of: avatarPick) { _, item in load(item, as: .avatar) }
        .onChange(of: bannerPick) { _, item in load(item, as: .banner) }
    }

    private var previewButton: AnyView {
        AnyView(
            Button { preview = .handle(draft.handle) } label: {
                Text("View")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background { Capsule().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See your profile as others do")
        )
    }

    // MARK: - Sections

    private var signedOut: some View {
        PanelSection(title: "SIGN IN FIRST") {
            PanelEmptyState(
                symbol: "person.crop.circle.badge.plus",
                title: "A profile needs an account",
                detail: "Your profile follows the account, not the phone — which is the whole point of it. Sign in from the avatar at the top of the map."
            )
        }
    }

    /// Shown to a pilot whose profile has been taken out of public view. They
    /// are told, because being invisible without knowing why is the worst
    /// version of moderation.
    private var hiddenNotice: some View {
        PanelSection(title: "NOT CURRENTLY PUBLIC") {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.moderationNote
                     ?? "This profile has been taken out of public view while it is looked at.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can still see and edit it. Everybody else gets nothing.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var identitySection: some View {
        PanelSection(title: "HANDLE") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("@")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textDim)

                    TextField("speedbird", text: $draft.handle)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft.handle) { _, new in
                            // Typed straight into the shape the server accepts,
                            // rather than accepted and then rejected on save.
                            let cleaned = new.lowercased().filter {
                                $0.isLowercase || $0.isNumber || $0 == "_"
                            }
                            if cleaned != new { draft.handle = String(cleaned.prefix(20)) }
                            handleAvailable = nil
                        }

                    if isCheckingHandle {
                        ProgressView().controlSize(.small)
                    } else if let available = handleAvailable {
                        Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(available ? theme.accent : theme.textDim)
                    }
                }

                Text(handleHint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        // Checked as they stop typing rather than on every keystroke.
        .task(id: draft.handle) {
            guard draft.handle.count >= 3 else {
                handleAvailable = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            isCheckingHandle = true
            defer { isCheckingHandle = false }
            handleAvailable = await store.isHandleAvailable(draft.handle)
        }
    }

    private var handleHint: String {
        if let available = handleAvailable {
            return available
                ? "@\(draft.handle) is free."
                : "@\(draft.handle) is taken, reserved, or not one we can allow."
        }
        if draft.handle.count > 0 && draft.handle.count < 3 {
            return "Three characters at least."
        }
        return isNew
            ? "Letters, numbers and underscores. This is the name in your profile's link, and it can only be changed once a month."
            : "Changing this changes your link, and can only be done once every 30 days."
    }

    private var picturesSection: some View {
        PanelSection(title: "PICTURES") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    PilotAvatar(
                        url: draft.avatarURL,
                        initials: initials,
                        side: 64,
                        isPro: entitlements.isPro
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(selection: $avatarPick, matching: .images) {
                            pickerLabel(
                                draft.avatarPath == nil ? "Add a picture" : "Change picture",
                                busy: store.uploading == .avatar
                            )
                        }
                        .buttonStyle(.plain)

                        if draft.avatarPath != nil {
                            Button { Task { await store.removeImage(.avatar) } } label: {
                                Text("Remove")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textDim)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 0)
                }

                PanelDivider()

                bannerControls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var bannerControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            PilotBanner(
                url: entitlements.has(.profileBanner) ? draft.bannerURL : nil,
                preset: draft.bannerPreset,
                height: 76
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))

            if entitlements.has(.profileBanner) {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $bannerPick, matching: .images) {
                        pickerLabel(
                            draft.bannerPath == nil ? "Use a photo" : "Change photo",
                            busy: store.uploading == .banner
                        )
                    }
                    .buttonStyle(.plain)

                    if draft.bannerPath != nil {
                        Button { Task { await store.removeImage(.banner) } } label: {
                            Text("Back to a painted one")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Button { isShowingPaywall = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 10, weight: .bold))
                        Text("A photograph up here is part of Inflight Pro")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            // Offered to everybody, Pro included: somebody who has a photograph
            // may still want a different painting under it, and taking the
            // choice away the day they subscribe would be a strange reward.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BannerPreset.allCases) { preset in
                        Button { draft.bannerPreset = preset } label: {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(preset.gradient)
                                .frame(width: 54, height: 34)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(
                                            draft.bannerPreset == preset
                                                ? theme.textPrimary : theme.stroke,
                                            lineWidth: draft.bannerPreset == preset ? 2 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.label)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func pickerLabel(_ title: String, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.small).tint(theme.onAccent)
            } else {
                Image(systemName: "photo").font(.system(size: 11, weight: .bold))
            }
            Text(busy ? "Uploading…" : title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(theme.onAccent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background { Capsule().fill(theme.accent) }
    }

    private var aboutSection: some View {
        PanelSection(title: "ABOUT YOU") {
            field("Name", placeholder: "Speedbird", text: $draft.displayName)
            PanelDivider()

            VStack(alignment: .leading, spacing: 6) {
                PanelRowLabel(title: "Bio", symbol: "text.alignleft")
                TextField("Long haul, mostly.", text: $draft.bio, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text("\(draft.bio.count)/200 · Safe for work, like everything else here.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            PanelDivider()

            VStack(alignment: .leading, spacing: 6) {
                field(
                    "Infinite Flight name",
                    placeholder: identity.isSet ? identity.username : "your display name",
                    text: $draft.ifUsername,
                    monospaced: true
                )
                Text("What links your profile to your aeroplane on the map. Nobody verifies it, so profiles say \"claims to be\" — and it's the same name the tracker already uses to find your own flight.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private var favouriteSection: some View {
        PanelSection(title: "WHAT YOU FLY") {
            field("Favourite aircraft", placeholder: "Boeing 777-300ER",
                  text: $draft.favouriteAircraft)
            PanelDivider()
            field("Livery", placeholder: "British Airways", text: $draft.favouriteLivery)
            PanelDivider()
            field("Home airport", placeholder: "EGLL", text: $draft.homeAirport,
                  monospaced: true, uppercase: true)

            if !draft.favouriteAircraft.isEmpty {
                PanelDivider()
                Text("Your profile draws this aeroplane on a community photograph of it, in the livery you name.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
        }
    }

    private var privacySection: some View {
        PanelSection(title: "WHO CAN SEE IT") {
            PanelToggleRow(
                title: "Public profile",
                symbol: "globe",
                detail: "Off takes you out of search and off everybody's lists. Nothing is deleted, and you can turn it back on.",
                isOn: $draft.isPublic
            )

            PanelDivider()

            PanelPickerRow(
                title: "Friends list",
                symbol: "person.2",
                options: ProfileStore.Visibility.allCases,
                label: { $0.label },
                detail: "Your friends are other people's names, so this is separate from the rest.",
                selection: $draft.friendsVisibility
            )

            PanelDivider()

            PanelPickerRow(
                title: "Logbook",
                symbol: "book.closed",
                options: ProfileStore.Visibility.allCases,
                label: { $0.label },
                detail: entitlements.has(.logbook)
                    ? "Every flight the tracker watches you finish."
                    : "Every flight is recorded whatever your plan. A free profile shows its last \(ProFeature.freeLogbookEntries); Inflight Pro shows the lot.",
                selection: $draft.logbookVisibility
            )

            PanelDivider()

            PanelPickerRow(
                title: "Live status",
                symbol: "dot.radiowaves.up.forward",
                options: ProfileStore.Visibility.allCases,
                label: { $0.label },
                detail: "Where you are while you are actually flying, from Infinite Flight "
                      + "Connect. Only ever shown while you are in the air, and only if you "
                      + "have switched sharing on under Settings → The sim.",
                selection: $draft.liveVisibility
            )
        }
    }

    private var saveButton: some View {
        Button {
            Task { @MainActor in
                if await store.save(draft), isNew { dismiss() }
            }
        } label: {
            Text(store.isSaving ? "Saving…" : (isNew ? "Claim @\(draft.handle)" : "Save"))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .fill(canSave ? theme.accent : theme.surfaceFill)
                }
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    private var canSave: Bool {
        !store.isSaving && draft.handle.count >= 3 && handleAvailable != false
    }

    private var footnote: some View {
        Text("Your profile lives at inflight.info/pilot/\(draft.handle) — anybody can open it, with or without the app.")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    // MARK: - Pieces

    private func field(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false,
        uppercase: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelRowLabel(title: title, symbol: symbol(for: title))
            TextField(placeholder, text: text)
                .font(.system(
                    size: 14,
                    weight: .medium,
                    design: monospaced ? .monospaced : .default
                ))
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(uppercase ? .characters : .words)
                .autocorrectionDisabled(monospaced)
                .onChange(of: text.wrappedValue) { _, new in
                    if uppercase, new != new.uppercased() { text.wrappedValue = new.uppercased() }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func symbol(for title: String) -> String {
        switch title {
        case "Name": return "person"
        case "Infinite Flight name": return "at"
        case "Favourite aircraft": return "airplane"
        case "Livery": return "paintbrush"
        case "Home airport": return "mappin.and.ellipse"
        default: return "square"
        }
    }

    private func message(_ text: String, isProblem: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isProblem ? theme.textPrimary : theme.textSecondary)
        .padding(.horizontal, 2)
    }

    private var initials: String {
        let source = draft.displayName.isEmpty ? draft.handle : draft.displayName
        let letters = source.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    // MARK: - Work

    @MainActor
    private func firstLoad() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await store.load()
        adoptStored()
    }

    /// Takes the stored row into the draft, without stamping over an edit in
    /// progress. Only ever on first load and after a save — both times the
    /// stored row IS what the user just asked for.
    private func adoptStored() {
        guard let stored = store.profile else { return }
        draft = stored
        handleAvailable = nil
    }

    @MainActor
    private func load(_ item: PhotosPickerItem?, as kind: ProfileStore.ImageKind) {
        guard let item = item else { return }

        // Checked before the picker's data is even read, so a free account
        // tapping the banner gets the paywall rather than a spinner and then a
        // refusal from the server.
        if let feature = kind.feature, !entitlements.has(feature) {
            isShowingPaywall = true
            return
        }

        Task { @MainActor in
            defer {
                // Cleared either way, so picking the same photograph twice
                // still fires — `onChange` only fires on a change.
                if kind == .avatar { avatarPick = nil } else { bannerPick = nil }
            }

            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                store.problem = "That picture couldn't be read."
                return
            }
            await store.upload(image, as: kind)
        }
    }
}
