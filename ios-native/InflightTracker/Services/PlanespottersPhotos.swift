import Foundation
import UIKit

/// A photograph of one real aircraft, from Planespotters.
///
/// Every field here exists because their terms require it to reach the screen.
/// See `PlanespottersPhotos` for the rules in full; the short version is that a
/// picture may not be shown without the photographer's name beside it and a way
/// to open the original.
struct PlanespottersPhoto: Equatable {

    /// The large thumbnail, used exactly as returned. Their terms forbid
    /// proxying, rewriting or re-hosting any URL the API hands back, so this is
    /// carried around whole rather than picked apart and rebuilt.
    let imageURL: URL

    /// The photo's own page. The picture has to lead here, in one action, by a
    /// route the viewer can actually discover.
    let link: URL

    /// Whose photograph it is. Never optional: a picture whose photographer we
    /// could not read is a picture we are not allowed to draw, so the parse
    /// drops it rather than showing it uncredited.
    let photographer: String
}

/// The photo lookup for real-world aircraft.
///
/// ## Why this is its own service
///
/// `AircraftPhotoService` answers a different question — it is Infinite
/// Flight's community photographs of a *type in a livery*, several of them, from
/// our own backend. This is one photograph of one airframe, from somebody
/// else's, under terms that govern how it may be shown. Folding the two
/// together would mean one cache, one loader and one set of rules for two
/// things that share neither.
///
/// ## The terms, and where each one is kept
///
/// These are conditions of use rather than preferences, so they are written
/// down beside the code that honours them:
///
/// - **Never a paid feature.** The photograph is drawn for every account, Pro
///   or not, at the same size. Nothing here consults `Entitlements`, and
///   nothing should be added that does.
/// - **The photographer is credited beside the picture**, in visible text.
/// - **The picture leads back to its page** at Planespotters, using the `link`
///   the API returned, reachable in one obvious action.
/// - **A descriptive User-Agent with a contact address.** An iOS app is a
///   non-browser client by their rules, so it identifies itself rather than
///   pretending to be a browser — see `AppConfig.publicAPIUserAgent`.
/// - **JSON may be cached for up to 24 hours.** This holds it for six, in
///   memory.
/// - **Image binaries are fetched straight from the returned URL by the device
///   that displays them, and not written to storage.** That is what
///   `PlanespottersImageLoader` is for, and why it does not use
///   `RemoteImageLoader`: the shared loader keeps sixty decoded images in a
///   static cache and runs through `URLSession.shared`, whose default
///   `URLCache` writes to disk. Neither is allowed here.
/// - **URLs are used unchanged.** No proxying, no rewriting.
/// - **Not used to train anything.** There is no pipeline here that could.
/// - **Not re-exposed.** The app has no API of its own and publishes none of
///   this.
final class PlanespottersPhotos {

    static let shared = PlanespottersPhotos()

    /// What one lookup came back with, and when.
    ///
    /// A miss is cached as well as a hit — most light aircraft have never been
    /// photographed, and re-asking for every one of them every time a window
    /// opens is exactly the "sustained or bursty traffic" their terms reserve
    /// the right to throttle.
    private struct Entry {
        let photo: PlanespottersPhoto?
        let at: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    /// A session that writes nothing to disk.
    ///
    /// `.ephemeral` keeps its cache, its cookies and its credentials in memory
    /// for the life of the session, and the cache is then removed outright:
    /// their terms allow an image to be held for as long as it is on screen and
    /// no longer, which a disk cache plainly breaks.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": AppConfig.publicAPIUserAgent]
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    private init() {}

    /// The image session, shared with the loader so both obey the same rules.
    var imageSession: URLSession { session }

