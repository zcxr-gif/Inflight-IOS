import AuthenticationServices
import Combine
import Foundation

/// Who is signed in, and what their account is entitled to.
///
/// The tracker shipped without accounts on purpose — the friends list is filed
/// under the APNs device token, which works until you get a new phone and then
/// quietly doesn't. A profile is the answer to that, and it is the same profile
/// the web build has always had: the Supabase project, the `profiles` table and
/// the passwords are all the old ones, so an account made on inflight.info
/// signs in here and vice versa.
///
/// Only the access token is kept in memory. The refresh token — the thing that
/// is actually worth stealing — is in the Keychain, and the session is rebuilt
/// from it on launch.
final class AccountStore: ObservableObject {

    static let shared = AccountStore()

    /// The signed-in account, or nil. Everything else here is about getting
    /// into or out of this one state.
    @Published private(set) var account: Account?

    /// A request is in flight — sign-in, sign-up, reset. Drives the button's
    /// spinner and stops a second tap starting a second one.
    @Published private(set) var isWorking = false

    /// The launch-time attempt to rebuild a session from the stored refresh
    /// token. True until it resolves, so the panel shows nothing rather than
    /// flashing the signed-out state at someone who is signed in.
    @Published private(set) var isRestoring = true

    /// The last thing that went wrong, in the server's own words where it had
    /// any. Cleared by the panel when the user edits a field.
    @Published var problem: String?

    /// Said after a sign-up that needs an email confirmed, or a password reset
    /// that has been sent. Not an error, and not a session either.
    @Published var notice: String?

    struct Account: Equatable {

        let id: String
        let email: String

        /// What the *cloud* thinks: the answer `pro_entitlement()` gave, which
        /// folds together an App Store purchase linked to this account, a web
        /// subscription, and the grandfathered flag.
        var isPro: Bool

        /// Which grant answered, in `pro_entitlement()`'s own words —
        /// 'app-store', 'app-store-lifetime', 'subscription', 'grace',
        /// 'legacy', 'profile', 'expired' or 'free'.
        ///
        /// Kept as the server's string rather than mapped to a local enum here,
        /// because the mapping that matters is `Entitlements.Source` and one
        /// translation is enough. It is what stops the app offering "Restore
        /// purchases" to somebody whose Pro was never an App Store purchase.
        var proSource: String?

        /// When the paid period runs out, for the plans that have one.
        var proUntil: Date?

        /// Set when the plan is paid up but has been told not to renew.
        var proCancelsAtPeriodEnd: Bool

        /// What Apple gave us on the first Sign in with Apple, if that is how
        /// this account was made.
        var displayName: String?

        let joined: Date?

        var grantsPro: Bool { isPro }

        /// Whether the entitlement is one the App Store could restore. Anything
        /// else — a website subscription, a grandfathered account — is not a
        /// purchase on this Apple Account and has nothing to restore.
        var isAppStorePro: Bool {
            proSource == "app-store" || proSource == "app-store-lifetime"
        }

        /// What to draw in the avatar when there is no picture to draw. The
        /// profile has no display name yet, so the local part of the email is
        /// the closest thing to one.
        var handle: String {
            if let name = displayName, !name.isEmpty { return name }
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return local.isEmpty ? email : local
        }

        /// Two letters for the avatar. A real name gives up its initials; a
        /// handle gives up its first two characters, which is the best anyone
        /// can do with "hrantony2230".
        var initials: String {
            let words = handle
                .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
                .filter { $0.contains(where: \.isLetter) }

            if words.count >= 2 {
                return words.prefix(2)
                    .compactMap { $0.first.map(String.init) }
                    .joined()
                    .uppercased()
            }

            let letters = handle.filter { $0.isLetter || $0.isNumber }
            return String(letters.prefix(2)).uppercased()
        }
    }

    private static let emailKey = "account.lastEmail"

    /// Held rather than published: it is a credential, and no view needs it.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    /// The raw nonce for the Sign in with Apple request in flight, between the
    /// button building the request and Apple answering it.
    private var appleNonce: String?

    private init() {}

    var isSignedIn: Bool { account != nil }

    /// The email last signed in with, so the sign-in form opens filled. Kept
    /// after a sign-out on purpose — it is not a secret, and typing an address
    /// on a phone is the tedious part.
    var rememberedEmail: String {
        UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
    }

