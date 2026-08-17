import UIKit

/// Single place for the values the tracker depends on.
///
/// The live feed is the same ACARS backend the web tracker talks to
/// (see `old/www/flight.js` -> `ACARS_SOCKET_URL`), so the native app sees
/// exactly the same traffic as the old build.
enum AppConfig {

    /// Socket.IO endpoint broadcasting `all_flights_update`.
    static let socketURLString = "https://site--acars-backend--6dmjph8ltlhv.code.run"

    /// REST backend behind the community aircraft photos.
    static let apiBaseURLString = "https://site--indgo-backend--6dmjph8ltlhv.code.run"

    /// Breadcrumb history for one flight — the path it has already flown.
    /// Same endpoint the Capacitor build fetches (`old/www/flight.js`, where
    /// `LIVE_FLIGHTS_API_URL` has `/flights` swapped for `/api/flights`).
    static func flightHistoryURL(flightId: String) -> URL? {
        guard let encoded = flightId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(socketURLString)/api/flights/\(encoded)/history")
    }

    /// What the backend will actually do for us — push, watchlist storage,
    /// which event kinds it knows about. Probed on launch rather than assumed,
    /// so a client shipped ahead of a backend rollout shows the friends list
    /// as unavailable instead of silently registering for pushes that will
    /// never arrive.
    static var watchlistCapabilitiesURL: URL? {
        URL(string: "\(socketURLString)/api/watchlist/capabilities")
    }

    /// Where this device registers its APNs token. The token is the identity —
    /// the tracker has no accounts.
    static var pushSubscriptionsURL: URL? {
        URL(string: "\(socketURLString)/api/push/subscriptions")
    }

    static func pushSubscriptionURL(deviceToken: String) -> URL? {
        URL(string: "\(socketURLString)/api/push/subscriptions/\(deviceToken)")
    }

    /// Live Activity push tokens, tied to the device rather than an account.
    static var liveActivityTokensURL: URL? {
        URL(string: "\(socketURLString)/api/push/device-live-activity-tokens")
    }

    /// The Supabase project the web tracker has always used — same accounts,
    /// same passwords, same `profiles` table (`old/www/flight.js`, where
    /// `supabaseUrl` and `supabaseKey` are declared). Signing in here is
    /// signing into the account you already have on inflight.info.
    static let supabaseURLString = "https://lcgaoiqwwpyqndaucyzu.supabase.co"

    /// The project's publishable `anon` key.
    ///
    /// Not a secret, and not treated as one: it identifies the project to
    /// PostgREST and grants exactly what row-level security allows an
    /// unauthenticated caller. It shipped in the web bundle for the same
    /// reason. The thing that must never appear here is the `service_role`
    /// key, which bypasses RLS entirely.
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxjZ2FvaXF3d3B5cW5kYXVjeXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIwNjkyOTksImV4cCI6MjA4NzY0NTI5OX0.9TO21knXR_P9E80pea7gUOu-gTjb17sCGk7BYgRRe3U"

    /// The App Store product behind Inflight Pro — a non-consumable, US tier
    /// $1.99. The identifier has to match the one on the App Store Connect
    /// record exactly; the price lives there rather than here, so every
    /// storefront gets its own.
    static let proProductID = "com.tracker.Inflight.pro"

    /// Erases the signed-in account, from the app.
    ///
    /// Guideline 5.1.1(v) requires an app that lets you *make* an account to
    /// let you delete it from inside the app — not by email, and not on a
    /// website. Deleting an auth user needs the `service_role` key, which must
    /// never be in a client, so it is an Edge Function that checks the caller's
    /// own token and deletes only that caller. Source, and how to deploy it, in
    /// `supabase/functions/delete-account/`.
    static var accountDeletionURL: URL? {
        URL(string: "\(supabaseURLString)/functions/v1/delete-account")
    }

    /// Rooms the backend broadcasts on, joined via `join_server_room`.
    static let servers = ["Expert Server", "Training Server", "Casual Server"]

    static let defaultServer = "Expert Server"

    /// Key used to remember the last picked server between launches.
    static let serverDefaultsKey = "preferredServer"

    /// On-screen size of a plane sprite, in points. The web tracker draws its
    /// icons at a uniform ~19px (every sprite is normalised to 128 logical px
    /// and then drawn at `icon-size: 0.15`), so a single size for all types
    /// matches the old look.
    static let iconPointSize: CGFloat = 26

    /// Transparent padding around each sprite. The plane itself stays small,
    /// but the annotation view is big enough to be tapped comfortably.
    static let iconCanvasSize: CGFloat = 44

    /// How long an aircraft that has stopped appearing in the feed keeps its
    /// place on the map.
    ///
    /// The backend drops an aircraft from the odd packet and has it back in the
    /// next one. Removing it the moment it goes missing and adding it again a
    /// few seconds later is the blink that made traffic look like it was
    /// popping in and out; holding its last position for a few packets costs
    /// nothing and covers the gap. Long enough to ride out a stutter, short
    /// enough that an aircraft which has actually landed doesn't hang about.
    static let flightGracePeriod: TimeInterval = 30

    /// Fraction of the visible span, beyond the edge of the screen, within
    /// which an aircraft is added to the map.
    ///
    /// Generous on purpose: the map is loaded well past what it is showing, so
    /// a pan reveals aircraft that are already drawn instead of waiting for the
    /// next cull to put them there.
    static let flightAddMargin: Double = 0.9

    /// The same boundary for *keeping* an aircraft that is already drawn.
    ///
    /// Wider than the add margin, and that gap is the point: with one shared
    /// boundary, an aircraft sitting on it — or the map's own region jittering
    /// across it — flips between added and removed on consecutive passes.
    static let flightKeepMargin: Double = 1.35
}
