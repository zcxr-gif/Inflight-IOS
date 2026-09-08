import Combine
import Foundation
import UIKit

/// The signed-in pilot's own public profile.
///
/// Everything a stranger sees is read through `PilotDirectory`, which goes via
/// the server's visibility functions. This is the other side of that: the row
/// itself, read and written with the account's own token, where row-level
/// security says "yours and no other" and the write guard on `pilot_profiles`
/// says which columns are the client's to set at all.
///
/// The split matters. A profile a pilot is editing is not the same object as a
/// profile somebody is reading — the editable one still carries the banner they
/// uploaded while they were Pro, and the readable one does not, because the
/// server blanks it for an account whose subscription has ended. Keeping the
/// banner in the row rather than deleting it is the point: a lapsed
/// subscription should not destroy something somebody made, and resubscribing
/// should put it straight back.
@MainActor
final class ProfileStore: ObservableObject {

    static let shared = ProfileStore()

    /// The pilot's own row, or nil when they have not claimed a handle — or
    /// when nobody is signed in. Both are ordinary states: the tracker works
    /// signed out, and an account without a profile is an account that has not
    /// been asked for one yet.
    @Published private(set) var profile: Editable?

    /// Set while the row is being read for the first time, so the panel shows
    /// nothing rather than flashing "claim a handle" at somebody who has one.
    @Published private(set) var isLoading = false

    @Published private(set) var isSaving = false

    /// True while a picture is on its way up. Named for the kind so the two
    /// spinners are independent — a banner uploading must not make the avatar
    /// look like it is too.
    @Published private(set) var uploading: ImageKind?

    @Published var problem: String?
    @Published var notice: String?

    /// Raised when the server refused because the account is free. The panel
    /// opens the paywall off this rather than off an error string.
    @Published var needsProFor: ProFeature?

    /// What moderation has said to this pilot, and whether they may add
    /// pictures. Nil until read, and nil for a signed-out reader.
    @Published private(set) var standing: Standing?

    /// The pilot's side of moderation: what they were told, and what it stops
    /// them doing.
    ///
    /// `uploadsNotice` is composed BY THE SERVER and shown verbatim. It would
    /// be easy to build the sentence here from `uploadsRestrictedUntil` and
    /// save a column — and then a pilot who has not updated the app in three
    /// months would be reading three-month-old wording about a restriction
    /// applied this morning, and the refusal they get from the upload button
    /// would not match the banner sitting above it. One sentence, from one
    /// place, is the whole point.
    /// Timestamps are decoded as text and converted, not declared as `Date`.
    /// `SupabaseData.rpc` decodes with a plain `JSONDecoder`, whose default
    /// date strategy reads a number of seconds — handed a Postgres timestamp
    /// it throws, and the throw would take the whole standing with it. The
    /// same variable-fractional-digits problem `SupabaseAuth.Timestamp` was
    /// written for, so it is what parses them.
    struct Standing: Decodable, Equatable {
        var warnings: [Warning] = []
        var activeCount: Int = 0
        var unacknowledgedCount: Int = 0
        var uploadsRestricted: Bool = false
        var uploadsRestrictedUntilText: String?
        var uploadsNotice: String = ""

        var uploadsRestrictedUntil: Date? {
            uploadsRestrictedUntilText.flatMap(SupabaseAuth.Timestamp.date(from:))
        }

        /// Warnings that still stand, newest first — what the editor lists.
        var standingWarnings: [Warning] { warnings.filter(\.isStanding) }

        enum CodingKeys: String, CodingKey {
            case warnings
            case activeCount = "active_count"
            case unacknowledgedCount = "unacknowledged_count"
            case uploadsRestricted = "uploads_restricted"
            case uploadsRestrictedUntilText = "uploads_restricted_until"
            case uploadsNotice = "uploads_notice"
        }

        struct Warning: Decodable, Equatable, Identifiable {
            let id: String
            let level: String
            let reason: String
            let category: String?
            let acknowledgedAtText: String?
            let rescindedAtText: String?
            let createdAtText: String?
            let uploadBlock: Bool

