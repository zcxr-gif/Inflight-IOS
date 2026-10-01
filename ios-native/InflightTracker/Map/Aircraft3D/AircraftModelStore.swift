import CryptoKit
import Foundation
import UIKit

/// Fetches the 3D aircraft, adapts them, and keeps them on disk.
///
/// Nothing is fetched until an aeroplane of that type is on the map with a
/// source chosen, and then only once: the adapted model is written to Caches
/// and read from there for as long as iOS keeps it. Each model is downloaded
/// from the repository its authors publish it in — the app ships none of them,
/// see `AircraftModelSource`.
///
/// Main-thread state throughout, like the map's other stores; the download
/// and the rewrite happen off it.
final class AircraftModelStore {

    static let shared = AircraftModelStore()

    struct Ready: Equatable {
        let entry: AircraftModelCatalog.Entry
        let file: URL
        /// The aeroplane's real length. The file itself is one unit long.
        let lengthMetres: Double
    }

    private enum State {
        case loading
        case ready(Ready)
        case failed(at: Date)
    }

    private var states: [AircraftModelCatalog.Entry: State] = [:]
    private var queue: [AircraftModelCatalog.Entry] = []
    private var running = 0
    private static let concurrent = 2

    /// How long a model that failed is left alone before it is tried again.
    private static let retryAfter: TimeInterval = 600

    private var observers: [ObjectIdentifier: (Ready) -> Void] = [:]

    // MARK: - Asking

    /// The model, if it is on disk and adapted. Otherwise starts getting it
    /// and returns nil; observers hear when it lands.
    func ready(_ entry: AircraftModelCatalog.Entry) -> Ready? {
        switch states[entry] {
        case .ready(let ready):
            return ready
        case .loading:
            return nil
        case .failed(let at) where Date().timeIntervalSince(at) < Self.retryAfter:
            return nil
        case .failed, .none:
            if let cached = cached(entry) {
                states[entry] = .ready(cached)
                return cached
            }
            states[entry] = .loading
            queue.append(entry)
            pump()
            return nil
        }
    }

