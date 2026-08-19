import SwiftUI
import UIKit

/// A pilot, as everybody else sees them.
///
/// The map has always been full of names with nothing behind them — every
/// aircraft carries its pilot's Infinite Flight handle, and until now that was
/// a string. This is what a name leads to: a picture, a banner, the aeroplane
/// they love, where they fly out of, who they fly with, and what they have
/// flown.
///
/// Decoded straight from `public.pilot_profile_card()`, which is the only way
/// a profile is ever read. That function — not this struct, and not the views
/// — is what decides whether a reader may see any of it: the row is already
/// filtered, the Pro-only fields are already blanked for an account whose Pro
/// has lapsed, and a profile that is private or hidden simply returns nothing.
/// Nothing here re-derives any of that, because a second copy of a visibility
/// rule is a second chance to get it wrong.
struct PilotProfile: Decodable, Equatable, Identifiable {

    let handle: String
    let displayName: String
    let bio: String?

    /// Object paths inside the public storage buckets, not URLs. `avatarURL`
    /// and `bannerURL` below build the address; keeping the path means moving
    /// the bucket or putting a CDN in front of it is not a data migration.
    let avatarPath: String?
    let bannerPath: String?

    /// Which painted banner a profile without a photograph wears. Everybody
    /// gets a banner; Pro is what makes it a photograph.
    let bannerPreset: String

    /// The colour the profile is drawn in. Pro, and already nil for anybody
    /// whose subscription has ended — the server blanks it rather than the app
    /// having to remember to.
    let accent: String?

    /// The Infinite Flight community handle they say is theirs, and whether
    /// anybody has actually checked. Nothing sets `ifUsernameVerified` yet, so
    /// it is always false and everything that shows the handle says "claims to
    /// be" — which is the honest version of a verification we cannot perform.
    let ifUsername: String?
    let ifUsernameVerified: Bool

    let favouriteAircraft: String?
    let favouriteLivery: String?
    let homeAirport: String?

    let isPro: Bool
    let friendsVisibility: String

    let followerCount: Int
    let followingCount: Int
    let friendCount: Int

    let joinedAt: Date?

    /// How the reader stands to this pilot. Answered by the server against the
    /// reader's own token, so a client cannot ask about a relationship it is
    /// not part of.
    let viewerFollows: Bool
    let followsViewer: Bool
    let isFriend: Bool
    let isSelf: Bool
    let viewerBlocked: Bool

    var id: String { handle }

