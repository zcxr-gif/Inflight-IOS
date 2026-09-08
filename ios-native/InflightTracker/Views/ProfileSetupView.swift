import PhotosUI
import SwiftUI

/// Making a profile, in one sitting.
///
/// ## What it replaced
///
/// Setting up a profile used to be four separate errands, and nothing told you
/// there were four. You made an account. Then, if you ever found the row, you
/// opened the editor and claimed a handle — which is where it ended for most
/// people, because the editor hides the pictures until the row exists, so the
/// screen you had just used had nothing on it about a photograph. Then you came
/// back and added one. And the Infinite Flight username — the single field that
/// joins a profile to an aeroplane on the map, and without which the app cannot
/// tell you anything about your own flight — was on a different panel again,
/// under a different heading, and was nobody's idea of part of signing up.
///
/// The result was predictable and visible in the data: accounts with a handle
/// and no picture, accounts with a picture and no Infinite Flight name, and
/// profiles that existed but were joined to nothing.
///
/// This is the same four things in one flow, opened by the app the moment an
/// account is made rather than waiting to be found.
///
/// ## Why it is steps rather than one long form
///
/// The editor is the long form, and it stays the long form — it is the right
/// shape for changing one thing about a profile you already have. This is the
/// first run, where the person does not yet know what a handle is for, has no
/// opinion about a banner, and is one dull screen away from putting the phone
/// down. Three short steps that each ask one thing, each say what it is for,
/// and each can be skipped is a different job from a page of fields.
///
/// ## Why the row is written half way through
///
/// A picture has to be attached to something: `profile-image` stores it under
/// the account and the profile row is what points at it, so the row has to
/// exist before step three can do anything. So leaving the Infinite Flight step
/// saves what has been gathered so far — handle, name, username — and step
/// three edits a profile that is already real. That is also the useful failure
/// mode: somebody who closes the sheet on the last step still has a profile,
/// still has their handle, and is joined to their aeroplane. They are missing a
/// photograph, which is the one part of this that can wait.
struct ProfileSetupView: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var identity = PilotIdentity.shared

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProfileStore.Editable()
    @State private var step: Step = .name
    @State private var hasPrefilled = false

    @State private var handleAvailable: Bool?
    @State private var isCheckingHandle = false

    /// What the Live API said about the name typed on step two, and whether we
    /// have asked yet. Three states, all of them worth drawing differently: not
    /// asked, asked and found nobody, asked and found somebody.
    @State private var sync: SyncResult = .idle

    @State private var avatarPick: PhotosPickerItem?
    @State private var isShowingPaywall = false

    private var theme: FlightInfoTheme { appearance.theme }

    enum Step: Int, CaseIterable {
        case name
        case sim
        case picture

        var title: String {
            switch self {
            case .name:    return "Pick a name"
            case .sim:     return "Find your aeroplane"
            case .picture: return "Put a face to it"
            }
        }

        var subtitle: String {
            switch self {
            case .name:    return "Step 1 of 3"
            case .sim:     return "Step 2 of 3"
            case .picture: return "Step 3 of 3"
            }
        }
    }

    enum SyncResult: Equatable {
        case idle
        case checking
        case found(IFPilotStats)
        case missing
        case unreachable
    }

    var body: some View {
        MapPanel(title: step.title, subtitle: step.subtitle) {
            progress

            switch step {
            case .name:    nameStep
            case .sim:     simStep
            case .picture: pictureStep
            }

            if let problem = store.problem { message(problem, isProblem: true) }

            footer
        }
        .task { await prefill() }
        .onChange(of: avatarPick) { _, item in load(item) }
        .onChange(of: store.needsProFor) { _, feature in
            if feature != nil { isShowingPaywall = true }
        }
        .sheet(isPresented: $isShowingPaywall, onDismiss: { store.needsProFor = nil }) {
            ProPanel(highlighted: store.needsProFor ?? .profileBanner)
        }
    }

    // MARK: - Where you are

    /// Three bars rather than a spinner or a page count alone.
    ///
    /// It is the one piece of chrome worth spending on a first run: the
    /// difference between "this is a form" and "this is three questions and I
    /// can see the end of it" is most of whether somebody finishes.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { each in
                Capsule()
                    .fill(each.rawValue <= step.rawValue ? theme.accent : theme.stroke)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 2)
        .motion(Motion.content, value: step)
        .accessibilityLabel(step.subtitle)
    }

    // MARK: - Step one

    private var nameStep: some View {
        PanelSection(title: "YOUR HANDLE") {
            VStack(alignment: .leading, spacing: 10) {
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
                            // rather than accepted and then refused on save.
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
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .flightInfoSurface(theme, radius: theme.radiusSmall)

                Text(handleHint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                PanelDivider()

                TextField("What people should call you", text: $draft.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .flightInfoSurface(theme, radius: theme.radiusSmall)

                Text("The handle is your link — inflight.info/pilot/\(draft.handle.isEmpty ? "…" : draft.handle). The name under it is the one people read.")
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
        if !draft.handle.isEmpty && draft.handle.count < 3 { return "Three characters at least." }
        return "Letters, numbers and underscores. It can only be changed once a month, so pick one you will still like."
    }

    // MARK: - Step two

    /// The Infinite Flight username, checked against Infinite Flight.
    ///
    /// This is the step that did not exist. The name is the join between an
    /// account here and an aeroplane on the map, and it was previously typed
    /// into a settings field with nothing to say whether it was right — a typo
    /// there means the app never marks your own flight, never records a logbook
    /// entry, and never sends you a notice about a landing you just made, and
    /// nothing anywhere says why.
    ///
    /// So it is checked. The backend resolves the name against the Live API and
    /// hands back what it found, which is both the confirmation and the first
    /// thing this profile has ever said that nobody typed.
    private var simStep: some View {
        PanelSection(title: "YOUR INFINITE FLIGHT NAME") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Exactly as it is in the sim", text: $draft.ifUsername)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: draft.ifUsername) { _, _ in sync = .idle }
                        .onSubmit { Task { await check() } }

                    Button { Task { await check() } } label: {
                        Text(sync == .checking ? "Checking…" : "Check")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background { Capsule().fill(theme.accent) }
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.ifUsername.count < 3 || sync == .checking)
                    .opacity(draft.ifUsername.count < 3 || sync == .checking ? 0.45 : 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .flightInfoSurface(theme, radius: theme.radiusSmall)

                syncAnswer

                Text("This is how the tracker picks your aeroplane out of the traffic — it is what marks your own flight on the map, writes your logbook, and lets us tell you when you have landed.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// What came back, said plainly.
    ///
    /// A found pilot is shown their own grade and virtual airline, because that
    /// is proof of the right kind: it is not "saved", it is the server reading
    /// back something about them that they never told us.
    @ViewBuilder
    private var syncAnswer: some View {
        switch sync {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking Infinite Flight…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }

        case .found(let stats):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Found you.")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    Text(foundLine(stats))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .flightInfoSurface(theme, radius: theme.radiusSmall, elevated: true)

        case .missing:
            message(
                "No Infinite Flight account with that name. Check the spelling — it is the name in the sim, not an email address.",
                isProblem: true
            )

        case .unreachable:
            message(
                "Couldn't reach Infinite Flight to check. The name is saved either way; if it is right, everything will start working on its own.",
                isProblem: false
            )
        }
    }

    private func foundLine(_ stats: IFPilotStats) -> String {
        var parts: [String] = []
        if let grade = stats.gradeBadge { parts.append(grade.label.capitalized) }
        if let org = stats.virtualOrganization { parts.append(org) }
        if let landings = stats.landingCount, landings > 0 {
            parts.append("\(Format.number(Double(landings))) landings")
        }
        return parts.isEmpty ? "Your flights will be marked as yours." : parts.joined(separator: " · ")
    }

    // MARK: - Step three

    private var pictureStep: some View {
        PanelSection(title: "YOUR PICTURE") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    PilotAvatar(
                        url: draft.avatarURL,
                        initials: draft.initials,
                        side: 64,
                        isPro: entitlements.isPro
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        // Read out here rather than inside the label closure,
                        // which SwiftUI marks `@Sendable`.
                        let busy = store.uploading == .avatar

                        PhotosPicker(selection: $avatarPick, matching: .images) {
                            HStack(spacing: 6) {
                                if busy {
                                    ProgressView().controlSize(.small).tint(theme.onAccent)
                                } else {
                                    Image(systemName: "photo").font(.system(size: 11, weight: .bold))
                                }
                                Text(busy ? "Uploading…"
                                     : draft.avatarPath == nil ? "Choose a picture" : "Change it")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background { Capsule().fill(theme.accent) }
                        }
                        .buttonStyle(.plain)

                        Text("Or leave it — your initials do the job until you have one.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                PanelDivider()

                bannerPicker
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// The painted banners, and only those.
    ///
    /// The photographic banner is Pro and is deliberately not sold here. This
    /// is the last screen of somebody's first two minutes with an account they
    /// have just made; putting a locked control on it turns "set up your
    /// profile" into "here is what you cannot have". The editor offers it, and
    /// by the time somebody opens the editor they are a person who wants a
    /// better banner rather than a person who has just signed up.
    private var bannerPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("AND A BACKDROP")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textDim)

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

    // MARK: - Getting on with it

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await advance() }
            } label: {
                HStack(spacing: 8) {
                    if store.isSaving { ProgressView().tint(theme.onAccent) }
                    Text(primaryLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .fill(theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdvance)
            .opacity(canAdvance ? 1 : 0.45)

            // Every step past the first can be skipped, and says so. A profile
            // with a handle and nothing else is a working profile; a person
            // held on a screen until they fill in a field they do not
            // understand is a person who force-quits the app.
            if step != .name {
                Button {
                    Task { await skip() }
                } label: {
                    Text(step == .picture ? "Not now" : "Skip for now")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private var primaryLabel: String {
        switch step {
        case .name:    return "Continue"
        case .sim:     return "Save and carry on"
        case .picture: return "Done"
        }
    }

    private var canAdvance: Bool {
        guard !store.isSaving, store.uploading == nil else { return false }
        switch step {
        case .name:    return draft.handle.count >= 3 && handleAvailable != false
        case .sim:     return true
        case .picture: return true
        }
    }

    // MARK: - Work

    /// Fills in everything already known before the person is asked for any of
    /// it.
    ///
    /// All three come from somewhere real: the Infinite Flight name may already
    /// be set on the device or on the website, Apple hands over a full name on
    /// the first Sign in with Apple, and the local part of an email address is
    /// what most people would have typed as a handle anyway. A first field that
    /// is already filled in correctly is worth more than any amount of
    /// explanatory copy above it.
    @MainActor
    private func prefill() async {
        guard !hasPrefilled else { return }
        hasPrefilled = true

        await store.load()

        // Somebody who already has a profile is not setting one up. This is
        // reachable — the sheet can be opened from the account panel — and the
        // right thing is to carry on from what is there rather than to draw
        // empty fields over it.
        if let stored = store.profile {
            draft = stored
            step = stored.avatarPath == nil ? .picture : .name
        }

        if draft.ifUsername.isEmpty { draft.ifUsername = identity.username }

        if draft.displayName.isEmpty {
            draft.displayName = accounts.account?.displayName
                ?? (draft.ifUsername.isEmpty ? "" : draft.ifUsername)
        }

        if draft.handle.isEmpty {
            draft.handle = Self.suggestedHandle(
                ifUsername: draft.ifUsername,
                email: accounts.account?.email
            )
        }
    }

    /// A handle worth offering, out of what is already known.
    ///
    /// The Infinite Flight name first: somebody whose two names match is
    /// findable by people who only know one of them, which is the whole reason
    /// a handle exists. The email's local part second, cleaned the same way the
    /// field cleans typing. Empty when neither survives the cleaning, which is
    /// a blank field rather than a suggestion of "user".
    static func suggestedHandle(ifUsername: String?, email: String?) -> String {
        let candidates = [ifUsername, email?.split(separator: "@").first.map(String.init)]
        for candidate in candidates {
            let cleaned = (candidate ?? "")
                .lowercased()
                .filter { $0.isLowercase || $0.isNumber || $0 == "_" }
            if cleaned.count >= 3 { return String(cleaned.prefix(20)) }
        }
        return ""
    }

    /// Asks Infinite Flight whether the typed name is anybody.
    @MainActor
    private func check() async {
        let typed = draft.ifUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 3 else { return }

        sync = .checking
        // Dropped first, so somebody who mistyped, was told so, and corrected
        // it is not shown the cached refusal for the old spelling.
        PilotStatsService.shared.forget(ifUsername: typed)

        switch await PilotStatsService.shared.resolve(ifUsername: typed) {
        case .found(let stats):
            // Infinite Flight's own spelling wins. Handles there are
            // case-sensitive in exactly the way people get wrong, and the name
            // has to match what the feed sends for the join to work at all.
            if let canonical = stats.username, !canonical.isEmpty {
                draft.ifUsername = canonical
            }
            sync = .found(stats)

        case .missing:
            sync = .missing

        case .unreachable:
            sync = .unreachable
        }
    }

    /// The primary button. Saves where saving is what the step means, and
    /// finishes on the last one.
    @MainActor
    private func advance() async {
        switch step {
        case .name:
            withAnimation(Motion.content) { step = .sim }

        case .sim:
            // The one write of the flow. See the note at the top for why it is
            // here rather than at the end.
            guard await store.save(draft) else { return }
            if let stored = store.profile { draft = stored }
            withAnimation(Motion.content) { step = .picture }

        case .picture:
            // Only the banner choice can have changed since the write above,
            // and only when they picked one — so this is a save rather than
            // nothing, but not one worth blocking the dismissal on.
            if store.profile?.bannerPreset != draft.bannerPreset {
                await store.save(draft)
            }
            dismiss()
        }
    }

    /// Skipping still saves, and skips the *question* rather than the field.
    ///
    /// Two things follow from that. Somebody who skips past the Infinite Flight
    /// name has still claimed a handle, and closing the sheet without writing it
    /// would throw away the step they did answer. And a name already in the box
    /// — prefilled off the device, or typed and not checked — is kept: skipping
    /// means "don't make me check this now", and blanking a name the pilot had
    /// already set somewhere else would be the screen taking something away in
    /// exchange for being dismissed.
    @MainActor
    private func skip() async {
        switch step {
        case .name:
            break

        case .sim:
            guard await store.save(draft) else { return }
            if let stored = store.profile { draft = stored }
            withAnimation(Motion.content) { step = .picture }

        case .picture:
            dismiss()
        }
    }

    @MainActor
    private func load(_ item: PhotosPickerItem?) {
        guard let item = item else { return }

        Task { @MainActor in
            // Cleared either way, so picking the same photograph twice still
            // fires — `onChange` only fires on a change.
            defer { avatarPick = nil }

            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                store.problem = "That picture couldn't be read."
                return
            }
            await store.upload(image, as: .avatar)
            if let stored = store.profile { draft = stored }
        }
    }

    private func message(_ text: String, isProblem: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isProblem ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isProblem ? theme.textPrimary : theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }
}