    func observe(_ owner: AnyObject, _ handler: @escaping (Ready) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func stopObserving(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    // MARK: - Fetching

    private func pump() {
        while running < Self.concurrent, !queue.isEmpty {
            let entry = queue.removeFirst()
            running += 1
            Task {
                let result = await Self.fetch(entry)
                // Back on the main thread, through the one instance there is.
                DispatchQueue.main.async { AircraftModelStore.shared.finish(entry, result) }
            }
        }
    }

    private func finish(_ entry: AircraftModelCatalog.Entry, _ result: Result<Ready, Error>) {
        running -= 1
        switch result {
        case .success(let ready):
            states[entry] = .ready(ready)
            for observer in observers.values { observer(ready) }
        case .failure(let error):
            NSLog("[Models] %@ failed: %@", entry.styleId, String(describing: error))
            states[entry] = .failed(at: Date())
        }
        pump()
    }

    private static func fetch(_ entry: AircraftModelCatalog.Entry) async -> Result<Ready, Error> {
        do {
            let url: URL
            var expectedHash: String?
            if let direct = entry.url {
                url = direct
            } else {
                let file = try await SkytrailsManifest.shared.file(for: entry.id)
                url = file.url
                expectedHash = file.sha256
            }

            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            if let expectedHash {
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expectedHash.lowercased() else { throw URLError(.cannotDecodeContentData) }
            }

            let notice = "Adapted on this device by Inflight from \(url.absoluteString) "
                + "(\(entry.licence)): node transforms baked in, turned to face −Z with +Y up, centred, "
                + "scaled to one unit long, glTF 1.0 read as 2.0 where needed, repacked as tightly packed "
                + "floats with 16-bit indices, materials reduced to base colour, transparency and emission."
            let output = try await Task.detached(priority: .utility) {
                try GLBNormaliser.normalise(data, forward: entry.forward, up: entry.up, notice: notice)
            }.value

            let file = Self.file(for: entry)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try output.data.write(to: file, options: .atomic)
            let info = ["length": output.lengthMetres]
            try JSONSerialization.data(withJSONObject: info).write(to: Self.infoFile(for: entry), options: .atomic)
            return .success(Ready(entry: entry, file: file, lengthMetres: output.lengthMetres))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Not crashing twice

    /// The setting the map control writes.
    static let settingKey = "map.aircraftModels"

    /// Set while 3D models are on the map and the app is in front; cleared
    /// when it goes to the background. Still set at launch means the last
    /// session ended with models on screen and without going to the
    /// background — which is to say it crashed — and the models are turned
    /// off, so a model that brings the app down cannot do it on every launch.
    private static let armedKey = "map.aircraftModels.armed"

    /// Once per version of the adapted models: the first builds wrote models
    /// that could exhaust the phone's memory, so the setting starts at Off.
    private static let resetKey = "map.aircraftModels.reset.v\(GLBNormaliser.version)"

    private static var isArmed = false
    private static var lifecycleObservers: [NSObjectProtocol] = []

    /// Call at launch, before anything reads the setting.
    static func recoverFromCrashIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: resetKey) {
            defaults.set(true, forKey: resetKey)
            defaults.set(AircraftModelSource.off.rawValue, forKey: settingKey)
            // Models written by older versions of the pass are never read again.
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AircraftModels", isDirectory: true)
            for old in 1..<GLBNormaliser.version {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("v\(old)", isDirectory: true))
            }
        }
        if defaults.bool(forKey: armedKey) {
            NSLog("[Models] the last session ended while 3D aircraft were on the map; turning them off")
            defaults.set(false, forKey: armedKey)
            defaults.set(AircraftModelSource.off.rawValue, forKey: settingKey)
        }
    }

    /// Called when a model goes onto the map.
    static func armCrashGuard() {
        guard !isArmed else { return }
        isArmed = true
        UserDefaults.standard.set(true, forKey: armedKey)

        guard lifecycleObservers.isEmpty else { return }
        let centre = NotificationCenter.default
        lifecycleObservers = [
            centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                UserDefaults.standard.set(false, forKey: armedKey)
            },
            centre.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                if isArmed { UserDefaults.standard.set(true, forKey: armedKey) }
            },
        ]
    }

    /// Called when the models are switched off.
    static func disarmCrashGuard() {
        isArmed = false
        UserDefaults.standard.set(false, forKey: armedKey)
    }

    // MARK: - The cache

    private func cached(_ entry: AircraftModelCatalog.Entry) -> Ready? {
        let file = Self.file(for: entry)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: Self.infoFile(for: entry)),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let length = info["length"] as? Double, length > 0 else { return nil }
        return Ready(entry: entry, file: file, lengthMetres: length)
    }

    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("AircraftModels/v\(GLBNormaliser.version)", isDirectory: true)
    }

    private static func file(for entry: AircraftModelCatalog.Entry) -> URL {
        directory.appendingPathComponent(entry.source.key).appendingPathComponent("\(entry.id).glb")
    }

    private static func infoFile(for entry: AircraftModelCatalog.Entry) -> URL {
        directory.appendingPathComponent(entry.source.key).appendingPathComponent("\(entry.id).json")
    }
}

/// The Skytrails release manifest, which names each model's file.
///
/// The repository asks apps to follow its latest release rather than pin one,
/// and its file names carry a hash, so the manifest is the only way to them.
/// Fetched once a session.
private actor SkytrailsManifest {

    static let shared = SkytrailsManifest()

    private static let base = URL(string: "https://github.com/stagworksde/skytrails-aircraft-models/releases/latest/download/")!

    private var models: [String: [String: Any]]?
    private var loading: Task<[String: [String: Any]], Error>?

    func file(for id: String) async throws -> (url: URL, sha256: String?) {
        let models = try await load()
        guard let model = models[id], let name = model["file"] as? String,
              let url = URL(string: name, relativeTo: Self.base) else {
            throw URLError(.fileDoesNotExist)
        }
        return (url.absoluteURL, model["sha256"] as? String)
    }

    private func load() async throws -> [String: [String: Any]] {
        if let models { return models }
        if let loading { return try await loading.value }
        let task = Task<[String: [String: Any]], Error> {
            let (data, _) = try await URLSession.shared.data(from: Self.base.appendingPathComponent("manifest.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [String: [String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            return models
        }
        loading = task
        do {
            let loaded = try await task.value
            models = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }
}