    enum CodingKeys: String, CodingKey {
        case handle
        case displayName = "display_name"
        case bio
        case avatarPath = "avatar_path"
        case bannerPath = "banner_path"
        case bannerPreset = "banner_preset"
        case accent
        case ifUsername = "if_username"
        case ifUsernameVerified = "if_username_verified"
        case favouriteAircraft = "favourite_aircraft"
        case favouriteLivery = "favourite_livery"
        case homeAirport = "home_airport"
        case isPro = "is_pro"
        case friendsVisibility = "friends_visibility"
        case followerCount = "follower_count"
        case followingCount = "following_count"
        case friendCount = "friend_count"
        case joinedAt = "joined_at"
        case viewerFollows = "viewer_follows"
        case followsViewer = "follows_viewer"
        case isFriend = "is_friend"
        case isSelf = "is_self"
        case viewerBlocked = "viewer_blocked"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
        bio = try? c.decode(String.self, forKey: .bio)
        avatarPath = try? c.decode(String.self, forKey: .avatarPath)
        bannerPath = try? c.decode(String.self, forKey: .bannerPath)
        bannerPreset = (try? c.decode(String.self, forKey: .bannerPreset)) ?? "dusk"
        accent = try? c.decode(String.self, forKey: .accent)
        ifUsername = try? c.decode(String.self, forKey: .ifUsername)
        ifUsernameVerified = (try? c.decode(Bool.self, forKey: .ifUsernameVerified)) ?? false
        favouriteAircraft = try? c.decode(String.self, forKey: .favouriteAircraft)
        favouriteLivery = try? c.decode(String.self, forKey: .favouriteLivery)
        homeAirport = try? c.decode(String.self, forKey: .homeAirport)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        friendsVisibility = (try? c.decode(String.self, forKey: .friendsVisibility)) ?? "public"
        followerCount = (try? c.decode(Int.self, forKey: .followerCount)) ?? 0
        followingCount = (try? c.decode(Int.self, forKey: .followingCount)) ?? 0
        friendCount = (try? c.decode(Int.self, forKey: .friendCount)) ?? 0
        joinedAt = (try? c.decode(String.self, forKey: .joinedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        viewerFollows = (try? c.decode(Bool.self, forKey: .viewerFollows)) ?? false
        followsViewer = (try? c.decode(Bool.self, forKey: .followsViewer)) ?? false
        isFriend = (try? c.decode(Bool.self, forKey: .isFriend)) ?? false
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        viewerBlocked = (try? c.decode(Bool.self, forKey: .viewerBlocked)) ?? false
    }

    var avatarURL: URL? { AppConfig.profileImageURL(bucket: "pilot-avatars", path: avatarPath) }

    /// The colour this pilot chose for their profile, if they are Pro and chose
    /// one.
    ///
    /// The server already refuses to serve `accent` for an account whose
    /// subscription has ended — it blanks it rather than the app having to
    /// remember — so this being non-nil is itself the entitlement check, and
    /// there is deliberately no `isPro` test here to drift out of step with it.
    ///
    /// Parsed rather than trusted: the column's check constraint is
    /// `^#[0-9a-f]{6}$`, and a value that somehow is not gets no colour rather
    /// than a crash or a black profile.
    var accentColor: Color? { PilotAccent.color(accent) }

    var bannerURL: URL? { AppConfig.profileImageURL(bucket: "pilot-banners", path: bannerPath) }

    /// Two letters for the empty avatar. A profile always has a display name,
    /// so unlike the account's own initials this never has to fall back to an
    /// email address.
    var initials: String {
        let words = displayName
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
            .filter { $0.contains(where: \.isLetter) }

        if words.count >= 2 {
            return words.prefix(2).compactMap { $0.first.map(String.init) }
                .joined().uppercased()
        }
        let letters = displayName.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    /// What the follow button should say. Four states, not two: following
    /// somebody who follows you back is a friendship and should read as one,
    /// and being followed by somebody you don't follow is the prompt to.
    var relationship: Relationship {
        if isSelf { return .you }
        if isFriend { return .friends }
        if viewerFollows { return .following }
        if followsViewer { return .followsYou }
        return .none
    }

    enum Relationship {
        case none
        case following
        case followsYou
        case friends
        case you
    }
}

/// One pilot in a list — a friends list, a followers list, a search result.
///
/// The same seven fields wherever a row of people appears, because they are the
/// same rows: `public.pilot_summary` is one composite type on the server for
/// exactly this reason.
struct PilotSummary: Decodable, Equatable, Identifiable, Hashable {

    let handle: String
    let displayName: String
    let avatarPath: String?
    let ifUsername: String?
    let favouriteAircraft: String?
    let homeAirport: String?
    let isPro: Bool

    /// The colour this pilot chose, when they are Pro and chose one.
    ///
    /// Added to `pilot_summary` by `20260819000000_pilot_accent_in_summary.sql`.
    /// Before that the type had no such column and this property could not have
    /// been decoded — which is why an earlier build carried an `accentColor`
    /// here that referred to a field that did not exist and would not compile.
    /// Optional all the way down, so a client running ahead of the migration
    /// simply gets nil and the default ring.
    let accent: String?

    var id: String { handle }

    enum CodingKeys: String, CodingKey {
        case handle
        case accent
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case ifUsername = "if_username"
        case favouriteAircraft = "favourite_aircraft"
        case homeAirport = "home_airport"
        case isPro = "is_pro"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
        avatarPath = try? c.decode(String.self, forKey: .avatarPath)
        ifUsername = try? c.decode(String.self, forKey: .ifUsername)
        favouriteAircraft = try? c.decode(String.self, forKey: .favouriteAircraft)
        homeAirport = try? c.decode(String.self, forKey: .homeAirport)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        accent = try? c.decode(String.self, forKey: .accent)
    }

    var accentColor: Color? { PilotAccent.color(accent) }

    var avatarURL: URL? { AppConfig.profileImageURL(bucket: "pilot-avatars", path: avatarPath) }

    var initials: String {
        let letters = displayName.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }
}

/// One flight the tracker watched to its end.
struct LogbookEntry: Decodable, Equatable, Identifiable {

    let id: String
    let flightId: String?
    let server: String?
    let callsign: String?
    let aircraft: String?
    let livery: String?
    let originIcao: String?
    let destinationIcao: String?
    let departedAt: Date?
    let landedAt: Date
    let minutes: Int
    let distanceNm: Int?
    let maxAltitudeFeet: Int?
    let topGroundSpeedKnots: Int?

    /// Where the row's numbers came from: `feed` when the flight was inferred
    /// from the public live feed, `connect` when the simulator measured it.
    ///
    /// Worth showing rather than hiding. They are different kinds of claim, and
    /// a landing rate exists only on the second — so a logbook that mixed them
    /// silently would be inviting somebody to compare two numbers that are not
    /// comparable.
    let source: String?

    let landingVerticalSpeedFPM: Int?
    let landingScore: Int?
    let landingGForce: Double?
    let landingCentrelineOffsetM: Int?
    let landingAimingPointOffsetM: Int?

    /// True when the list stopped because the account is free rather than
    /// because it ran out of flights. Comes back on every row so the client
    /// never has to guess; the panel says which, because a logbook that appears
    /// to have lost half of itself is worse than one that explains the limit.
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case flightId = "flight_id"
        case server, callsign, aircraft, livery
        case originIcao = "origin_icao"
        case destinationIcao = "destination_icao"
        case departedAt = "departed_at"
        case landedAt = "landed_at"
        case minutes
        case distanceNm = "distance_nm"
        case maxAltitudeFeet = "max_altitude_feet"
        case topGroundSpeedKnots = "top_ground_speed_knots"
        case source
        case landingVerticalSpeedFPM = "landing_vertical_speed_fpm"
        case landingScore = "landing_score"
        case landingGForce = "landing_g_force"
        case landingCentrelineOffsetM = "landing_centreline_offset_m"
        case landingAimingPointOffsetM = "landing_aiming_point_offset_m"
        case truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        flightId = try? c.decode(String.self, forKey: .flightId)
        server = try? c.decode(String.self, forKey: .server)
        callsign = try? c.decode(String.self, forKey: .callsign)
        aircraft = try? c.decode(String.self, forKey: .aircraft)
        livery = try? c.decode(String.self, forKey: .livery)
        originIcao = try? c.decode(String.self, forKey: .originIcao)
        destinationIcao = try? c.decode(String.self, forKey: .destinationIcao)
        departedAt = (try? c.decode(String.self, forKey: .departedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        landedAt = (try? c.decode(String.self, forKey: .landedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:)) ?? Date()
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
        distanceNm = try? c.decode(Int.self, forKey: .distanceNm)
        maxAltitudeFeet = try? c.decode(Int.self, forKey: .maxAltitudeFeet)
        topGroundSpeedKnots = try? c.decode(Int.self, forKey: .topGroundSpeedKnots)
        source = try? c.decode(String.self, forKey: .source)
        landingVerticalSpeedFPM = try? c.decode(Int.self, forKey: .landingVerticalSpeedFPM)
        landingScore = try? c.decode(Int.self, forKey: .landingScore)
        // PostgREST renders `numeric` as a JSON string rather than a number, so
        // this is the one field that has to try both.
        landingGForce = (try? c.decode(Double.self, forKey: .landingGForce))
            ?? (try? c.decode(String.self, forKey: .landingGForce)).flatMap(Double.init)
        landingCentrelineOffsetM = try? c.decode(Int.self, forKey: .landingCentrelineOffsetM)
        landingAimingPointOffsetM = try? c.decode(Int.self, forKey: .landingAimingPointOffsetM)
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
    }

    /// Whether the simulator measured this flight rather than it being worked
    /// out from the map.
    var wasMeasured: Bool { source == "connect" }

    /// The landing as a pilot reads it. Nil when there was no measurement,
    /// which is most flights.
    var landingLabel: String? {
        guard let rate = landingVerticalSpeedFPM, rate != 0 else { return nil }
        return "\(rate) fpm"
    }

    /// The thresholds the Infinite Flight community uses, not ones we invented.
    var landingVerdict: String? {
        guard let rate = landingVerticalSpeedFPM, rate != 0 else { return nil }
        switch abs(rate) {
        case ..<60:  return "Greased"
        case ..<150: return "Smooth"
        case ..<300: return "Firm"
        case ..<600: return "Hard"
        default:     return "Very hard"
        }
    }

    var route: String {
        "\(originIcao ?? "————") → \(destinationIcao ?? "————")"
    }

    /// "6h 20m", or "45m" under the hour. Block time reads badly in minutes
    /// once it is into the hundreds.
    var blockTime: String {
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}

/// The all-time numbers behind a profile.
struct LogbookSummary: Decodable, Equatable {

    let flights: Int
    let minutes: Int
    let distanceNm: Int
    let airports: Int
    let aircraftTypes: Int
    let regions: Int
    let longestMinutes: Int
    let longestDistanceNm: Int
    let highestFeet: Int
    let firstFlightAt: Date?
    let lastFlightAt: Date?
    let topAircraft: String?
    let topRoute: String?

    /// Everything below is measured by the simulator rather than inferred from
    /// the map, and is zero for a pilot who has never flown with Connect
    /// attached. `landingsMeasured` is what tells the two apart — a best
    /// landing of 0 fpm and no landings at all would otherwise look identical.
    let landingsMeasured: Int
    let bestLandingFPM: Int?
    let averageLandingFPM: Int?
    let recentLandingFPM: Int?
    let greasers: Int
    let bestLandingScore: Int?

    enum CodingKeys: String, CodingKey {
        case flights, minutes, airports, regions, greasers
        case distanceNm = "distance_nm"
        case aircraftTypes = "aircraft_types"
        case longestMinutes = "longest_minutes"
        case longestDistanceNm = "longest_distance_nm"
        case highestFeet = "highest_feet"
        case firstFlightAt = "first_flight_at"
        case lastFlightAt = "last_flight_at"
        case topAircraft = "top_aircraft"
        case topRoute = "top_route"
        case landingsMeasured = "landings_measured"
        case bestLandingFPM = "best_landing_fpm"
        case averageLandingFPM = "average_landing_fpm"
        case recentLandingFPM = "recent_landing_fpm"
        case bestLandingScore = "best_landing_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flights = (try? c.decode(Int.self, forKey: .flights)) ?? 0
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
        distanceNm = (try? c.decode(Int.self, forKey: .distanceNm)) ?? 0
        airports = (try? c.decode(Int.self, forKey: .airports)) ?? 0
        aircraftTypes = (try? c.decode(Int.self, forKey: .aircraftTypes)) ?? 0
        regions = (try? c.decode(Int.self, forKey: .regions)) ?? 0
        longestMinutes = (try? c.decode(Int.self, forKey: .longestMinutes)) ?? 0
        longestDistanceNm = (try? c.decode(Int.self, forKey: .longestDistanceNm)) ?? 0
        highestFeet = (try? c.decode(Int.self, forKey: .highestFeet)) ?? 0
        firstFlightAt = (try? c.decode(String.self, forKey: .firstFlightAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        lastFlightAt = (try? c.decode(String.self, forKey: .lastFlightAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        topAircraft = try? c.decode(String.self, forKey: .topAircraft)
        topRoute = try? c.decode(String.self, forKey: .topRoute)
        landingsMeasured = (try? c.decode(Int.self, forKey: .landingsMeasured)) ?? 0
        bestLandingFPM = try? c.decode(Int.self, forKey: .bestLandingFPM)
        averageLandingFPM = try? c.decode(Int.self, forKey: .averageLandingFPM)
        recentLandingFPM = try? c.decode(Int.self, forKey: .recentLandingFPM)
        greasers = (try? c.decode(Int.self, forKey: .greasers)) ?? 0
        bestLandingScore = try? c.decode(Int.self, forKey: .bestLandingScore)
    }

    var hours: Int { minutes / 60 }

    var isEmpty: Bool { flights == 0 }

    /// Whether this pilot has ever flown with the simulator attached. The
    /// landing card is drawn only when they have — an empty one would be
    /// telling everybody who has not that they are missing something, on a
    /// profile that is not the place to sell them anything.
    var hasMeasuredLandings: Bool { landingsMeasured > 0 }
}

/// One thing a pilot has done, or is on the way to doing.
///
/// Derived on the server from the logbook rather than stored, so a badge is
/// true by construction and cannot be granted by hand. Every badge comes back
/// whether it has been earned or not, with the progress towards it — a profile
/// that shows the next one is something to fly towards, where an empty shelf is
/// just an empty shelf.
struct PilotBadge: Decodable, Equatable, Identifiable {

    let code: String
    let family: String
    let title: String
    let detail: String
    let target: Int
    let progress: Int
    let earned: Bool

    var id: String { code }

    var fraction: Double {
        guard target > 0 else { return 0 }
        return min(Double(progress) / Double(target), 1)
    }

    /// The glyph for the family this badge belongs to, so a shelf of them reads
    /// as a handful of kinds rather than twenty different pictures.
    var symbol: String {
        switch family {
        case "hours": return "clock.fill"
        case "flights": return "airplane"
        case "airports": return "mappin.and.ellipse"
        case "fleet": return "airplane.circle.fill"
        case "reach": return "globe"
        case "endurance": return "moon.stars.fill"
        case "distance": return "arrow.left.and.right"
        default: return "rosette"
        }
    }
}

/// The colour a pilot draws their profile in.
///
/// One place for the format, because it is agreed with a database constraint
/// rather than with ourselves: `pilot_profiles.accent` is checked against
/// `^#[0-9a-f]{6}$`, so anything this writes has to be a hash, six digits, and
/// lower case. Reading and writing therefore live together — a parser and an
/// encoder that disagree about the case of `#AABBCC` is a row the server
/// rejects with a constraint violation nobody can read.
///
/// Pro, and enforced on the server: the write guard refuses an accent from a
/// free account, and `pilot_profile_card` stops *serving* the stored value when
/// a subscription lapses rather than clearing it. So somebody who resubscribes
/// gets their colour back, and no client has to remember it for them.
enum PilotAccent {

    /// What the picker offers before anybody reaches for the colour wheel.
    ///
    /// Ten, spread around the wheel, and every one of them chosen to hold up as
    /// a thin ring around a photograph on both a light and a dark ground — which
    /// rules out the very pale and the very dark ends that would disappear into
    /// one or the other. Somebody who wants a colour that is not here can still
    /// have it; this is the shelf, not the fence.
    static let palette: [String] = [
        "#4f8ef7", // azure
        "#3fc1c9", // teal
        "#37c26b", // green
        "#a3c236", // moss
        "#f2b632", // amber
        "#f2762e", // orange
        "#e8484e", // red
        "#e5559b", // pink
        "#a566f0", // violet
        "#8892a6", // slate
    ]

    /// Parsed rather than trusted. A value that is somehow not six hex digits
    /// gets no colour, rather than a crash or a black profile.
    static func color(_ hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The other direction, for the colour wheel. Alpha is dropped on purpose:
    /// the column stores six digits, and a half-transparent ring is not a
    /// choice the profile offers.
    static func hex(_ color: Color) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}

/// The painted banners a profile wears when it has no photograph.
///
/// Everybody gets a banner. Free accounts get to choose one of these, Pro
/// replaces it with a picture — which is a much easier thing to explain than
/// "free profiles have a grey rectangle", and it means a profile never looks
/// broken because somebody has not bought anything.
///
/// Drawn rather than shipped as assets: six gradients cost nothing in the
/// bundle, scale to any width, and are the same in both colour schemes because
/// a banner is its own surface rather than part of the page.
enum BannerPreset: String, CaseIterable, Identifiable {

    case dusk
    case dawn
    case flightLevel = "flight_level"
    case night
    case desert
    case ocean

    var id: String { rawValue }

    static func resolved(_ raw: String?) -> BannerPreset {
        BannerPreset(rawValue: raw ?? "") ?? .dusk
    }

    var label: String {
        switch self {
        case .dusk: return "Dusk"
        case .dawn: return "Dawn"
        case .flightLevel: return "Flight level"
        case .night: return "Night"
        case .desert: return "Desert"
        case .ocean: return "Ocean"
        }
    }

    /// Top-to-bottom, because a banner is read as sky over ground.
    var colours: [Color] {
        switch self {
        case .dusk:
            return [Color(red: 0.17, green: 0.20, blue: 0.42),
                    Color(red: 0.58, green: 0.31, blue: 0.44),
                    Color(red: 0.92, green: 0.55, blue: 0.36)]
        case .dawn:
            return [Color(red: 0.12, green: 0.24, blue: 0.44),
                    Color(red: 0.36, green: 0.55, blue: 0.72),
                    Color(red: 0.98, green: 0.80, blue: 0.60)]
        case .flightLevel:
            return [Color(red: 0.05, green: 0.11, blue: 0.27),
                    Color(red: 0.16, green: 0.35, blue: 0.60),
                    Color(red: 0.62, green: 0.80, blue: 0.93)]
        case .night:
            return [Color(red: 0.03, green: 0.04, blue: 0.12),
                    Color(red: 0.10, green: 0.13, blue: 0.28),
                    Color(red: 0.25, green: 0.28, blue: 0.45)]
        case .desert:
            return [Color(red: 0.42, green: 0.26, blue: 0.16),
                    Color(red: 0.76, green: 0.52, blue: 0.28),
                    Color(red: 0.95, green: 0.83, blue: 0.60)]
        case .ocean:
            return [Color(red: 0.02, green: 0.20, blue: 0.30),
                    Color(red: 0.05, green: 0.42, blue: 0.51),
                    Color(red: 0.44, green: 0.76, blue: 0.75)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colours, startPoint: .top, endPoint: .bottom)
    }
}