    // MARK: - Launch

    /// Rebuilds the session from the Keychain. Safe to call more than once.
    @MainActor
    func restore() async {
        guard account == nil, let token = SessionKeychain.read() else {
            isRestoring = false
            return
        }

        isRestoring = true
        defer { isRestoring = false }

        do {
            let session = try await SupabaseAuth.refresh(refreshToken: token)
            try await adopt(session)
        } catch {
            // A refresh token is rejected for exactly one interesting reason —
            // it has been revoked, by a password change or a sign-out
            // elsewhere — and for one boring one: the phone is offline. Only
            // the first should cost the stored session, and the two are not
            // distinguishable from here, so the token is kept and the next
            // launch tries again. Nothing is said either way: an account the
            // user cannot see is not worth an error about.
            accessToken = nil
        }
    }

    // MARK: - Sign in / up / out

    @MainActor
    func signIn(email: String, password: String) async {
        await run {
            let session = try await SupabaseAuth.signIn(
                email: Self.clean(email),
                password: password
            )
            try await self.adopt(session)
        }
    }

    /// Sign in with Apple, first half: the nonce.
    ///
    /// Apple's button builds its own request, so the nonce has to be handed to
    /// it as the request is made and kept here until the token comes back —
    /// Supabase needs the raw value to check against the hash Apple embedded.
    /// Returns the hash, which is the only half that leaves the device.
    @MainActor
    func beginAppleSignIn() -> String {
        let nonce = AppleSignIn.nonce()
        appleNonce = nonce
        problem = nil
        notice = nil
        return AppleSignIn.hashed(nonce)
    }

    /// Sign in with Apple, second half.
    ///
    /// Required by App Store Guideline 4.8 the moment an app offers any other
    /// third-party sign-in, and worth having on its own account: it is the one
    /// way in that costs nobody a password. Apple's identity token goes
    /// straight to GoTrue, which verifies it against Apple's own public keys —
    /// this app never handles a credential it could misuse, because there
    /// isn't one.
    @MainActor
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard !isWorking else { return }

        isWorking = true
        defer {
            isWorking = false
            // One nonce, one sign-in. Whatever happened, it is spent.
            appleNonce = nil
        }

