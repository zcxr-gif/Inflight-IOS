import Foundation
import Security

/// The tracker's half of Supabase: GoTrue for sign-in, PostgREST for the one
/// row we read back.
///
/// The Capacitor build did all of this through `@supabase/supabase-js` against
/// the same project (`old/www/flight.js` — `supabaseUrl`, and `authUI.js` for
/// the flow). The accounts, the passwords and the `profiles` table are all
/// still there, so signing in here signs you into the same account you have on
/// the web; what has been left behind is the look, and the web-only parts of
/// the old flow — Stripe and PayPal are not in this file, because on iOS the
/// only lawful way to sell Pro is StoreKit (`ProStore`).
///
/// Hand-rolled rather than the `supabase-swift` package on purpose. What the
/// app needs is four requests and one row; the package would add a dependency
/// graph to a CI build that currently resolves exactly one, and none of its
/// realtime, storage or edge-function surface is used.
enum SupabaseAuth {

    // MARK: - Errors

    struct Failure: LocalizedError {

        let message: String

        var errorDescription: String? { message }

        /// GoTrue's own wording, when it sent any. Its messages are written for
        /// people ("Invalid login credentials"), so they are better than
        /// anything this layer would invent from a status code.
        static func from(data: Data, status: Int) -> Failure {
            struct Body: Decodable {
                let msg: String?
                let message: String?
                let error_description: String?
                let error: String?
            }

            if let body = try? JSONDecoder().decode(Body.self, from: data),
               let text = body.msg ?? body.message ?? body.error_description ?? body.error,
               !text.isEmpty {
                return Failure(message: text)
            }

            return Failure(message: "The server refused that (HTTP \(status)).")
        }
    }

    // MARK: - Wire types

    /// What GoTrue hands back from a sign-in, a sign-up that needs no
    /// confirmation, and a refresh.
    struct Session: Decodable {

        let accessToken: String
        let refreshToken: String
        let expiresIn: Double?
        let user: User

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
        }

