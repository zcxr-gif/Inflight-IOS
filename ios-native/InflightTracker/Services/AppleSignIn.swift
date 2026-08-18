import AuthenticationServices
import CryptoKit
import Foundation

/// The two things Sign in with Apple needs that Apple's own button does not
/// provide: a nonce, and something to do with what comes back.
///
/// The flow is short and entirely prescribed. Make a single-use random string,
/// hand Apple its SHA-256, and get back an identity token with that hash
/// inside it. Supabase is then given the token and the *raw* nonce, and checks
/// the two agree — which is what stops an identity token captured somewhere
/// else being replayed at our sign-in. Skip the nonce and that check cannot
/// happen, which is why it is generated here rather than left to the button.
enum AppleSignIn {

    /// What Apple gives back, reduced to what Supabase needs and the one thing
    /// only this moment can supply.
    struct Credential {
        let identityToken: String

        /// Apple sends a name on the *first* authorisation for an app and
        /// never again. Nil on every later sign-in, which is not an error — it
        /// means the account already has whatever name it is going to get.
        let fullName: String?
    }

    enum Failure: LocalizedError {
        case cancelled
        case noIdentityToken
        case noNonce

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .noIdentityToken: return "Apple didn't return a usable sign-in token."
            case .noNonce: return "That sign-in expired before it finished. Try again."
            }
        }
    }

    /// A single-use random string, in the character set Apple documents.
    ///
    /// `SecRandomCopyBytes` rather than anything seeded: this value's entire
    /// job is to be unguessable by whoever might want to replay a token.
    static func nonce(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)

        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The system CSPRNG failing is not a case to paper over with
            // something weaker, but it is also not a reason to break a sign-in
            // button: `SystemRandomNumberGenerator` is itself cryptographically
            // secure on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }

        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    /// What goes on the request: the hash, never the nonce itself.
    static func hashed(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Pulls the identity token and the once-only name out of what the button
    /// handed back.
    static func credential(
        from result: Result<ASAuthorization, Error>
    ) throws -> Credential {
        switch result {
        case .failure(let error):
            // Tapping Cancel is not a failure to report. It is the user saying
            // no, and an alert about it is the app arguing with them.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                throw Failure.cancelled
            }
            throw error

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                throw Failure.noIdentityToken
            }

            let name = credential.fullName.flatMap { components -> String? in
                let formatted = PersonNameComponentsFormatter.localizedString(
                    from: components,
                    style: .default
                )
                return formatted.isEmpty ? nil : formatted
            }

            return Credential(identityToken: token, fullName: name)
        }
    }
}