        do {
            let credential = try AppleSignIn.credential(from: result)

            guard let nonce = appleNonce else { throw AppleSignIn.Failure.noNonce }

            let session = try await SupabaseAuth.signInWithApple(
                idToken: credential.identityToken,
                nonce: nonce
            )
            try await adopt(session, appleName: credential.fullName)
        } catch AppleSignIn.Failure.cancelled {
            // They tapped Cancel. Nothing to report.
        } catch let failure as SupabaseAuth.Failure {
            problem = failure.message
        } catch let failure as AppleSignIn.Failure {
            problem = failure.errorDescription
        } catch {
            problem = error.localizedDescription
        }
    }

    @MainActor
    func signUp(email: String, password: String) async {
        await run {
            switch try await SupabaseAuth.signUp(email: Self.clean(email), password: password) {
            case .signedIn(let session):
                try await self.adopt(session)

            case .needsConfirmation(let email):
                self.notice = "Check \(email) for a confirmation link, then sign in."
            }
        }
    }

    @MainActor
    func sendPasswordReset(email: String) async {
        await run {
            let address = Self.clean(email)
            try await SupabaseAuth.sendPasswordReset(email: address)
            self.notice = "If \(address) has an account, a reset link is on its way."
        }
    }

    @MainActor
    func signOut() async {
        if let token = accessToken {
            // Before the token goes: the device's push registration belongs to
            // the account, and a row left behind sends this pilot's own flight
            // notices to whoever signs in on this phone next.
            PushService.shared.clearAccountRegistration(accessToken: token)
            await SupabaseAuth.signOut(accessToken: token)
        }

        SessionKeychain.clear()
        accessToken = nil
        accessTokenExpiry = nil
        account = nil
        problem = nil
        notice = nil
        Entitlements.shared.accountChanged()
        // The public profile belongs to the account, not to the phone. Leaving
        // it loaded would show the last person to sign in on this device to the
        // next one.
        ProfileStore.shared.accountChanged()
        PilotDirectory.shared.accountChanged()

        // Carries an agreement made before there was an account onto the
        // account. Not awaited, for the same reason as the profile: it is
        // bookkeeping, and nothing on screen waits for it.
        Task { await self.recordTermsAcceptance() }
    }

    /// Erases the account, then signs out.
    ///
    /// Required to exist by App Store Guideline 5.1.1(v) — an app that lets you
    /// make an account has to let you delete it from inside the app. It is
    /// genuinely irreversible: the auth user goes, and so does everything on
    /// the server keyed to it. What it does *not* touch is anything local — the
    /// watchlist is filed under the device, and deleting an account is not a
    /// reason to take it away.
    @MainActor
    func deleteAccount() async {
        guard account != nil else { return }

        await run {
            let token = try await self.validAccessToken()
            try await SupabaseAuth.deleteAccount(accessToken: token)

            SessionKeychain.clear()
            self.accessToken = nil
            self.accessTokenExpiry = nil
            self.account = nil
            UserDefaults.standard.removeObject(forKey: Self.emailKey)
            Entitlements.shared.accountChanged()
            ProfileStore.shared.accountChanged()
        PilotDirectory.shared.accountChanged()
        }
    }

    /// Pushes the pilot handle onto the account, if there is one.
    ///
    /// Silent either way. The handle is already saved on the device — this only
    /// makes it follow you — so a failed sync is not something to interrupt
    /// anyone about.
    @MainActor
    func syncPilotName(_ name: String) async {
        guard account != nil else { return }
        guard let token = try? await validAccessToken() else { return }
        try? await SupabaseAuth.updatePilotName(name, accessToken: token)
    }

    // MARK: - Terms

    /// Records on the account which version of the terms was agreed to, and
    /// when.
    ///
    /// Called when the gate is accepted and again whenever a session is
    /// adopted, because the two happen in either order: somebody can agree
    /// before they ever make an account, and the agreement has to reach the
    /// account they eventually make. The write is idempotent — it sets the same
    /// version to the same value — so calling it on every sign-in costs one
    /// request and keeps the record true across a reinstall.
    ///
    /// Silent on failure. Agreement is already recorded on the device and the
    /// next sign-in will try again; interrupting somebody to tell them a
    /// bookkeeping write did not land would be the wrong trade.
    @MainActor
    func recordTermsAcceptance() async {
        guard account != nil else { return }
        guard TermsStore.shared.isAccepted else { return }
        guard let token = try? await validAccessToken() else { return }

        let acceptedAt = TermsStore.shared.acceptedAt ?? Date()

        _ = try? await SupabaseData.perform(
            "record_terms_acceptance",
            arguments: [
                "p_version": TermsStore.shared.acceptedVersion,
                "p_accepted_at": ISO8601DateFormatter().string(from: acceptedAt)
            ],
            accessToken: token
        )
    }

    // MARK: - Entitlement

    /// Re-asks the server what this account is entitled to.
    ///
    /// Called after a purchase and whenever the account panel opens, because
    /// the answer can change without this device doing anything — a
    /// subscription renewing or lapsing is the whole point of asking at all.
    @MainActor
    func refreshEntitlement() async {
        guard account != nil else { return }

        do {
            let token = try await validAccessToken()
            apply(try await SupabaseAuth.entitlement(accessToken: token))
        } catch {
            // Leaves whatever the last known answer was. An entitlement is not
            // something to revoke because a request timed out.
        }
    }

    /// Hands the server the App Store purchases StoreKit has verified, so the
    /// entitlement belongs to the account rather than to this phone.
    ///
    /// Silent, and deliberately so: the device has already unlocked Pro on the
    /// strength of Apple's own signature by the time this runs. This is what
    /// makes the same purchase work on inflight.info, and there is nothing for
    /// anybody to do about it failing.
    @MainActor
    func linkAppStorePurchases(_ signedTransactions: [String]) async {
        guard account != nil, !signedTransactions.isEmpty else { return }
        guard let token = try? await validAccessToken() else { return }

        do {
            try await SupabaseAuth.linkAppStoreTransactions(
                signedTransactions,
                accessToken: token
            )
            await refreshEntitlement()
        } catch {
            // Tried again on the next launch, and covered by Apple's own
            // server notifications in the meantime.
        }
    }

    // MARK: - Internals

    /// Wraps the shared shape of every user-initiated request: one at a time,
    /// the previous complaint cleared, and a thrown error turned into something
    /// to read.
    @MainActor
    private func run(_ work: @escaping () async throws -> Void) async {
        guard !isWorking else { return }

        isWorking = true
        problem = nil
        notice = nil

        do {
            try await work()
        } catch let failure as SupabaseAuth.Failure {
            problem = failure.message
        } catch {
            problem = error.localizedDescription
        }

        isWorking = false
    }

    @MainActor
    private func adopt(
        _ session: SupabaseAuth.Session,
        appleName: String? = nil
    ) async throws {
        accessToken = session.accessToken
        accessTokenExpiry = session.expiry
        SessionKeychain.save(session.refreshToken)

        let email = session.user.email ?? rememberedEmail
        UserDefaults.standard.set(email, forKey: Self.emailKey)

        account = Account(
            id: session.user.id,
            email: email,
            isPro: false,
            proSource: nil,
            proUntil: nil,
            proCancelsAtPeriodEnd: false,
            displayName: appleName ?? session.user.fullName,
            joined: session.user.createdAt
        )

        // Apple hands over a name on the first authorisation and never again,
        // so it is written onto the account the moment it arrives or it is
        // gone for good.
        if let appleName = appleName, session.user.fullName == nil {
            await SupabaseAuth.updateFullName(appleName, accessToken: session.accessToken)
        }

        // A handle set on another device, or on the website. Only taken when
        // this device has none of its own — see `adoptFromAccount`.
        PilotIdentity.shared.adoptFromAccount(session.user.pilotName)

        // The entitlement is a separate request, and a slow or failed one
        // shouldn't hold up being signed in — the account lands first, Pro
        // follows.
        apply(try? await SupabaseAuth.entitlement(accessToken: session.accessToken))

        // Anything this Apple Account already owns now has an account to
        // belong to. This is what makes "bought it on the phone, want it on
        // the website" work for somebody who bought before they signed in.
        await ProStore.shared.refreshEntitlement()

        // The public profile follows the account. Not awaited: somebody who has
        // never claimed a handle has no profile to wait for, and somebody who
        // has does not need it before the map appears.
        ProfileStore.shared.accountChanged()
        PilotDirectory.shared.accountChanged()

        // And the device now has an account for the server to reach it by, for
        // the one notification that is about this pilot's own flight rather
        // than about somebody they are watching.
        PushService.shared.syncAccountRegistration()
    }

    @MainActor
    private func apply(_ entitlement: SupabaseAuth.Entitlement?) {
        guard var updated = account else { return }
        updated.isPro = entitlement?.isPro ?? false
        updated.proSource = entitlement?.source
        updated.proUntil = entitlement?.until
        updated.proCancelsAtPeriodEnd = entitlement?.cancelAtPeriodEnd ?? false

        guard updated != account else { return }
        account = updated
        Entitlements.shared.accountChanged()
    }

    /// An access token that is good for the next minute, refreshing first if it
    /// isn't. GoTrue's are short-lived, and the app can sit open for hours.
    /// A token for another store to spend, or nil when nobody is signed in.
    ///
    /// Deliberately the only way out of this class for a credential, and
    /// deliberately not `@Published`: a view has no business holding one, and
    /// the stores that do — the profile, the directory, the logbook — ask for
    /// it per request rather than keeping a copy that can go stale. Nil rather
    /// than throwing, because "signed out" is an ordinary state for every one
    /// of those callers: reading a public profile does not need an account.
    @MainActor
    func currentAccessToken() async -> String? {
        guard account != nil else { return nil }
        return try? await validAccessToken()
    }

    @MainActor
    private func validAccessToken() async throws -> String {
        if let token = accessToken,
           let expiry = accessTokenExpiry,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }

        guard let stored = SessionKeychain.read() else {
            throw SupabaseAuth.Failure(message: "Signed out.")
        }

        let session = try await SupabaseAuth.refresh(refreshToken: stored)
        accessToken = session.accessToken
        accessTokenExpiry = session.expiry
        SessionKeychain.save(session.refreshToken)
        return session.accessToken
    }

    private static func clean(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