        var expiry: Date { Date().addingTimeInterval(expiresIn ?? 3600) }
    }

    struct User: Decodable {

        let id: String
        let email: String?
        let createdAt: Date?

        /// The Infinite Flight community handle, from
        /// `user_metadata.if_username` — the same key the Capacitor build wrote
        /// (`old/www/flight.js`, `myIfName`), so the two builds share it.
        let pilotName: String?

        /// What to call them. Only ever set by Sign in with Apple, which is
        /// the one flow that offers a name at all.
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case email
            case createdAt = "created_at"
            case userMetadata = "user_metadata"
        }

        private struct Metadata: Decodable {
            let ifUsername: String?
            let fullName: String?

            enum CodingKeys: String, CodingKey {
                case ifUsername = "if_username"
                case fullName = "full_name"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            createdAt = (try? container.decode(String.self, forKey: .createdAt))
                .flatMap(Self.date(from:))

            let metadata = try? container.decode(Metadata.self, forKey: .userMetadata)
            pilotName = (metadata?.ifUsername).flatMap { $0.isEmpty ? nil : $0 }
            fullName = (metadata?.fullName).flatMap { $0.isEmpty ? nil : $0 }
        }

        private static func date(from text: String) -> Date? { Timestamp.date(from: text) }
    }

    /// Postgres timestamps come back with a variable number of fractional
    /// digits, which `.iso8601` alone rejects. Shared, because every date this
    /// file decodes arrives in that shape.
    enum Timestamp {

        static func date(from text: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }
    }

    /// A sign-up either opens a session or asks for an email to be confirmed
    /// first, depending on how the project is configured. Both are successes
    /// and they need completely different things said about them, so the caller
    /// is told which happened rather than being handed an optional session to
    /// interpret.
    enum SignUpOutcome {
        case signedIn(Session)
        case needsConfirmation(email: String)
    }

    /// What the server says this account is entitled to.
    ///
    /// One `pro_entitlement()` call rather than a read of `profiles`, because
    /// the answer depends on four things — an App Store row, a Stripe row, and
    /// two flags — and the rules for combining them belong in one place that
    /// the website reads too. Resolving it in the client would mean four reads
    /// and a second copy of the rules to keep in step.
    struct Entitlement: Decodable {

        let isPro: Bool

        /// Which of the possible grants answered. 'app-store',
        /// 'app-store-lifetime', 'subscription', 'grace', 'legacy', 'profile',
        /// 'expired', 'free' or 'signed-out'.
        let source: String

        /// When the paid period runs out, for the plans that have one.
        let until: Date?

        /// Set when the plan is paid up but will not renew.
        let cancelAtPeriodEnd: Bool

        enum CodingKeys: String, CodingKey {
            case isPro = "is_pro"
            case source
            case until
            case cancelAtPeriodEnd = "cancel_at_period_end"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isPro = (try? container.decode(Bool.self, forKey: .isPro)) ?? false
            source = (try? container.decode(String.self, forKey: .source)) ?? "free"
            until = (try? container.decode(String.self, forKey: .until))
                .flatMap(Timestamp.date(from:))
            cancelAtPeriodEnd =
                (try? container.decode(Bool.self, forKey: .cancelAtPeriodEnd)) ?? false
        }
    }

    // MARK: - Requests

    static func signIn(email: String, password: String) async throws -> Session {
        try await post(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": email, "password": password]
        )
    }

    /// Signs in with the identity token Apple just handed us.
    ///
    /// GoTrue's `id_token` grant, which is the native flow: no browser, no
    /// redirect URL, no web view — the app asks Apple, Apple signs a token,
    /// and Supabase verifies that signature against Apple's public keys. The
    /// account it resolves to is keyed on the Apple identity, so the same
    /// Apple ID lands on the same account every time.
    ///
    /// The nonce is the raw one. Apple was given its SHA-256 and put that hash
    /// in the token; Supabase hashes this and checks the two match, which is
    /// what stops a token captured somewhere else being replayed here.
    static func signInWithApple(idToken: String, nonce: String) async throws -> Session {
        try await post(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: ["provider": "apple", "id_token": idToken, "nonce": nonce]
        )
    }

    /// Writes the name Apple gave us onto a brand-new account.
    ///
    /// Apple sends a name exactly once — on the very first authorisation, and
    /// never again — so it is stored the moment it arrives or it is lost. Best
    /// effort: a display name is not worth failing a sign-in over.
    static func updateFullName(_ name: String, accessToken: String) async {
        try? await updateUser(["data": ["full_name": name]], accessToken: accessToken)
    }

    static func signUp(email: String, password: String) async throws -> SignUpOutcome {
        let data = try await postData(
            path: "/auth/v1/signup",
            body: ["email": email, "password": password]
        )

        // A project with email confirmation on answers with the user and no
        // tokens; one with it off answers with a full session.
        if let session = try? decoder.decode(Session.self, from: data) {
            return .signedIn(session)
        }
        return .needsConfirmation(email: email)
    }

    static func refresh(refreshToken: String) async throws -> Session {
        try await post(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": refreshToken]
        )
    }

    static func sendPasswordReset(email: String) async throws {
        _ = try await postData(path: "/auth/v1/recover", body: ["email": email])
    }

    /// Best-effort: the local session is dropped whatever this says, so a
    /// failure here is not something to put in front of the user.
    static func signOut(accessToken: String) async {
        _ = try? await postData(path: "/auth/v1/logout", body: [:], accessToken: accessToken)
    }

    /// Writes the Infinite Flight handle onto the signed-in user.
    ///
    /// `user_metadata` is the user's own to write — GoTrue scopes the update to
    /// whoever the token belongs to — which is exactly why the handle lives
    /// there and the Pro flag does not.
    static func updatePilotName(_ name: String, accessToken: String) async throws {
        try await updateUser(["data": ["if_username": name]], accessToken: accessToken)
    }

    /// PUTs onto `/auth/v1/user`, which GoTrue scopes to whoever the token
    /// belongs to. That scoping is exactly why the handle and the display name
    /// live in `user_metadata` and the Pro flag does not.
    private static func updateUser(
        _ body: [String: Any],
        accessToken: String
    ) async throws {
        guard let url = URL(string: AppConfig.supabaseURLString + "/auth/v1/user") else {
            throw Failure(message: "Bad user URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }
    }

    /// Erases the account this token belongs to.
    ///
    /// The id is never sent: the Edge Function resolves it from the token, so
    /// this call can only ever delete its own caller. See
    /// `supabase/functions/delete-account/`.
    static func deleteAccount(accessToken: String) async throws {
        guard let url = AppConfig.accountDeletionURL else {
            throw Failure(message: "Account deletion isn't configured.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 404 is the one worth translating: it means the function has not been
        // deployed to the project yet, which is a deployment problem rather
        // than anything the user did or can fix by trying again.
        if status == 404 {
            throw Failure(message: "Account deletion isn't available on the server yet.")
        }

        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }
    }

    /// What this account is entitled to, as the server sees it.
    static func entitlement(accessToken: String) async throws -> Entitlement? {
        guard let url = AppConfig.proEntitlementRPCURL else {
            throw Failure(message: "Bad entitlement URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }

        // The function returns a table, so PostgREST answers with an array of
        // one row.
        return try decoder.decode([Entitlement].self, from: data).first
    }

    /// Hands the server the signed transactions StoreKit gave us, so the
    /// purchase belongs to the account and not just to the phone.
    ///
    /// The JWS is what makes this safe to accept: the Edge Function verifies
    /// Apple's signature over each one before it writes anything, so the worst
    /// a tampered body can achieve is being rejected.
    static func linkAppStoreTransactions(
        _ signedTransactions: [String],
        accessToken: String
    ) async throws {
        guard !signedTransactions.isEmpty else { return }
        guard let url = AppConfig.appleSubscriptionSyncURL else {
            throw Failure(message: "Purchase syncing isn't configured.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["transactions": signedTransactions]
        )
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }
    }

    // MARK: - Plumbing

    private static let decoder = JSONDecoder()

    @discardableResult
    private static func postData(
        path: String,
        query: [URLQueryItem] = [],
        body: [String: String],
        accessToken: String? = nil
    ) async throws -> Data {
        var components = URLComponents(string: AppConfig.supabaseURLString + path)
        if !query.isEmpty { components?.queryItems = query }

        guard let url = components?.url else { throw Failure(message: "Bad request URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(accessToken ?? AppConfig.supabaseAnonKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }
        return data
    }

    private static func post<T: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        body: [String: String]
    ) async throws -> T {
        let data = try await postData(path: path, query: query, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw Failure(message: "The server sent something this app couldn't read.")
        }
    }
}

/// Where the refresh token lives.
///
/// The Keychain rather than `UserDefaults`: a refresh token is a credential —
/// it mints access tokens for the account until it is revoked — and defaults
/// are readable from a backup. `ThisDeviceOnly` so it doesn't travel to a new
/// phone in an iCloud restore; the worst case there is one sign-in.
enum SessionKeychain {

    private static let service = "com.tracker.Inflight.supabase"
    private static let account = "refreshToken"

    static func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
