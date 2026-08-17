import Combine
import Foundation

/// Who *you* are on the server.
///
/// The feed names every aircraft's pilot but has no idea which one is yours,
/// so the app has to be told. The Capacitor build asked the same question and
/// kept the answer in the Supabase user's `user_metadata.if_username` (see
/// `old/www/flight.js`, `myIfName`) — this is the same field, so a username set
/// on the website is already set here and vice versa.
///
/// It is also kept on the device, which is the important difference: the
/// tracker works signed out, and "show me my own aircraft" is far too useful to
/// be something you need an account for. The account only makes it follow you.
final class PilotIdentity: ObservableObject {

    static let shared = PilotIdentity()

    private static let key = "pilot.ifcUsername"

    /// The display name as the user typed it. Matching is done on the
    /// lowercased form; this is what gets shown back to them.
    @Published private(set) var username: String = ""

    /// Stored in the shared container rather than standard defaults so the
    /// widgets can eventually mark your own flight too.
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        username = defaults.string(forKey: Self.key) ?? ""
    }

    var isSet: Bool { !username.isEmpty }

    /// What comparisons are made against. Empty when nothing is set, which is
    /// deliberately a value that matches nothing rather than everything.
    var matchKey: String { username.lowercased() }

    /// Returns the cleaned name that was stored, or nil if it was unusable.
    ///
    /// Infinite Flight community handles are Discourse usernames: letters,
    /// numbers, underscores, hyphens and dots. Anything else is a paste
    /// accident — a profile URL, an email, a display name with spaces — and is
    /// refused rather than stored as something that will silently never match.
    @discardableResult
    func set(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return nil }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        guard trimmed.count <= 40,
              trimmed.lowercased().unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        guard trimmed != username else { return trimmed }
        username = trimmed
        defaults.set(trimmed, forKey: Self.key)
        return trimmed
    }

    func clear() {
        guard !username.isEmpty else { return }
        username = ""
        defaults.removeObject(forKey: Self.key)
    }

    /// Whether a flight's pilot is this user.
    func isMe(_ candidate: String?) -> Bool {
        guard isSet, let candidate = candidate, !candidate.isEmpty else { return false }
        return candidate.lowercased() == matchKey
    }

    /// Adopts the name stored against the signed-in account.
    ///
    /// The device wins when both exist and differ: whoever is holding the phone
    /// set it here most recently, and silently replacing what they typed with
    /// something from the website would be the wrong way round. Only an empty
    /// device value takes the account's.
    func adoptFromAccount(_ remote: String?) {
        guard !isSet, let remote = remote else { return }
        set(remote)
    }
}
