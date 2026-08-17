import Foundation

/// A field's ATIS, when somebody is running one.
///
/// Addressed by session like the flight plan is, so it goes through
/// `SessionService` first — which by the time a field panel opens has almost
/// always already resolved for something else.
///
/// Nil is the usual answer: an ATIS only exists while a controller is working
/// the field and has switched one on. That is cached like any other answer, for
/// a couple of minutes, because a panel left open re-asks on its own clock.
final class AtisService {

    static let shared = AtisService()

    private struct Entry {
        let atis: Atis?
        let fetched: Date
    }

    private var cache: [String: Entry] = [:]
    private var waiting: [String: [(Atis?) -> Void]] = [:]
    private let lock = NSLock()

    /// Short: an ATIS is reissued whenever conditions change, and a stale
    /// information letter is worse than none.
    private let lifetime: TimeInterval = 120

    private init() {}

    func cached(_ icao: String, server: String) -> Atis? {
        lock.lock()
        defer { lock.unlock() }
        return cache[Self.key(icao, server)]?.atis
    }

    /// `completion` runs on the main thread.
    func atis(for icao: String, server: String, completion: @escaping (Atis?) -> Void) {
        let code = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 4 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let key = Self.key(code, server)

        lock.lock()
        if let entry = cache[key], Date().timeIntervalSince(entry.fetched) < lifetime {
            let atis = entry.atis
            lock.unlock()
            DispatchQueue.main.async { completion(atis) }
            return
        }

        if waiting[key] != nil {
            waiting[key]?.append(completion)
            lock.unlock()
            return
        }
        waiting[key] = [completion]
        lock.unlock()

        SessionService.shared.sessionId(for: server) { [weak self] sessionId in
            guard let self = self else { return }

            guard let sessionId = sessionId,
                  let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "\(AppConfig.socketURLString)/api/live/airport/\(encoded)/\(code)/atis")
            else {
                self.finish(key: key, atis: nil, cache: false)
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12

            URLSession.shared.dataTask(with: request) { data, _, _ in
                let atis = data.flatMap { Self.decode($0) }
                self.finish(key: key, atis: atis, cache: true)
            }
            .resume()
        }
    }

    private func finish(key: String, atis: Atis?, cache shouldCache: Bool) {
        lock.lock()
        if shouldCache {
            cache[key] = Entry(atis: atis, fetched: Date())
        }
        let waiters = waiting.removeValue(forKey: key) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for waiter in waiters { waiter(atis) }
        }
    }

    /// Keyed by server as well as field: the same airport can have a different
    /// controller and a different ATIS on Expert and on Training.
    private static func key(_ icao: String, _ server: String) -> String {
        "\(server)|\(icao.uppercased())"
    }

    private struct Envelope: Decodable {
        let ok: Bool?
        let atis: String?
    }

    private static func decode(_ data: Data) -> Atis? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.ok != false else { return nil }
        return Atis(envelope.atis)
    }
}