            var acknowledgedAt: Date? {
                acknowledgedAtText.flatMap(SupabaseAuth.Timestamp.date(from:))
            }
            var createdAt: Date? {
                createdAtText.flatMap(SupabaseAuth.Timestamp.date(from:))
            }

            var isAcknowledged: Bool { acknowledgedAtText != nil }

            /// A rescinded warning is one we withdrew. It is still shown, and
            /// shown as withdrawn: a warning issued in error is part of how
            /// this pilot has been treated, and dropping it would make the
            /// record we keep differ from the record they can see.
            var isStanding: Bool { rescindedAtText == nil }

            var title: String {
                switch level {
                case "notice": return "Notice"
                case "first": return "First warning"
                case "final": return "Final warning"
                case "suspended": return "Profile suspended"
                default: return "Warning"
                }
            }

            enum CodingKeys: String, CodingKey {
                case id, level, reason, category
                case acknowledgedAtText = "acknowledged_at"
                case rescindedAtText = "rescinded_at"
                case createdAtText = "created_at"
                case uploadBlock = "upload_block"
            }
        }
    }

    /// A profile as its owner edits it.
    ///
    /// Deliberately not `PilotProfile`: that type is what a reader gets, it has
    /// counts and relationship flags on it that mean nothing here, and it is
    /// missing the two settings — the logbook's visibility, the row's own
    /// privacy — that only the owner ever sees.
    struct Editable: Equatable {

        var handle: String = ""
        var displayName: String = ""
        var bio: String = ""
        var ifUsername: String = ""
        var favouriteAircraft: String = ""
        var favouriteLivery: String = ""
        var homeAirport: String = ""

        var bannerPreset: BannerPreset = .dusk

        /// Pro. Kept as the stored value even when Pro has lapsed, so it is
        /// still there to come back to.
        var accent: String?

        var isPublic: Bool = true
        var friendsVisibility: Visibility = .public
        var logbookVisibility: Visibility = .public

        /// Who may see the live status while flying.
        ///
        /// Followers by default, where the other two are public. Deliberately
        /// out of step with them: the friends list and the logbook say who you
        /// know and where you have been, and this says where you are — which is
        /// a different thing to hand to strangers, and the sort of default
        /// nobody should have to go and find.
        var liveVisibility: Visibility = .followers

        /// Whether the server announces this pilot's own flight to them —
        /// airborne, top of descent, landed — from the live feed.
        ///
        /// Stored on the profile rather than in `UserDefaults` because the
        /// thing that acts on it is the backend, not this app: the whole point
        /// of these notices is that they are worked out and sent while the app
        /// is suspended behind Infinite Flight, or not running at all. A local
        /// preference could not be consulted at the moment it matters.
        var flightAlerts: Bool = true

        var avatarPath: String?
        var bannerPath: String?

        /// The VAs this pilot has chosen to wear, in their own order.
        ///
        /// Written here, entitled elsewhere. Sending an id the pilot has no
        /// claim to is not refused, because refusing it here would be a check
        /// in the wrong place — the rosters are the partner backend's and the
        /// resolution that decides whether a badge is drawn happens against
        /// them every time it is drawn. What is stored is a preference; the
        /// picker only offers rosters this pilot is actually on, and an id
        /// that stops being true stops being drawn on its own.
        var vaAdIds: [String] = []

        /// Set by the server when a profile has been hidden. Read-only, and
        /// shown to its owner so they know why nobody can find them.
        var moderationState: String = "ok"
        var moderationNote: String?

        var avatarURL: URL? {
            AppConfig.profileImageURL(bucket: "pilot-avatars", path: avatarPath)
        }

        var bannerURL: URL? {
            AppConfig.profileImageURL(bucket: "pilot-banners", path: bannerPath)
        }

