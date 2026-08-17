import Foundation

/// Resolves the Infinite Flight session id for a server name.
///
/// Several of the backend's endpoints are addressed by session rather than by
/// server — the filed flight plan, a field's ATIS — and the id changes when the
/// simulator's servers roll. The web build resolved it the same way
/// (`old/www/flight.js` -> `getValidSessionId`) and cached it for five minutes;
/// so does this, per server, because switching servers must not hand the new
/// one the old one's id.
final class SessionService {

    static let shared = SessionService()

    private struct Entry {
        let id: String
        let fetched: Date
    }

    private var cache: [String: Entry] = [:]
    private var waiting: [String: [(String?) -> Void]] = [:]
    private let lock = NSLock()

    /// Five minutes, as the web build used. A session lasts hours, so this is
    /// about not asking on every panel rather than about staying current.
    private let lifetime: TimeInterval = 300

    private init() {}

    /// `completion` runs on the main thread with the session id, or nil when
    /// the server has no session the backend recognises.
    ///
    /// Nil is not cached: a failed lookup is usually the network rather than an
    /// answer, and the next panel to ask should get a fresh try rather than
    /// five minutes of the same silence.
    func sessionId(for server: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        if let entry = cache[server], Date().timeIntervalSince(entry.fetched) < lifetime {
            let id = entry.id
            lock.unlock()
            DispatchQueue.main.async { completion(id) }
            return
        }

        if waiting[server] != nil {
            waiting[server]?.append(completion)
            lock.unlock()
            return
        }
        waiting[server] = [completion]
        lock.unlock()

        guard let url = URL(string: "\(AppConfig.socketURLString)/if-sessions") else {
            finish(server: server, id: nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let id = data.flatMap { Self.session(named: server, in: $0) }
            self?.finish(server: server, id: id)
        }
        .resume()
    }

    private func finish(server: String, id: String?) {
        lock.lock()
        if let id = id {
            cache[server] = Entry(id: id, fetched: Date())
        }
        let waiters = waiting.removeValue(forKey: server) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for waiter in waiters { waiter(id) }
        }
    }

    private struct Envelope: Decodable {
        struct Session: Decodable {
            let id: String?
            let name: String?
        }
        let sessions: [Session]?
    }

    /// Exact name first, then the first word of it — the backend has called the
    /// same server both "Expert Server" and "Expert", and the app's own list
    /// says "Expert Server".
    private static func session(named server: String, in data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let sessions = envelope.sessions else { return nil }

        let wanted = server.lowercased()

        if let exact = sessions.first(where: { $0.name?.lowercased() == wanted }) {
            return exact.id
        }

        guard let stem = wanted.split(separator: " ").first else { return nil }
        return sessions.first { $0.name?.lowercased().contains(stem) == true }?.id
    }
}
