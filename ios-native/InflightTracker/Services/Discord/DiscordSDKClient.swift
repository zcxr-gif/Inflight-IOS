import Foundation

#if canImport(discord_partner_sdk)
import discord_partner_sdk
#endif

/// What goes on somebody's Discord profile while the app is open.
///
/// Plain values, so the presence layer can compare what it would send with
/// what it last sent and stay quiet when nothing has changed — Discord rate
/// limits presence updates, and a packet every few seconds is far more often
/// than anything on the card actually moves.
struct DiscordActivity: Equatable {

    struct Button: Equatable {
        let label: String
        let url: URL
    }

    /// The first line under the app's name. "Flying BAW117 · A350".
    var details: String

    /// The second. "EGLL → KJFK · FL350".
    var state: String?

    /// Art asset keys, as uploaded under Rich Presence → Art Assets in the
    /// Discord developer portal — see DISCORD.md.
    var largeImage: String?
    var largeText: String?
    var smallImage: String?
    var smallText: String?

    /// Discord draws "elapsed" from a start and counts down to an end.
    var start: Date?
    var end: Date?

    /// At most two; Discord ignores the rest.
    var buttons: [Button] = []
}

/// The tokens one linked Discord account hands back.
struct DiscordTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    /// Refreshed with a margin rather than at the last second, so a launch an
    /// hour before expiry does not connect with a token that dies mid-session.
    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 24 * 60 * 60 }
}

/// A thin, main-thread wrapper over the Discord Social SDK's C interface.
///
/// The SDK is a binary Discord distributes from its developer portal and does
/// not allow to be fetched by a package manager, so it is not in the repository
/// until somebody drops it in — see DISCORD.md. Until then this compiles to a
/// stub that reports itself unavailable, and the settings row that would offer
/// it is never built.
///
/// ## Threading
///
/// Everything here, the SDK calls and the callbacks alike, happens on the main
/// thread. The SDK delivers callbacks from inside `Discord_RunCallbacks`, on
/// whichever thread calls it; pumping it from a main-thread timer is what makes
/// that the main thread, and keeps the SDK — which is not documented as safe to
/// drive from two threads at once — on exactly one.
final class DiscordSDKClient {

    enum Status: Equatable {
        case disconnected
        case connecting
        case ready
        case failed(String)
    }

    /// Whether the SDK was compiled into this build at all.
    static var isCompiledIn: Bool {
        #if canImport(discord_partner_sdk)
        return true
        #else
        return false
        #endif
    }

    var onStatus: ((Status) -> Void)?

    #if canImport(discord_partner_sdk)

    private let applicationId: UInt64
    private var client = Discord_Client()
    private var pump: Timer?

    init?(applicationId: UInt64) {
        guard applicationId != 0 else { return nil }
        self.applicationId = applicationId

        Discord_Client_Init(&client)
        Discord_Client_SetApplicationId(&client, applicationId)

        let box = Box<(Status) -> Void> { [weak self] status in self?.onStatus?(status) }
        Discord_Client_SetStatusChangedCallback(&client, { status, error, _, userData in
            guard let callback = Box<(Status) -> Void>.peek(userData) else { return }
            if status == Discord_Client_Status_Ready {
                callback(.ready)
            } else if status == Discord_Client_Status_Disconnected {
                callback(error == Discord_Client_Error_None ? .disconnected : .failed("Lost the connection to Discord"))
            } else {
                callback(.connecting)
            }
        }, Box<(Status) -> Void>.release, box.retained())

        // Ten times a second is what the SDK's own samples run it at, and an
        // idle pump is a C call that returns at once. iOS stops the timer with
        // the rest of the app when it goes to the background.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in Discord_RunCallbacks() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    deinit {
        pump?.invalidate()
        Discord_Client_Drop(&client)
    }

    // MARK: Linking

    /// Sends the person to Discord to approve the link, then swaps the code it
    /// returns for tokens. PKCE, so no client secret is anywhere in the app.
    func authorize(completion: @escaping (Result<DiscordTokens, Error>) -> Void) {
        var verifier = Discord_AuthorizationCodeVerifier()
        Discord_Client_CreateAuthorizationCodeVerifier(&client, &verifier)

        var verifierText = Discord_String()
        Discord_AuthorizationCodeVerifier_Verifier(&verifier, &verifierText)
        let codeVerifier = Self.take(verifierText)

        var args = Discord_AuthorizationArgs()
        Discord_AuthorizationArgs_Init(&args)
        Discord_AuthorizationArgs_SetClientId(&args, applicationId)

        var scopes = Discord_String()
        Discord_Client_GetDefaultPresenceScopes(&scopes)
        Discord_AuthorizationArgs_SetScopes(&args, scopes)
        Discord_Free(scopes.ptr)

        var challenge = Discord_AuthorizationCodeChallenge()
        Discord_AuthorizationCodeVerifier_Challenge(&verifier, &challenge)
        Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)
        Discord_AuthorizationCodeChallenge_Drop(&challenge)
        Discord_AuthorizationCodeVerifier_Drop(&verifier)

