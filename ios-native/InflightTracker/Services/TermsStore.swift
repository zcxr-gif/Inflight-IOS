import Combine
import Foundation

/// Whether the terms have been agreed to, and which version.
///
/// Kept on the device rather than only on the account, because the tracker
/// works signed out: somebody who never makes an account still has to have
/// agreed, and asking again every launch would be both rude and useless. The
/// account copy exists as well — see `AccountStore.recordTermsAcceptance` — so
/// that agreement survives a reinstall and so there is a record on the server
/// of who agreed to what and when, which is the entire point of asking.
///
/// ## Versioning
///
/// `current` is bumped when the terms change in a way people should see. A
/// stored version lower than it puts the gate back up with the changes called
/// out, rather than silently treating an old agreement as covering new terms.
@MainActor
final class TermsStore: ObservableObject {

    static let shared = TermsStore()

    /// The version of the terms in force.
    ///
    /// An integer rather than a date so the comparison is unambiguous, and
    /// deliberately not derived from the app version: shipping a bug fix is not
    /// a reason to ask eighty thousand people to agree to anything.
    static let current = 1

    @Published private(set) var acceptedVersion: Int
    @Published private(set) var acceptedAt: Date?

    private static let versionKey = "terms.acceptedVersion"
    private static let dateKey = "terms.acceptedAt"

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        acceptedVersion = defaults.integer(forKey: Self.versionKey)
        acceptedAt = defaults.object(forKey: Self.dateKey) as? Date
    }

    /// Whether the app may be used without showing the gate.
    var isAccepted: Bool { acceptedVersion >= Self.current }

    /// True when they agreed to an earlier version and the terms have since
    /// changed — which the gate says out loud, because "we've updated our
    /// terms" is the only honest reason to interrupt somebody who has already
    /// agreed once.
    var isUpdate: Bool { acceptedVersion > 0 && acceptedVersion < Self.current }

    func accept() {
        let now = Date()
        acceptedVersion = Self.current
        acceptedAt = now
        defaults.set(Self.current, forKey: Self.versionKey)
        defaults.set(now, forKey: Self.dateKey)

        // If they are already signed in, the account gets the record too. If
        // they are not, `AccountStore` sends it when they next sign in or make
        // an account — see `recordTermsAcceptance`.
        Task { await AccountStore.shared.recordTermsAcceptance() }
    }

    /// Only for the debug menu and the tests. Never called by the app.
    func reset() {
        acceptedVersion = 0
        acceptedAt = nil
        defaults.removeObject(forKey: Self.versionKey)
        defaults.removeObject(forKey: Self.dateKey)
    }
}
