import Foundation

/// PostgREST, for everything that is not sign-in.
///
/// `SupabaseAuth` owns GoTrue and the four requests the session is built from;
/// this owns the rest of the project — the profile functions, the logbook, the
/// follow graph. Split because they have different rules about who may call
/// them: almost everything here is readable signed out, and a profile served to
/// a stranger's browser has to be.
///
/// Hand-rolled for the same reason the auth half is. What the app needs is a
/// POST with a bearer token and a JSON array back; `supabase-swift` would bring
/// a dependency graph to a CI build that currently resolves exactly one, for
/// three functions.
///
/// ## Two kinds of caller, one shape
///
/// Every request carries a token: the signed-in pilot's, or the project's
/// publishable `anon` key when nobody is signed in. That is not a fallback that
/// weakens anything — the anon key grants exactly what row-level security
/// allows an unauthenticated caller, which for these functions is "the public
/// profiles, as a stranger sees them". Passing it explicitly is what lets the
/// same call site work signed in and signed out, and it is why reading a
/// profile does not require an account.
enum SupabaseData {

    struct Failure: LocalizedError {

        let message: String

        /// Set when the server refused because the account is free. The caller
        /// shows a paywall rather than an error, and this is how it knows to.
        var needsPro: Bool = false

        var errorDescription: String? { message }

        /// PostgREST's own words where it had any. Its messages come from the
        /// database — including the ones raised by the write guard on
        /// `pilot_profiles`, which are written to be read by a person, so they
        /// are better than anything this layer would invent from a status code.
        static func from(data: Data, status: Int) -> Failure {
            struct Body: Decodable {
                let message: String?
                let hint: String?
                let details: String?
                let error: String?
                let code: String?
            }

            let body = try? JSONDecoder().decode(Body.self, from: data)
            let text = body?.message ?? body?.error ?? body?.details

            // 42501 is `insufficient_privilege`, which is the errcode the Pro
            // gate raises with. Recognising it here is what turns "the server
            // said no" into a paywall.
            let pro = body?.code == "42501" || status == 402

            if let text = text, !text.isEmpty {
                return Failure(message: text, needsPro: pro)
            }
            return Failure(message: "The server refused that (HTTP \(status)).", needsPro: pro)
        }
    }

    // MARK: - Calls

    /// A `security definer` function that returns rows.
    static func rpc<T: Decodable>(
        _ function: String,
        arguments: [String: Any] = [:],
        accessToken: String? = nil
    ) async throws -> [T] {
        guard let url = AppConfig.rpcURL(function) else {
            throw Failure(message: "Bad request URL.")
        }
        let data = try await send(
            url: url,
            method: "POST",
            body: arguments,
            accessToken: accessToken
        )

        // An empty body is a function that returned no rows, which every
        // visibility rule in this schema expresses by returning nothing.
        guard !data.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            // A `returns table` function with one row still answers with an
            // array; a scalar one answers with the bare value. Both happen.
            if let single = try? JSONDecoder().decode(T.self, from: data) { return [single] }
            throw Failure(message: "The server sent something this app couldn't read.")
        }
    }

    /// A function called for its effect rather than its answer.
    @discardableResult
    static func perform(
        _ function: String,
        arguments: [String: Any] = [:],
        accessToken: String?
    ) async throws -> Data {
        guard let url = AppConfig.rpcURL(function) else {
            throw Failure(message: "Bad request URL.")
        }
        return try await send(url: url, method: "POST", body: arguments, accessToken: accessToken)
    }

    /// Writes a row the caller owns.
    ///
    /// `resolution=merge-duplicates` so claiming a handle and editing a profile
    /// are the same request: there is one row per account, and the difference
    /// between making it and changing it is not one the client should have to
    /// know about — particularly since it would have to find out by reading
    /// first, which is a round trip and a race.
    @discardableResult
    static func upsert(
        table: String,
        row: [String: Any],
        accessToken: String,
        onConflict: String
    ) async throws -> Data {
        guard var components = URLComponents(
            url: AppConfig.tableURL(table) ?? URL(fileURLWithPath: "/"),
            resolvingAgainstBaseURL: false
        ) else { throw Failure(message: "Bad request URL.") }

        components.queryItems = [URLQueryItem(name: "on_conflict", value: onConflict)]
        guard let url = components.url else { throw Failure(message: "Bad request URL.") }

        return try await send(
            url: url,
            method: "POST",
            body: row,
            accessToken: accessToken,
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=representation"]
        )
    }

    /// Inserts a row, quietly ignoring one that is already there.
    ///
    /// Used by the logbook, where the same completed flight can be offered more
    /// than once — a retry, a second device watching the same pilot — and the
    /// unique index is the thing that makes that harmless.
    @discardableResult
    static func insertIgnoringDuplicates(
        table: String,
        row: [String: Any],
        accessToken: String
    ) async throws -> Data {
        guard let url = AppConfig.tableURL(table) else {
            throw Failure(message: "Bad request URL.")
        }
        return try await send(
            url: url,
            method: "POST",
            body: row,
            accessToken: accessToken,
            extraHeaders: ["Prefer": "resolution=ignore-duplicates,return=minimal"]
        )
    }

    // MARK: - Plumbing

    private static func send(
        url: URL,
        method: String,
        body: [String: Any],
        accessToken: String?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(accessToken ?? AppConfig.supabaseAnonKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.from(data: data, status: status)
        }
        return data
    }
}
