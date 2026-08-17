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

        /// What the *cloud* thinks. An App Store purchase is not written back
        /// here — see `Entitlements` — so this is only ever the web
        /// subscription or the grandfathered flag.
        var isPro: Bool
        var isLegacyPro: Bool

        let joined: Date?

        var grantsPro: Bool { isPro || isLegacyPro }

        /// What to draw in the avatar when there is no picture to draw. The
        /// profile has no display name yet, so the local part of the email is
        /// the closest thing to one.
        var handle: String {
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return local.isEmpty ? email : local
        }

        var initials: String {
            let letters = handle.filter { $0.isLetter || $0.isNumber }
            return String(letters.prefix(2)).uppercased()
        }
    }

    private static let emailKey = "account.lastEmail"

    /// Held rather than published: it is a credential, and no view needs it.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

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
            await SupabaseAuth.signOut(accessToken: token)
        }

        SessionKeychain.clear()
        accessToken = nil
        accessTokenExpiry = nil
        account = nil
        problem = nil
        notice = nil
        Entitlements.shared.accountChanged()
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

    // MARK: - Profile

    /// Re-reads `profiles` for the signed-in account.
    ///
    /// Called after a purchase and whenever the account panel opens, because
    /// the row can change without this device doing anything — a web
    /// subscription renewing or lapsing is the whole point of reading it at
    /// all.
    @MainActor
    func refreshProfile() async {
        guard let account = account else { return }

        do {
            let token = try await validAccessToken()
            let profile = try await SupabaseAuth.profile(userId: account.id, accessToken: token)
            apply(profile)
        } catch {
            // Leaves whatever the last known answer was. An entitlement is not
            // something to revoke because a request timed out.
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
    private func adopt(_ session: SupabaseAuth.Session) async throws {
        accessToken = session.accessToken
        accessTokenExpiry = session.expiry
        SessionKeychain.save(session.refreshToken)

        let email = session.user.email ?? rememberedEmail
        UserDefaults.standard.set(email, forKey: Self.emailKey)

        account = Account(
            id: session.user.id,
            email: email,
            isPro: false,
            isLegacyPro: false,
            joined: session.user.createdAt
        )

        // A handle set on another device, or on the website. Only taken when
        // this device has none of its own — see `adoptFromAccount`.
        PilotIdentity.shared.adoptFromAccount(session.user.pilotName)

        // The row is a separate request, and a slow or failed one shouldn't
        // hold up being signed in — the account lands first, Pro follows.
        let profile = try? await SupabaseAuth.profile(
            userId: session.user.id,
            accessToken: session.accessToken
        )
        apply(profile)
    }

    @MainActor
    private func apply(_ profile: SupabaseAuth.Profile?) {
        guard var updated = account else { return }
        updated.isPro = profile?.isPro ?? false
        updated.isLegacyPro = profile?.legacyPro ?? false

        guard updated != account else { return }
        account = updated
        Entitlements.shared.accountChanged()
    }

    /// An access token that is good for the next minute, refreshing first if it
    /// isn't. GoTrue's are short-lived, and the app can sit open for hours.
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
