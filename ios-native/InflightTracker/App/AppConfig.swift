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

    /// The filed plan for one flight, resolved by flight id alone — the map
    /// holds one of those and has no idea which session the aeroplane is in.
    static func flightPlanURL(flightId: String) -> URL? {
        guard let encoded = flightId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "\(socketURLString)/api/flights/\(encoded)/plan")
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

    /// Where this device's APNs token is tied to the signed-in **account**.
    ///
    /// The subscription above is the other direction, and both are needed. A
    /// watchlist push is about somebody you are watching, so it is addressed by
    /// the token that registered the watch and needs no account at all. A push
    /// about *your own* flight — the sim link dropping mid-flight, which only
    /// the server can see, because the app is suspended when it happens — has
    /// to reach the pilot, and the server knows whose flight it is by the
    /// account the live status is keyed on. `push_devices` is the only table
    /// that joins an account to a device.
    static var pushDevicesURL: URL? {
        URL(string: "\(socketURLString)/api/push/devices")
    }

    static func pushDeviceURL(deviceToken: String) -> URL? {
        URL(string: "\(socketURLString)/api/push/devices/\(deviceToken)")
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

    /// The products Inflight Pro has ever been sold as.
    ///
    /// Two of them are on sale — a year and a month, sharing a subscription
    /// group on App Store Connect so moving between them is an upgrade Apple
    /// handles rather than two things bought twice. The third is the lifetime
    /// unlock earlier builds sold, which is **no longer offered** and is still
    /// listed here because it is still honoured: somebody who paid once for
    /// Pro keeps Pro, and taking that away because the pricing changed would
    /// be indefensible. See `forSale` for what the paywall actually shows.
    ///
    /// Identifiers have to match the App Store Connect records exactly. Prices
    /// deliberately do not live here — the App Store's own localised price is
    /// the only one the paywall ever shows, because every storefront has a
    /// different number and a hard-coded "$19.99" is wrong in most of them.
    enum ProProduct: String, CaseIterable, Identifiable {

        /// A year. The one the paywall preselects.
        case annual = "com.tracker.Inflight.pro.annual"

        /// A month, for anyone who wants to try it that way.
        case monthly = "com.tracker.Inflight.pro.monthly"

        /// The original non-consumable: one payment, never expires.
        ///
        /// Retired — off the paywall, and removed from sale on App Store
        /// Connect — but never forgotten. It stays in this enum so `ProStore`
        /// still recognises the transaction and still unlocks Pro for everyone
        /// who bought one.
        case lifetime = "com.tracker.Inflight.pro"

        var id: String { rawValue }

        var isSubscription: Bool { self != .lifetime }

        /// What the paywall offers, in the order it offers it.
        ///
        /// Deliberately not `allCases`: the difference between "a product this
        /// app knows about" and "a product this app will sell you" is the
        /// whole point, and conflating them is how a retired product finds its
        /// way back onto the paywall.
        static let forSale: [ProProduct] = [.annual, .monthly]
    }

    /// Every identifier the app asks the App Store for a price for.
    ///
    /// Only what is for sale. The retired lifetime unlock needs no `Product` —
    /// nothing shows its price or offers to buy it — and asking for one that
    /// has been removed from sale is a request that can only fail.
    static var proProductIDs: [String] { ProProduct.forSale.map(\.rawValue) }

    /// The lifetime unlock, by identifier. Kept under its old name because it
    /// is the product every earlier build bought.
    static let proProductID = ProProduct.lifetime.rawValue

    /// Where a verified App Store purchase is linked to the signed-in account.
    ///
    /// StoreKit already tells *this app* what the Apple Account owns, and that
    /// is what unlocks Pro on the device. This is the other half: posting the
    /// signed transaction to the server means the website unlocks too, and
    /// means a renewal or a refund that happens while the app is closed still
    /// reaches the account. Source in `supabase/functions/apple-subscription-sync/`.
    static var appleSubscriptionSyncURL: URL? {
        URL(string: "\(supabaseURLString)/functions/v1/apple-subscription-sync")
    }

    /// The one question the app asks the server about Pro.
    ///
    /// A `security definer` function rather than a table read: the answer
    /// depends on an App Store row, a Stripe row and two flags on `profiles`,
    /// and resolving that in the client would mean four reads and a copy of
    /// the rules that could drift from the website's. See
    /// `supabase/migrations/20260817000100_pro_entitlement_app_store.sql`.
    static var proEntitlementRPCURL: URL? {
        URL(string: "\(supabaseURLString)/rest/v1/rpc/pro_entitlement")
    }

    // MARK: - Profiles

    /// PostgREST, for the handful of rows the app writes directly.
    ///
    /// Reads of somebody else's profile never come through here — they go
    /// through the `pilot_profile_*` functions below, which apply the
    /// visibility rules. This is for a pilot's own row, where row-level
    /// security already says "yours and no other".
    static func tableURL(_ table: String) -> URL? {
        URL(string: "\(supabaseURLString)/rest/v1/\(table)")
    }

    /// A `security definer` function, called by name.
    ///
    /// Most of the profile surface is functions rather than tables, and
    /// deliberately: "which of these rows may this reader see" is a rule, the
    /// rule depends on blocks and reports and the profile's own settings, and a
    /// rule that lives in the client is a rule an unmodified client follows.
    static func rpcURL(_ function: String) -> URL? {
        URL(string: "\(supabaseURLString)/rest/v1/rpc/\(function)")
    }

    /// The public address of a profile picture.
    ///
    /// The buckets are public to read — a stranger's browser has to be able to
    /// fetch the picture, and it has no credential to present — and writable
    /// only by the `profile-image` Edge Function, which holds the service role.
    /// See `20260818000100_pilot_profiles.sql`.
    static func profileImageURL(bucket: String, path: String?) -> URL? {
        guard let path = path, !path.isEmpty,
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(supabaseURLString)/storage/v1/object/public/\(bucket)/\(encoded)")
    }

    /// Where an avatar or a banner is uploaded.
    ///
    /// Not straight into Storage, even though Storage would take it: these
    /// buckets are public, and a public bucket a client can write to is a
    /// public bucket a client can put anything into, at a URL under our own
    /// domain. Source in `supabase/functions/profile-image/`.
    static var profileImageUploadURL: URL? {
        URL(string: "\(supabaseURLString)/functions/v1/profile-image")
    }

    /// Where a profile is read on the open web, for sharing.
    ///
    /// The same page the website serves, so a link pasted into a forum post
    /// opens something a person without the app can read.
    static func publicProfileURL(handle: String) -> URL? {
        URL(string: "https://inflight.info/pilot/\(handle)")
    }

    /// The subscription terms, as App Store Review requires them to be
    /// reachable from the paywall itself.
    ///
    /// Apple's standard EULA is the one every app is covered by unless it
    /// files its own, and it is a link that cannot rot. Swap it for
    /// inflight.info's own terms page the day there is one.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    static let privacyURL = URL(string: "https://inflight.info/privacy")

    /// Where iOS lets someone change or cancel a subscription. Apple's own
    /// deep link, so it lands on the right screen of Settings rather than on
    /// the App Store's front page.
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")

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

    /// On-screen size of the longest side of an aircraft mark, in points,
    /// before its type's own scale.
    ///
    /// 26 while the icons came off the sprite sheet, but that was the size of
    /// the *crop*: the drawing floated inside a square box and only ever filled
    /// around 70% of it, so the aeroplane anyone actually saw was about 18
    /// points across. The marks are fitted to their own ink now, with no box
    /// around them, so matching the old look means saying 18 rather than 26.
    static let iconPointSize: CGFloat = 18

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
