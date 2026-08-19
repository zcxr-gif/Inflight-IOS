import Foundation

/// Every link that opens the app at something in particular.
///
/// Two forms of the same thing, and the distinction matters:
///
/// * `url` is `inflight://open?flight=…`, a private scheme. It is what a widget
///   tile writes, because a widget is already on this device and a tap on it
///   can only ever mean this app. It is useless to anybody else — a person
///   without the app who taps one gets an error, not a web page.
/// * `webURL` is `https://inflight.info/…`, the address the website already
///   serves. It is what the app *shares*, because a shared link goes to
///   somebody whose phone we know nothing about. With the associated-domains
///   entitlement (`Support/InflightTracker.entitlements`) iOS hands that URL
///   straight to the app when it is installed and opens Safari when it is not,
///   so one link is right for both.
///
/// `parse` accepts either, which is what makes the second half work: the app
/// receives the https link through `NSUserActivity` and resolves it here rather
/// than anywhere having to know that a shared link and a widget link are the
/// same journey.
///
/// Query parameters rather than path components on the private scheme, on
/// purpose. A flight's id comes from the feed and is whatever the backend says
/// it is; putting an arbitrary string in a path means worrying about slashes
/// and percent-encoding at both ends, and `URLComponents` handles a query item
/// correctly without anyone having to think about it.
public enum InflightLink: Equatable {

    public static let scheme = "inflight"
    private static let host = "open"

    /// The site the shareable form of these links lives on, and the domain the
    /// entitlement claims. Bare and `www`, because both resolve and people
    /// paste both.
    public static let webHost = "inflight.info"
    private static let webHosts: Set<String> = ["inflight.info", "www.inflight.info"]

    /// What may go into a single path component untouched.
    ///
    /// `urlPathAllowed` on its own is the wrong set here: it permits `/`,
    /// because it is meant for a whole path. A feed id is one component, and an
    /// id that happened to contain a slash would silently become two — a URL
    /// that no longer parses back to the flight it was built from.
    private static let pathComponentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    /// One aircraft, by feed id.
    case flight(id: String)

    /// One field, by ICAO.
    case airport(icao: String)

    /// One pilot's public profile, by handle.
    case pilot(handle: String)

    /// A toolbar panel, for the tiles that are about a list rather than a thing.
    case panel(String)

    // MARK: - Building

    /// The private-scheme form. Always available; only useful on this device.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host

        switch self {
        case .flight(let id):
            components.queryItems = [URLQueryItem(name: "flight", value: id)]
        case .airport(let icao):
            components.queryItems = [URLQueryItem(name: "airport", value: icao.uppercased())]
        case .pilot(let handle):
            components.queryItems = [URLQueryItem(name: "pilot", value: Self.normalised(handle))]
        case .panel(let name):
            components.queryItems = [URLQueryItem(name: "panel", value: name)]
        }

        return components.url
    }

    /// The public form — the one to hand to another person.
    ///
    /// `nil` for the cases the website has no page for. A panel is a piece of
    /// this app's furniture and there is nothing on the web that corresponds to
    /// it; an airport has no permalink on the site yet. Returning nil rather
    /// than inventing an address means a share button for one of those is
    /// absent instead of broken.
    public var webURL: URL? {
        switch self {
        case .flight(let id):
            // `/share/<id>` is the site's flight permalink: it unfurls with the
            // real callsign, route and photo in a chat app, and sends a human
            // on to the live map.
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed),
                  !encoded.isEmpty else { return nil }
            return URL(string: "https://\(Self.webHost)/share/\(encoded)")

        case .pilot(let handle):
            let normalised = Self.normalised(handle)
            guard !normalised.isEmpty,
                  let encoded = normalised.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowed)
            else { return nil }
            return URL(string: "https://\(Self.webHost)/pilot/\(encoded)")

        case .airport, .panel:
            return nil
        }
    }

    // MARK: - Reading

    /// Resolves either form. Anything else is `nil`, including an https URL on
    /// one of our hosts whose path we do not recognise.
    ///
    /// That last case is not hypothetical. The entitlement claims the domain,
    /// not a list of paths — only the site's `apple-app-site-association` file
    /// can narrow it — so until that file is written iOS may hand this app any
    /// inflight.info address at all, `/crew/…` and `/terms` included. `nil` is
    /// the honest answer for those, and the caller opens them in the browser
    /// rather than leaving somebody staring at a map that did not move.
    public static func parse(_ url: URL) -> InflightLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let urlScheme = url.scheme?.lowercased()

        if urlScheme == scheme { return parsePrivate(components) }
        if urlScheme == "https" { return parseWeb(url, components) }
        return nil
    }

    private static func parsePrivate(_ components: URLComponents) -> InflightLink? {
        guard let items = components.queryItems else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if let id = value("flight") { return .flight(id: id) }
        if let icao = value("airport") { return .airport(icao: icao.uppercased()) }
        if let handle = value("pilot") { return .pilot(handle: normalised(handle)) }
        if let panel = value("panel") { return .panel(panel) }
        return nil
    }

    /// The website's own addresses, read back.
    ///
    /// `/share/<id>` and `/?flight=<id>` are both live — the first is the older
    /// permalink and the second is what the web build hands out today — so both
    /// resolve here. A link that has been through a chat app arrives with
    /// tracking parameters and a trailing slash often enough that neither is
    /// worth being strict about.
    private static func parseWeb(_ url: URL, _ components: URLComponents) -> InflightLink? {
        guard let host = url.host?.lowercased(), webHosts.contains(host) else { return nil }

        let path = components.path.split(separator: "/").map(String.init)

        if path.count >= 2, path[0].lowercased() == "share" {
            return .flight(id: path[1])
        }

        if path.count >= 2, path[0].lowercased() == "pilot" {
            return .pilot(handle: normalised(path[1]))
        }

        if path.isEmpty, let id = components.queryItems?.first(where: { $0.name == "flight" })?.value,
           !id.isEmpty {
            return .flight(id: id)
        }

        return nil
    }

    /// A handle as the profile tables store it: no leading `@`, lower case.
    /// Applied on the way in and on the way out, so `@Rey`, `rey` and a link
    /// somebody typed by hand all reach the same profile.
    private static func normalised(_ handle: String) -> String {
        var trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }
        return trimmed.lowercased()
    }
}