    /// The photograph for one aircraft, by hex with the registration as the
    /// fallback.
    ///
    /// `completion` always lands on the main thread, and is handed nil for "no
    /// photograph", which is an ordinary answer rather than a failure.
    func photo(
        hex: String?,
        registration: String?,
        completion: @escaping (PlanespottersPhoto?) -> Void
    ) {
        // Keyed on BOTH identifiers rather than on whichever one came first.
        //
        // A contact is usually heard before the aggregator has matched it to an
        // airframe, so the same aeroplane gets asked about twice: once on the
        // Mode S address alone, and again a sweep or two later once a tail
        // number has landed. Keyed on the address, that second ask was answered
        // out of the cache with the first one's empty result — and the
        // registration fallback below, which is the entire reason for asking
        // again, was never reached. Two identifiers are two questions.
        let identity = [hex, registration].compactMap { $0 }.filter { !$0.isEmpty }
        guard !identity.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let key = identity.joined(separator: "|").lowercased()

        if let entry = cache[key],
           Date().timeIntervalSince(entry.at) < AppConfig.aircraftPhotoLifetime {
            DispatchQueue.main.async { completion(entry.photo) }
            return
        }

        // Already being asked for — by the peak and the open window at once,
        // which both want the same picture. Answered from the cache a moment
        // later rather than fetched twice.
        guard !inFlight.contains(key) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // The hex identifies the airframe and the registration only names it,
        // so the hex is tried first and the registration is what happens when
        // their database has never heard of the address.
        let first = hex.flatMap { AppConfig.aircraftPhotoURL(hex: $0) }
        let second = registration.flatMap { AppConfig.aircraftPhotoURL(registration: $0) }

        guard let url = first ?? second else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        inFlight.insert(key)

        fetch(url) { [weak self] photo in
            guard let self = self else { return }

            if photo == nil, first != nil, let fallback = second {
                self.fetch(fallback) { second in
                    self.finish(key: key, photo: second, completion: completion)
                }
                return
            }

            self.finish(key: key, photo: photo, completion: completion)
        }
    }

    private func finish(
        key: String,
        photo: PlanespottersPhoto?,
        completion: @escaping (PlanespottersPhoto?) -> Void
    ) {
        DispatchQueue.main.async {
            self.inFlight.remove(key)
            self.cache[key] = Entry(photo: photo, at: Date())
            // Bounded purely as a safety net. A long session over a busy
            // continent could otherwise accumulate an entry per airframe seen.
            if self.cache.count > 600 { self.cache.removeAll(keepingCapacity: true) }
            completion(photo)
        }
    }

    private func fetch(_ url: URL, completion: @escaping (PlanespottersPhoto?) -> Void) {
        session.dataTask(with: url) { data, _, _ in
            completion(Self.decode(data))
        }.resume()
    }

    /// Reads one photo out of the response, and refuses anything it cannot show
    /// within the terms.
    ///
    /// The photographer and the link are both required rather than optional:
    /// without either, the picture could not be credited or led back to, and a
    /// picture that cannot be is one this app has no right to draw. So a
    /// response missing them reads as "no photograph" rather than as a
    /// photograph with a gap in it.
    private static func decode(_ data: Data?) -> PlanespottersPhoto? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil,
              let photos = root["photos"] as? [Any],
              let first = photos.first as? [String: Any]
        else { return nil }

        // The large thumbnail: 280 points tall, a few hundred wide. The right
        // size for a window header, and the only other one they offer is a
        // 200-pixel strip.
        let large = first["thumbnail_large"] as? [String: Any]
        let small = first["thumbnail"] as? [String: Any]
        let source = (large?["src"] as? String) ?? (small?["src"] as? String)

        guard let source = source,
              let imageURL = URL(string: source),
              let link = (first["link"] as? String).flatMap(URL.init(string:)),
              let photographer = (first["photographer"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !photographer.isEmpty
        else { return nil }

        return PlanespottersPhoto(imageURL: imageURL, link: link, photographer: photographer)
    }
}

/// Holds one Planespotters image for exactly as long as it is on screen.
///
/// Deliberately not `RemoteImageLoader`, which keeps sixty decoded images in a
/// static cache and fetches through `URLSession.shared` — a session whose
/// default `URLCache` writes to disk. Their terms allow an image to be held
/// while it is displayed and no longer, and forbid writing it to storage, so
/// this keeps exactly one, in memory, owned by the view that is showing it, and
/// lets go of it when that view goes.
final class PlanespottersImageLoader: ObservableObject {

    @Published private(set) var image: UIImage?

    private var requested: URL?
    private var task: URLSessionDataTask?

    func load(_ url: URL?) {
        guard requested != url else { return }
        requested = url

        task?.cancel()
        task = nil
        image = nil

        guard let url = url else { return }

        // The same no-disk session the lookup uses — see `PlanespottersPhotos`.
        let task = PlanespottersPhotos.shared.imageSession.dataTask(with: url) {
            [weak self] data, _, _ in
            guard let data = data, let decoded = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.requested == url else { return }
                self.image = decoded
            }
        }

        self.task = task
        task.resume()
    }

    deinit {
        task?.cancel()
    }
}