        typealias Authorized = (Result<(code: String, redirect: String), Error>) -> Void
        let box = Box<Authorized> { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let grant):
                self?.exchange(code: grant.code, verifier: codeVerifier, redirect: grant.redirect, completion: completion)
            }
        }

        Discord_Client_Authorize(&client, &args, { result, code, redirect, userData in
            let codeText = DiscordSDKClient.take(code)
            let redirectText = DiscordSDKClient.take(redirect)
            let failure = DiscordSDKClient.failure(of: result)
            guard let callback = Box<Authorized>.peek(userData) else { return }
            if let failure {
                callback(.failure(failure))
            } else {
                callback(.success((code: codeText, redirect: redirectText)))
            }
        }, Box<Authorized>.release, box.retained())

        Discord_AuthorizationArgs_Drop(&args)
    }

    private func exchange(
        code: String,
        verifier: String,
        redirect: String,
        completion: @escaping (Result<DiscordTokens, Error>) -> Void
    ) {
        let box = Box<(Result<DiscordTokens, Error>) -> Void>(completion)
        Self.withString(code) { code in
            Self.withString(verifier) { verifier in
                Self.withString(redirect) { redirect in
                    Discord_Client_GetToken(
                        &client, applicationId, code, verifier, redirect,
                        Self.tokenCallback, Box<(Result<DiscordTokens, Error>) -> Void>.release, box.retained()
                    )
                }
            }
        }
    }

    func refresh(_ refreshToken: String, completion: @escaping (Result<DiscordTokens, Error>) -> Void) {
        let box = Box<(Result<DiscordTokens, Error>) -> Void>(completion)
        Self.withString(refreshToken) { token in
            Discord_Client_RefreshToken(
                &client, applicationId, token,
                Self.tokenCallback, Box<(Result<DiscordTokens, Error>) -> Void>.release, box.retained()
            )
        }
    }

    private static let tokenCallback: Discord_Client_TokenExchangeCallback = {
        result, access, refresh, _, expiresIn, scopes, userData in
        let accessText = DiscordSDKClient.take(access)
        let refreshText = DiscordSDKClient.take(refresh)
        _ = DiscordSDKClient.take(scopes)
        let failure = DiscordSDKClient.failure(of: result)
        guard let callback = Box<(Result<DiscordTokens, Error>) -> Void>.peek(userData) else { return }
        if let failure {
            callback(.failure(failure))
        } else {
            callback(.success(DiscordTokens(
                accessToken: accessText,
                refreshToken: refreshText,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
            )))
        }
    }

    // MARK: Connection

    func connect(accessToken: String) {
        onStatus?(.connecting)
        let box = Box<(Error?) -> Void> { [weak self] error in
            guard let self else { return }
            if let error {
                self.onStatus?(.failed(error.localizedDescription))
            } else {
                Discord_Client_Connect(&self.client)
            }
        }
        Self.withString(accessToken) { token in
            Discord_Client_UpdateToken(&client, Discord_AuthorizationTokenType_Bearer, token, { result, userData in
                let failure = DiscordSDKClient.failure(of: result)
                Box<(Error?) -> Void>.peek(userData)?(failure)
            }, Box<(Error?) -> Void>.release, box.retained())
        }
    }

    func disconnect() {
        Discord_Client_Disconnect(&client)
    }

    // MARK: Presence

    func update(_ activity: DiscordActivity, completion: @escaping (Error?) -> Void) {
        var native = Discord_Activity()
        Discord_Activity_Init(&native)
        defer { Discord_Activity_Drop(&native) }

        Discord_Activity_SetType(&native, Discord_ActivityTypes_Playing)

        // Every setter copies what it is given, so the buffers only have to
        // outlive the call — the same contract the SDK's own C++ layer relies
        // on when it passes a temporary.
        Self.withOptionalString(activity.details) { Discord_Activity_SetDetails(&native, $0) }
        Self.withOptionalString(activity.state) { Discord_Activity_SetState(&native, $0) }

        var assets = Discord_ActivityAssets()
        Discord_ActivityAssets_Init(&assets)
        Self.withOptionalString(activity.largeImage) { Discord_ActivityAssets_SetLargeImage(&assets, $0) }
        Self.withOptionalString(activity.largeText) { Discord_ActivityAssets_SetLargeText(&assets, $0) }
        Self.withOptionalString(activity.smallImage) { Discord_ActivityAssets_SetSmallImage(&assets, $0) }
        Self.withOptionalString(activity.smallText) { Discord_ActivityAssets_SetSmallText(&assets, $0) }
        Discord_Activity_SetAssets(&native, &assets)
        Discord_ActivityAssets_Drop(&assets)

        if activity.start != nil || activity.end != nil {
            var timestamps = Discord_ActivityTimestamps()
            Discord_ActivityTimestamps_Init(&timestamps)
            if let start = activity.start {
                Discord_ActivityTimestamps_SetStart(&timestamps, Self.milliseconds(start))
            }
            if let end = activity.end {
                Discord_ActivityTimestamps_SetEnd(&timestamps, Self.milliseconds(end))
            }
            Discord_Activity_SetTimestamps(&native, &timestamps)
            Discord_ActivityTimestamps_Drop(&timestamps)
        }

        for button in activity.buttons.prefix(2) {
            var nativeButton = Discord_ActivityButton()
            Discord_ActivityButton_Init(&nativeButton)
            Self.withString(button.label) { Discord_ActivityButton_SetLabel(&nativeButton, $0) }
            Self.withString(button.url.absoluteString) { Discord_ActivityButton_SetUrl(&nativeButton, $0) }
            Discord_Activity_AddButton(&native, &nativeButton)
            Discord_ActivityButton_Drop(&nativeButton)
        }

        let box = Box<(Error?) -> Void>(completion)
        Discord_Client_UpdateRichPresence(&client, &native, { result, userData in
            let failure = DiscordSDKClient.failure(of: result)
            Box<(Error?) -> Void>.peek(userData)?(failure)
        }, Box<(Error?) -> Void>.release, box.retained())
    }

    func clear() {
        Discord_Client_ClearRichPresence(&client)
    }

    // MARK: C plumbing

    /// A Swift closure carried through the SDK's `void* userData`. Retained
    /// when handed over and released by the SDK through the free function it
    /// is given alongside, which it calls once it is done with the callback.
    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }

        func retained() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }

        static func peek(_ pointer: UnsafeMutableRawPointer?) -> Value? {
            guard let pointer else { return nil }
            return Unmanaged<Box<Value>>.fromOpaque(pointer).takeUnretainedValue().value
        }

        static var release: Discord_FreeFn {
            { pointer in
                guard let pointer else { return }
                Unmanaged<AnyObject>.fromOpaque(pointer).release()
            }
        }
    }

    /// A string the SDK allocated and hands over, read and freed.
    private static func take(_ text: Discord_String) -> String {
        guard let pointer = text.ptr else { return "" }
        let value = String(decoding: UnsafeBufferPointer(start: pointer, count: text.size), as: UTF8.self)
        Discord_Free(pointer)
        return value
    }

    /// Nil on success. The result is the callback's to drop, per the SDK.
    private static func failure(of result: UnsafeMutablePointer<Discord_ClientResult>?) -> Error? {
        guard let result else { return DiscordSDKError(message: "No result from Discord") }
        defer { Discord_ClientResult_Drop(result) }
        guard !Discord_ClientResult_Successful(result) else { return nil }
        var text = Discord_String()
        Discord_ClientResult_Error(result, &text)
        let message = take(text)
        return DiscordSDKError(message: message.isEmpty ? "Discord refused the request" : message)
    }

    private static func withString<Result>(_ text: String, _ body: (Discord_String) -> Result) -> Result {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            body(Discord_String(ptr: buffer.baseAddress, size: buffer.count))
        }
    }

    private static func withOptionalString(_ text: String?, _ body: (UnsafeMutablePointer<Discord_String>?) -> Void) {
        guard let text, !text.isEmpty else { return }
        withString(text) { value in
            var value = value
            body(&value)
        }
    }

    private static func milliseconds(_ date: Date) -> UInt64 {
        UInt64(max(date.timeIntervalSince1970, 0) * 1000)
    }

    #else

    init?(applicationId: UInt64) { return nil }

    func authorize(completion: @escaping (Result<DiscordTokens, Error>) -> Void) {
        completion(.failure(DiscordSDKError(message: "Discord isn't built into this version")))
    }

    func refresh(_ refreshToken: String, completion: @escaping (Result<DiscordTokens, Error>) -> Void) {
        completion(.failure(DiscordSDKError(message: "Discord isn't built into this version")))
    }

    func connect(accessToken: String) {}
    func disconnect() {}
    func update(_ activity: DiscordActivity, completion: @escaping (Error?) -> Void) { completion(nil) }
    func clear() {}

    #endif
}

struct DiscordSDKError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
