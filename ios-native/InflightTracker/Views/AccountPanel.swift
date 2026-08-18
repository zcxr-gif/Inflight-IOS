import AuthenticationServices
import SwiftUI

/// The profile panel: sign in, or look at the account you are signed into.
///
/// The account is the old build's — same Supabase project, same passwords, same
/// `profiles` row (see `SupabaseAuth`). What is not the old build's is any of
/// this: no modal stack, no gradient card, no crown. It is a panel like every
/// other panel in the app, because that is what it is.
struct AccountPanel: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var identity = PilotIdentity.shared
    @ObservedObject private var highlight = PilotHighlightPreferences.shared

    /// Sign in, or make one. One form either way — the fields are the same and
    /// the difference is one word on the button — so this is a segmented
    /// control rather than two screens.
    private enum Intent: String, CaseIterable, Identifiable {
        case signIn
        case signUp

        var id: String { rawValue }

        var label: String {
            switch self {
            case .signIn: return "Sign in"
            case .signUp: return "Create account"
            }
        }
    }

    @State private var intent: Intent = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isShowingPaywall = false
    @State private var isConfirmingDeletion = false

    /// The profile editor, and a preview of the profile as strangers see it.
    @State private var isShowingProfileEditor = false
    @State private var viewing: ProfileLink?

    /// The IFC handle being edited. Committed on submit rather than per
    /// keystroke, so a half-typed name never briefly matches somebody.
    @State private var handleDraft = ""
    @State private var handleProblem: String?

    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Account", subtitle: subtitle) {
            profileSection

            pilotSection

            colorSection

            if accounts.isRestoring && accounts.account == nil {
                PanelSection(title: "ACCOUNT") {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking your session…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else if let account = accounts.account {
                signedIn(account)
            } else {
                signedOut
            }
        }
        .task {
            await accounts.restore()
            await accounts.refreshEntitlement()
            await profiles.load()
            if email.isEmpty { email = accounts.rememberedEmail }
            if handleDraft.isEmpty { handleDraft = identity.username }
        }
        // A name set on the website arrives with the session, after this panel
        // has already drawn its empty field.
        .onChange(of: identity.username) { _, name in
            if handleDraft.isEmpty { handleDraft = name }
        }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
        .sheet(isPresented: $isShowingProfileEditor) { ProfileEditorView() }
        .sheet(item: $viewing) { link in PublicProfileView(link: link) }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await accounts.deleteAccount() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your account and everything stored against it are erased.")
        }
    }

    private var subtitle: String {
        if let account = accounts.account {
            return entitlements.isPro ? "\(account.email) · Pro" : account.email
        }
        return "Your watchlist and your Pro, on every device"
    }

    // MARK: - Your public profile

    /// The one thing on this panel that other people can see.
    ///
    /// Sits above the Infinite Flight handle because it is the thing somebody
    /// opens the account panel for now — the handle below is machinery, and a
    /// profile is a thing you have.
    @ViewBuilder
    private var profileSection: some View {
        PanelSection(title: "YOUR PROFILE") {
            if !accounts.isSignedIn {
                Text("Sign in below and you can claim a handle — a page with your picture, the aeroplane you fly and the pilots you fly with, that anybody can open.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else if let profile = profiles.profile {
                Button { isShowingProfileEditor = true } label: {
                    HStack(spacing: 12) {
                        PilotAvatar(
                            url: profile.avatarURL,
                            initials: profile.handle.prefix(2).uppercased(),
                            side: 42,
                            isPro: entitlements.isPro
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName.isEmpty ? profile.handle : profile.displayName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                                .flightInfoLine(minimumScale: 0.8)

                            Text(profile.isHidden
                                 ? "Not currently public"
                                 : profile.isPublic ? "@\(profile.handle)"
                                                    : "@\(profile.handle) · hidden")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textDim)
                                .flightInfoLine(minimumScale: 0.7)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textDim)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                PanelDivider()

                PanelActionRow(
                    title: "See it as others do",
                    symbol: "eye",
                    detail: "inflight.info/pilot/\(profile.handle)"
                ) {
                    viewing = .handle(profile.handle)
                }
            } else {
                PanelActionRow(
                    title: "Claim a handle",
                    symbol: "person.crop.circle.badge.plus",
                    detail: "A page with your picture, the aeroplane you fly, and the pilots you fly with. Anybody can open it — no app needed."
                ) {
                    isShowingProfileEditor = true
                }
            }
        }
    }

    // MARK: - Who you are on the server

    /// Your Infinite Flight community handle.
    ///
    /// The feed names the pilot of every aircraft but has no idea which one is
    /// yours, so this is the one thing it cannot work out for itself. The
    /// Capacitor build asked for exactly this and stored it in the same place
    /// — `user_metadata.if_username` — so a handle set on the website is
    /// already here.
    ///
    /// Above the sign-in form on purpose: it works signed out, and finding your
    /// own aircraft is not something anyone should need an account for.
    private var pilotSection: some View {
        PanelSection(title: "YOUR CALLSIGN") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 20)

                    TextField("Infinite Flight username", text: $handleDraft)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { commitHandle() }

                    if handleDraft != identity.username {
                        Button("Save") { commitHandle() }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .fill(theme.surfaceFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                                .strokeBorder(theme.stroke, lineWidth: 1)
                        }
                }

                if let problem = handleProblem {
                    message(problem, symbol: "exclamationmark.triangle", isProblem: true)
                }

                Text(identity.isSet
                     ? "The tracker marks \(identity.username)'s aircraft as yours."
                     : "Exactly as it appears in Infinite Flight, so the tracker can pick your aircraft out of the traffic.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func commitHandle() {
        focus = nil
        let typed = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if typed.isEmpty {
            identity.clear()
            handleDraft = ""
            handleProblem = nil
            return
        }

        guard let saved = identity.set(typed) else {
            handleProblem = "That doesn't look like an Infinite Flight username — letters, numbers, dots, dashes and underscores only."
            return
        }

        handleDraft = saved
        handleProblem = nil

        // Mirrored onto the account so it follows you to another device, the
        // same field the website reads. Best effort: the handle is already
        // saved on this device, and a failed sync is not worth a message.
        Task { await accounts.syncPilotName(saved) }
    }

    // MARK: - Colours

    /// What your own aircraft and your watchlist are painted.
    ///
    /// Pro. The defaults are the web build's amber and amethyst, which is what
    /// anyone coming from it will expect to see.
    @ViewBuilder
    private var colorSection: some View {
        PanelSection(title: "PICK YOUR TRAFFIC OUT") {
            if entitlements.has(.pilotColours) {
                PanelToggleRow(
                    title: "Colour my traffic",
                    symbol: "paintpalette",
                    detail: "Your aircraft and everyone you watch, painted on the map.",
                    isOn: $highlight.isEnabled
                )

                if highlight.isEnabled {
                    PanelDivider()

                    colorRow("Your aircraft", symbol: "airplane", selection: $highlight.ownColor)

                    PanelDivider()

                    colorRow("Watched pilots", symbol: "person.2.fill", selection: $highlight.friendColor)

                    PanelDivider()

                    Button {
                        highlight.resetColors()
                    } label: {
                        HStack(spacing: 10) {
                            PanelRowLabel(title: "Back to the defaults", symbol: "arrow.counterclockwise")
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                PanelActionRow(
                    title: "Colour my traffic",
                    symbol: "paintpalette",
                    detail: "Pro. Your own aircraft and every pilot you watch, picked out of the traffic in colours you choose."
                ) {
                    isShowingPaywall = true
                }
            }
        }
    }

    private func colorRow(_ title: String, symbol: String, selection: Binding<Color>) -> some View {
        HStack(spacing: 10) {
            PanelRowLabel(title: title, symbol: symbol)

            Spacer(minLength: 8)

            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedIn(_ account: AccountStore.Account) -> some View {
        PanelSection(title: "SIGNED IN") {
            HStack(spacing: 12) {
                // Initials rather than a photo: the profile has no picture to
                // show, and a grey silhouette says less than two letters do.
                Text(account.initials)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background { Circle().fill(theme.accent) }

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.handle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.8)

                    Text(account.email)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }

                Spacer(minLength: 8)

                if entitlements.isPro {
                    Text("PRO")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background { Capsule().fill(theme.accent) }
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let joined = account.joined {
                PanelDivider()
                detailRow("Member since", value: joined.formatted(.dateTime.month(.wide).year()))
            }
        }

        proSection

        PanelSection(title: "SESSION") {
            Button {
                Task { await accounts.signOut() }
            } label: {
                HStack(spacing: 10) {
                    PanelRowLabel(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right")
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            PanelDivider()

            Text("Signing out leaves the watchlist on this device. It is filed under the phone, not the account — see Friends.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }

        // Last, and behind a confirmation, but genuinely here: an app that
        // lets you make an account has to let you delete it from inside the
        // app. Burying it on a website is exactly what that rule exists to
        // stop.
        PanelSection(title: "DELETE ACCOUNT") {
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                HStack(spacing: 10) {
                    PanelRowLabel(title: "Delete my account", symbol: "trash")
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(accounts.isWorking)
            .opacity(accounts.isWorking ? 0.45 : 1)

            // The signed-out form has its own place to put this; signed in,
            // deletion is the only thing that can fail, so it reports here.
            if let problem = accounts.problem {
                PanelDivider()

                message(problem, symbol: "exclamationmark.triangle", isProblem: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }

            PanelDivider()

            Text("Erases the account and everything on the server that belongs to it, for good. An App Store purchase of Pro is not affected — it belongs to your Apple Account, and Restore brings it back.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    /// What Pro is, from an account's point of view. Four quite different
    /// things to say — a plan on the App Store, a subscription on the website,
    /// a grandfathered account, or none of them — and conflating them is how
    /// someone ends up tapping Restore for a subscription that was never an
    /// App Store purchase, or looking for a Cancel button on a plan that does
    /// not renew.
    @ViewBuilder
    private var proSection: some View {
        PanelSection(title: "INFLIGHT PRO") {
            switch entitlements.source {
            case .appStore:
                statusRow(
                    symbol: "checkmark.seal.fill",
                    title: "Pro is active",
                    detail: appStoreDetail
                )

                if store.ownedPlan?.isSubscription == true,
                   let manage = AppConfig.manageSubscriptionsURL {
                    PanelDivider()

                    Link(destination: manage) {
                        HStack(spacing: 10) {
                            PanelRowLabel(title: "Manage subscription", symbol: "creditcard")
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

            case .subscription:
                statusRow(
                    symbol: "checkmark.seal.fill",
                    title: "Pro is active",
                    detail: "From your subscription on inflight.info. Nothing to buy here."
                )

            case .legacy:
                statusRow(
                    symbol: "checkmark.seal.fill",
                    title: "Pro is active",
                    detail: "Your account has Pro from before it was sold separately. It stays that way."
                )

            case .free:
                PanelActionRow(
                    title: "Get Inflight Pro",
                    symbol: "sparkles",
                    detail: store.displayPrice.map { "From \($0) a year. Cancel any time." }
                        ?? "A year or a month. Cancel any time."
                ) {
                    isShowingPaywall = true
                }
            }
        }
    }

    /// What to say about an App Store entitlement: a plan that renews, a plan
    /// that has been told not to, and the retired lifetime unlock that never
    /// had to. The last is no longer sold and is still honoured, so its line
    /// still has to be here.
    private var appStoreDetail: String {
        if store.ownedPlan == .lifetime {
            return "The lifetime unlock, on your Apple Account. It follows that account to any device you sign in on."
        }

        guard let until = accounts.account?.proUntil else {
            return "Bought on the App Store. It follows your Apple Account to any device you sign in on."
        }

        let date = until.formatted(.dateTime.day().month(.abbreviated).year())
        return accounts.account?.proCancelsAtPeriodEnd == true
            ? "Runs until \(date), and will not renew after that."
            : "Renews \(date). Cancel any time in Settings."
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOut: some View {
        PanelSection(title: "WHY") {
            Text("An account carries your Inflight Pro between devices, and is the same one you use on inflight.info. The app works signed out — this only exists for the things that have to follow you.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }

        PanelSection(title: "QUICKEST WAY IN") {
            VStack(alignment: .leading, spacing: 9) {
                // Apple's own button, at Apple's own size and wording. It is
                // a control people recognise, and an imitation of it would be
                // both against the guidelines and worse: this one says
                // "Continue with Apple" in the reader's language without
                // anything here knowing what language that is.
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                    // The hash. The raw nonce stays on the device until the
                    // token comes back — see `AppleSignIn`.
                    request.nonce = accounts.beginAppleSignIn()
                } onCompletion: { result in
                    Task { await accounts.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(theme.isLight ? .black : .white)
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
                .disabled(accounts.isWorking)
                .opacity(accounts.isWorking ? 0.55 : 1)

                Text("No password to make up, and no email address to hand over if you would rather not — Apple can hide it.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        PanelSection(title: intent == .signIn ? "SIGN IN WITH EMAIL" : "CREATE AN ACCOUNT") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $intent) {
                    ForEach(Intent.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: intent) { _, _ in
                    accounts.problem = nil
                    accounts.notice = nil
                }

                field(
                    "Email",
                    text: $email,
                    symbol: "envelope",
                    isSecure: false,
                    field: .email
                )

                field(
                    "Password",
                    text: $password,
                    symbol: "lock",
                    isSecure: true,
                    field: .password
                )

                if let problem = accounts.problem {
                    message(problem, symbol: "exclamationmark.triangle", isProblem: true)
                }

                if let notice = accounts.notice {
                    message(notice, symbol: "envelope.badge", isProblem: false)
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if accounts.isWorking {
                            ProgressView().tint(theme.onAccent)
                        }
                        Text(intent.label)
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
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)

                if intent == .signIn {
                    Button {
                        Task { await accounts.sendPasswordReset(email: email) }
                    } label: {
                        Text("Forgot your password?")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(email.isEmpty || accounts.isWorking)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        // Offered signed out as well as signed in: a purchase belongs to the
        // Apple Account, so someone reinstalling can get Pro back without
        // remembering a password they may never have set.
        PanelSection(title: "ALREADY BOUGHT PRO") {
            PanelActionRow(
                title: "Restore purchases",
                symbol: "arrow.clockwise",
                detail: "Brings back an App Store purchase on this Apple Account."
            ) {
                Task { await store.restore() }
            }
        }
    }

    private var canSubmit: Bool {
        !accounts.isWorking
            && email.contains("@")
            && password.count >= 6
    }

    private func submit() {
        focus = nil
        let address = email
        let secret = password

        Task {
            switch intent {
            case .signIn: await accounts.signIn(email: address, password: secret)
            case .signUp: await accounts.signUp(email: address, password: secret)
            }
            // Never left sitting in a text field once it has been used.
            password = ""
        }
    }

    // MARK: - Pieces

    private func field(
        _ title: String,
        text: Binding<String>,
        symbol: String,
        isSecure: Bool,
        field: Field
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.textDim)
                .frame(width: 20)

            Group {
                if isSecure {
                    SecureField(title, text: text)
                        .textContentType(intent == .signUp ? .newPassword : .password)
                } else {
                    TextField(title, text: text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .focused($focus, equals: field)
            .submitLabel(field == .email ? .next : .go)
            .onSubmit {
                if field == .email { focus = .password } else { submit() }
            }
            .onChange(of: text.wrappedValue) { _, _ in
                // A complaint about the last attempt has nothing to say about
                // what is being typed now.
                accounts.problem = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                .fill(theme.surfaceFill)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .strokeBorder(focus == field ? theme.strokeStrong : theme.stroke, lineWidth: 1)
                }
        }
    }

    private func message(_ text: String, symbol: String, isProblem: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isProblem ? theme.textPrimary : theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