        /// Two letters for the avatar to fall back on before a picture is
        /// uploaded, or while one is still loading.
        ///
        /// Same rule as `PilotProfile.initials`, with one addition: a profile
        /// mid-edit can have an empty display name where a fetched one cannot,
        /// so the handle stands in rather than leaving the circle blank.
        var initials: String {
            let source = displayName.trimmingCharacters(in: .whitespaces).isEmpty
                ? handle
                : displayName

            let words = source
                .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
                .filter { $0.contains(where: \.isLetter) }

            if words.count >= 2 {
                return words.prefix(2).compactMap { $0.first.map(String.init) }
                    .joined().uppercased()
            }

            let letters = source.filter { $0.isLetter || $0.isNumber }
            return String(letters.prefix(2)).uppercased()
        }

        var isHidden: Bool { moderationState != "ok" }
    }

    enum Visibility: String, CaseIterable, Identifiable {
        case `public`
        case followers
        case `private`

        var id: String { rawValue }

        var label: String {
            switch self {
            case .public: return "Everyone"
            case .followers: return "Followers"
            case .private: return "Only me"
            }
        }
    }

    enum ImageKind: String, Equatable {
        case avatar
        case banner

        /// The longest side the picture is scaled to before it is sent.
        ///
        /// Done on the device, not the server. An avatar is drawn at 96 points
        /// and a banner at the width of a phone; sending a 12-megapixel camera
        /// photograph to be stored at full size costs the pilot their data
        /// allowance, costs the bucket the bytes forever, and costs every
        /// reader of the profile the download. The server still checks what
        /// arrives — see `profile-image` — because a client is a thing that can
        /// be modified, but the resizing belongs here where the picture is.
        var longestSide: CGFloat {
            switch self {
            case .avatar: return 720
            case .banner: return 1800
            }
        }

        var feature: ProFeature? {
            switch self {
            case .avatar: return nil
            case .banner: return .profileBanner
            }
        }
    }

    private init() {}

    var hasProfile: Bool { profile != nil }

    var handle: String? {
        guard let handle = profile?.handle, !handle.isEmpty else { return nil }
        return handle
    }

    // MARK: - Loading

    /// Called by `AccountStore` when somebody signs in or out.
    ///
    /// Not `async`, because the caller is in the middle of adopting a session
    /// and a profile is not something to hold that up for. Signing out clears
    /// synchronously — leaving the last person's profile loaded while the next
    /// one signs in would be the worst possible time to be lazy about it.
    func accountChanged() {
        guard AccountStore.shared.isSignedIn else {
            profile = nil
            problem = nil
            notice = nil
            // Signing out has to drop this too. It is one account's warnings,
            // and leaving it behind would show them to whoever signs in next.
            standing = nil
            return
        }
        Task { await load() }
    }

