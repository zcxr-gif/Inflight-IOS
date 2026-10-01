import Foundation
import MapboxMaps

/// The token the map draws with, and whether the build was given one.
///
/// It is never in the repository. `Support/Info.plist` carries
/// `$(MAPBOX_ACCESS_TOKEN)`, and the Codemagic build writes the real value in
/// from its environment just before archiving; a local or CI compile without
/// it builds fine and draws an empty map. That is the one failure worth
/// making loud, because nothing else will: Mapbox answers a missing token
/// with a 401 per tile and a blank canvas, which looks exactly like a slow
/// network.
enum MapboxAccess {

    /// The public token from the bundle, or empty.
    static var token: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A public token, as opposed to nothing or an unexpanded placeholder.
    static var isConfigured: Bool { token.hasPrefix("pk.") }

    /// Hands the token to every Mapbox SDK in the process. Called once at
    /// launch, before the first map view exists — a view built first takes
    /// whatever token was set when it was created.
    static func prepare() {
        guard isConfigured else {
            print("[Mapbox] No access token in this build — the map will be empty. Set MAPBOX_ACCESS_TOKEN where the app is built.")
            return
        }
        MapboxOptions.accessToken = token
    }
}
