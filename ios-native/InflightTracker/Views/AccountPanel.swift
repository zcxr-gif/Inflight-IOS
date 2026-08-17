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
    @ObservedObject private var store = ProStore.shared

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

    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Account", subtitle: subtitle) {
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
            await accounts.refreshProfile()
            if email.isEmpty { email = accounts.rememberedEmail }
        }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
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

    /// What Pro is, from an account's point of view. Three quite different
    /// things to say — you have it from the App Store, you have it from the
    /// website, or you don't have it — and conflating them is how someone ends
    /// up tapping Restore for a subscription that was never an App Store
    /// purchase.
    @ViewBuilder
    private var proSection: some View {
        PanelSection(title: "INFLIGHT PRO") {
            switch entitlements.source {
            case .appStore:
                statusRow(
                    symbol: "checkmark.seal.fill",
                    title: "Pro is active",
                    detail: "Bought on the App Store. It follows your Apple Account to any device you sign in on."
                )

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

            case .none:
                PanelActionRow(
                    title: "Get Inflight Pro",
                    symbol: "sparkles",
                    detail: store.displayPrice.map { "\($0), bought once." }
                        ?? "One payment, no subscription."
                ) {
                    isShowingPaywall = true
                }
            }
        }
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

        PanelSection(title: intent == .signIn ? "SIGN IN" : "CREATE AN ACCOUNT") {
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