    func load() async {
        guard let account = AccountStore.shared.account else {
            profile = nil
            standing = nil
            return
        }

        // Alongside the row, not after it. A pilot whose uploads are switched
        // off should see that the moment the editor draws, not one round trip
        // after the avatar button has already invited them to try.
        //
        // Its own task rather than sequenced into the body below, because that
        // body returns early in three places when the URL cannot be built —
        // and a pilot must not fail to be told about a restriction because
        // some unrelated `URLComponents` came back nil.
        Task { await self.loadStanding() }
        guard let token = await AccountStore.shared.currentAccessToken() else { return }

        isLoading = true
        defer { isLoading = false }

        // Filtered by id rather than trusting row-level security to return one
        // row. The select policy on this table is two policies OR-ed — your own
        // row, and every public one — so an unfiltered read would come back
        // with the whole directory and this would adopt a stranger's profile as
        // the user's own.
        guard var components = URLComponents(
            url: AppConfig.tableURL("pilot_profiles") ?? URL(fileURLWithPath: "/"),
            resolvingAgainstBaseURL: false
        ) else { return }

        components.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(account.id)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                return
            }
            profile = Self.decodeRow(data)
        } catch {
            // Left as it was. A profile that could not be re-read is not a
            // profile that has been deleted, and blanking the editor because
            // the phone lost signal would look like exactly that.
        }
    }

    // MARK: - Where this pilot stands

    /// Warnings this pilot has been sent about what they uploaded, and whether
    /// adding pictures is currently switched off for them.
    ///
    /// Read separately from the profile row rather than joined onto it,
    /// because it is a different KIND of thing: the profile is what the pilot
    /// wrote and may rewrite, this is what was said to them and they cannot.
    /// Keeping them apart is also why a failure here leaves the editor working
    /// — a warning that could not be fetched must not stop somebody fixing
    /// their bio.
    func loadStanding() async {
        guard AccountStore.shared.account != nil else {
            standing = nil
            return
        }
        guard let token = await AccountStore.shared.currentAccessToken() else { return }
        do {
            let rows: [Standing] = try await SupabaseData.rpc(
                "pilot_my_standing",
                accessToken: token
            )
            // No rows is the signed-out answer, and it arrives here whenever a
            // token has just expired. Left as it was rather than blanked: a
            // restriction that briefly failed to load must not read as one
            // that has been lifted.
            if let first = rows.first { standing = first }
        } catch {
            // Same reasoning as `load()`. Silence, not a blank.
        }
    }

    /// Marks a warning as received. Not as agreed with — there is nowhere in
    /// this app to disagree, and pretending otherwise would be worse than
    /// saying plainly what the button does.
    func acknowledgeWarning(_ id: String) async {
        guard let token = await AccountStore.shared.currentAccessToken() else { return }
        // Annotated rather than cast: `rpc` is generic over its return, so the
        // type has to be stated somewhere, and a binding states it without
        // wrapping the whole `try? await` in a postfix `as`.
        let _: [Bool]? = try? await SupabaseData.rpc(
            "pilot_acknowledge_warning",
            arguments: ["p_warning_id": id],
            accessToken: token
        )
        await loadStanding()
    }

    // MARK: - Writing

    /// Fills in the Infinite Flight handle from the running simulator.
    ///
    /// Only ever fills a blank. `infiniteflight/current_user` is a stronger
    /// claim than anything typed into a text field — it is read out of the sim
    /// that is flying the aeroplane — but a profile is a public thing, and
    /// silently rewriting the name on somebody's public profile because a
    /// simulator said something else is not a repair, it is a surprise. When
    /// they disagree the Connect panel offers the swap instead.
    ///
    /// Worth doing at all because the handle is the join between a profile and
    /// an aeroplane on the map, and asking somebody to type in a name the app
    /// is already being told is how the join ends up blank or misspelled — and
    /// a blank join is a pilot who is told nothing about their own flight.
    @discardableResult
    func adoptSimUsername(_ raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard var current = profile else { return false }
        guard current.ifUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        current.ifUsername = trimmed
        return await save(current)
    }

    /// The same swap, asked for deliberately after being offered it.
    @discardableResult
    func replaceIFUsername(with raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = profile else { return false }
        guard current.ifUsername != trimmed else { return false }

        current.ifUsername = trimmed
        return await save(current)
    }

    /// Claims a handle, or saves an edit. The same request either way — there
    /// is one row per account, and which of the two this is is not something
    /// the client should have to find out by reading first.
    ///
    /// Returns whether it saved, so a sheet can dismiss itself on success and
    /// stay open on a refusal.
    @discardableResult
    func save(_ edited: Editable) async -> Bool {
        guard let account = AccountStore.shared.account,
              let token = await AccountStore.shared.currentAccessToken() else {
            problem = "Sign in to set up a profile."
            return false
        }

        isSaving = true
        problem = nil
        notice = nil
        needsProFor = nil
        defer { isSaving = false }

        // Only the columns a client owns. `moderation_state`, the verified flag
        // and the timestamps are all pinned by the write guard whatever is sent,
        // so sending them would be noise at best and a misleading diff at worst.
        var row: [String: Any] = [
            "user_id": account.id,
            "handle": edited.handle.lowercased(),
            "banner_preset": edited.bannerPreset.rawValue,
            "is_public": edited.isPublic,
            "friends_visibility": edited.friendsVisibility.rawValue,
            "logbook_visibility": edited.logbookVisibility.rawValue,
            "live_visibility": edited.liveVisibility.rawValue,
            "flight_alerts": edited.flightAlerts
        ]

        // NSNull rather than omission: leaving a key out of an upsert leaves
        // the stored value alone, so clearing a bio would silently do nothing.
        func optional(_ value: String) -> Any {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? NSNull() : trimmed
        }

        row["display_name"] = optional(edited.displayName)
        row["bio"] = optional(edited.bio)
        row["if_username"] = optional(edited.ifUsername)
        row["favourite_aircraft"] = optional(edited.favouriteAircraft)
        row["favourite_livery"] = optional(edited.favouriteLivery)
        row["home_airport"] = optional(edited.homeAirport.uppercased())
        row["accent"] = edited.accent.map { $0 as Any } ?? NSNull()
        // An array rather than an optional: empty is a pilot who wears none,
        // which is a value and not an absence.
        row["va_ad_ids"] = edited.vaAdIds

        do {
            let data = try await SupabaseData.upsert(
                table: "pilot_profiles",
                row: row,
                accessToken: token,
                onConflict: "user_id"
            )
            profile = Self.decodeRow(data) ?? edited
            notice = "Profile saved."

            // The handle is what the rest of the app finds this pilot by, and
            // the Infinite Flight name is what ties the profile to an aeroplane
            // on the map — so a change to either is pushed onto the account's
            // own metadata, where `PilotIdentity` and the website read it.
            let identity = edited.ifUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identity.isEmpty, identity != PilotIdentity.shared.username {
                PilotIdentity.shared.set(identity)
                await AccountStore.shared.syncPilotName(identity)
            }
            return true
        } catch let failure as SupabaseData.Failure {
            problem = failure.message
            if failure.needsPro { needsProFor = .profileBanner }
            return false
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Whether a handle can be claimed, asked of the server.
    ///
    /// Nil when the question could not be answered — offline, mostly — which
    /// the editor shows as "we'll find out when you save" rather than as either
    /// answer. Guessing "available" invites a save that fails on a constraint;
    /// guessing "taken" stops somebody claiming a name that is theirs.
    func isHandleAvailable(_ handle: String) async -> Bool? {
        let candidate = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard candidate.count >= 3 else { return false }

        // Your own handle is always available to you, and asking the server
        // would be a round trip to be told so.
        if candidate == profile?.handle { return true }

        let token = await AccountStore.shared.currentAccessToken()
        do {
            let answer: [Bool] = try await SupabaseData.rpc(
                "pilot_handle_available",
                arguments: ["p_handle": candidate],
                accessToken: token
            )
            return answer.first
        } catch {
            return nil
        }
    }

    // MARK: - Pictures

    /// Scales, encodes and uploads a picture, then adopts the path the server
    /// stored it under.
    ///
    /// The banner is Pro. It is checked here so the picker can open a paywall
    /// instead of a file browser, checked again by the Edge Function before a
    /// byte is stored, and refused a third time by the write guard on the row.
    /// Three checks for one rule is not paranoia about the user: the first is a
    /// courtesy, the second stops a public bucket filling with files that will
    /// never be pointed at, and only the third is actually load-bearing.
    func upload(_ image: UIImage, as kind: ImageKind) async {
        if let feature = kind.feature, !Entitlements.shared.has(feature) {
            needsProFor = feature
            return
        }

        guard AccountStore.shared.isSignedIn,
              let token = await AccountStore.shared.currentAccessToken(),
              let url = AppConfig.profileImageUploadURL else {
            problem = "Sign in to add a picture."
            return
        }

        guard profile != nil else {
            problem = "Claim a handle before adding a picture."
            return
        }

        guard let payload = Self.encode(image, longestSide: kind.longestSide) else {
            problem = "That picture couldn't be prepared."
            return
        }

        uploading = kind
        problem = nil
        notice = nil
        needsProFor = nil
        defer { uploading = nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "kind": kind.rawValue,
            "contentType": "image/jpeg",
            "data": payload.base64EncodedString()
        ])
        // Generous: this is a photograph going up a phone connection.
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            struct Answer: Decodable {
                let path: String?
                let error: String?
                let pro: Bool?
                let uploadsPaused: Bool?
            }
            let answer = try? JSONDecoder().decode(Answer.self, from: data)

            guard (200..<300).contains(status), let path = answer?.path else {
                if answer?.pro == true || status == 402 {
                    needsProFor = kind.feature ?? .profileBanner
                }
                // Refused because a warning has switched uploading off. The
                // server's sentence is shown as-is — it is the same one the
                // editor's banner carries — and the standing is re-read so
                // that banner appears for a pilot who had not seen it yet.
                if answer?.uploadsPaused == true {
                    await loadStanding()
                }
                problem = answer?.error ?? "That picture couldn't be saved."
                return
            }

            switch kind {
            case .avatar: profile?.avatarPath = path
            case .banner: profile?.bannerPath = path
            }
            notice = kind == .avatar ? "Picture updated." : "Banner updated."
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Takes a picture back off. Always allowed, Pro or not — a free account
    /// that used to be Pro must be able to remove the banner it can no longer
    /// change.
    func removeImage(_ kind: ImageKind) async {
        guard let token = await AccountStore.shared.currentAccessToken(),
              let url = AppConfig.profileImageUploadURL else { return }

        uploading = kind
        defer { uploading = nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["kind": kind.rawValue, "remove": true]
        )
        request.timeoutInterval = 30

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            problem = "That picture couldn't be removed."
            return
        }

        switch kind {
        case .avatar: profile?.avatarPath = nil
        case .banner: profile?.bannerPath = nil
        }
    }

    // MARK: - Encoding

    /// Scales to fit `longestSide` and encodes as JPEG.
    ///
    /// JPEG rather than HEIC or PNG: it is the format every browser reading the
    /// public profile page can already draw, it is a tenth of the size of the
    /// PNG a screenshot would otherwise arrive as, and re-encoding is also what
    /// drops the EXIF — a photograph taken on a phone carries the coordinates
    /// it was taken at, and a profile picture is a public file.
    ///
    /// Only ever scales down. Blowing a small picture up to the ceiling would
    /// add bytes and no detail.
    static func encode(_ image: UIImage, longestSide: CGFloat) -> Data? {
        let side = max(image.size.width, image.size.height)
        let scale = side > longestSide ? longestSide / side : 1

        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        guard target.width >= 1, target.height >= 1 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        return rendered.jpegData(compressionQuality: 0.82)
    }

    // MARK: - Decoding

    /// PostgREST answers a filtered select and a returning upsert with an array
    /// of rows, so both land here.
    private static func decodeRow(_ data: Data) -> Editable? {
        struct Row: Decodable {
            let handle: String
            let display_name: String?
            let bio: String?
            let if_username: String?
            let avatar_path: String?
            let banner_path: String?
            let banner_preset: String?
            let accent: String?
            let favourite_aircraft: String?
            let favourite_livery: String?
            let home_airport: String?
            let is_public: Bool?
            let friends_visibility: String?
            let logbook_visibility: String?
            let live_visibility: String?
            let flight_alerts: Bool?
            let moderation_state: String?
            let moderation_note: String?
            let va_ad_ids: [String]?
        }

        guard let row = (try? JSONDecoder().decode([Row].self, from: data))?.first else {
            return nil
        }

        return Editable(
            handle: row.handle,
            displayName: row.display_name ?? "",
            bio: row.bio ?? "",
            ifUsername: row.if_username ?? "",
            favouriteAircraft: row.favourite_aircraft ?? "",
            favouriteLivery: row.favourite_livery ?? "",
            homeAirport: row.home_airport ?? "",
            bannerPreset: BannerPreset.resolved(row.banner_preset),
            accent: row.accent,
            isPublic: row.is_public ?? true,
            friendsVisibility: Visibility(rawValue: row.friends_visibility ?? "public") ?? .public,
            logbookVisibility: Visibility(rawValue: row.logbook_visibility ?? "public") ?? .public,
            liveVisibility: Visibility(rawValue: row.live_visibility ?? "followers") ?? .followers,
            flightAlerts: row.flight_alerts ?? true,
            avatarPath: row.avatar_path,
            bannerPath: row.banner_path,
            vaAdIds: row.va_ad_ids ?? [],
            moderationState: row.moderation_state ?? "ok",
            moderationNote: row.moderation_note
        )
    }
}
