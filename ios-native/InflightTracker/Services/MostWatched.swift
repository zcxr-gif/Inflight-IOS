import Combine
import Foundation

/// The pilots people have opened most today, and the reporting that feeds it.
///
/// ## Where it went
///
/// The web tracker posted a view every time a marker was clicked and showed the
/// top three under the map. The native app was never given either half, so the
/// backend's counter — and the `/most_watched` command in Discord that reads
/// it — went quiet the day the web build stopped being the one people used.
///
/// ## Why reporting is fire-and-forget
///
/// The backend already counts one view per viewer per flight per day, so this
/// needs no bookkeeping to be correct. The set of reported flights is only
/// there to save a request when the same aeroplane is opened, closed and opened
/// again, which is most of how a window gets used.
@MainActor
final class MostWatched: ObservableObject {

    static let shared = MostWatched()

    /// One pilot on today's list.
    struct Entry: Identifiable, Decodable, Equatable {
        let pilotUserId: String?
        let pilotName: String
        let viewCount: Int

        var id: String { pilotUserId ?? pilotName }
    }

    /// How many rows the list shows.
    nonisolated static let limit = 5

    /// The counts move on the scale of minutes; a panel opened twice in a
    /// row should not ask twice.
    private nonisolated static let lifetime: TimeInterval = 60

    @Published private(set) var entries: [Entry] = []

    /// Whether an answer has come back at all, so an empty list can say
    /// "nobody yet" rather than looking like it is still loading.
    @Published private(set) var hasLoaded = false

    private var fetchedAt: Date?
    private var fetching = false
    private var reported: Set<String> = []

    private init() {}

    // MARK: - Reporting

    /// Count an opened aircraft towards today's list.
    ///
    /// Only Infinite Flight traffic, and only with a pilot attached: a real
    /// airliner has nobody to rank, and the backend refuses a view without a
    /// name and account id anyway.
    func report(_ flight: Flight) {
        guard flight.origin == .infiniteFlight,
              let userId = flight.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty,
              let name = flight.username?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !reported.contains(flight.id),
              let url = AppConfig.mostWatchedTrackURL
        else { return }

        reported.insert(flight.id)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "pilotUserId": userId,
            "pilotName": name,
            "flightId": flight.id
        ])

        Task { [weak self] in
            let ok: Bool
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                ok = (200..<300).contains(http.statusCode)
            } else {
                ok = false
            }
            // A failed report is allowed to try again next time the window
            // opens, rather than being remembered as done.
            if !ok { self?.reported.remove(flight.id) }
        }
    }

    // MARK: - Reading

    /// Fetch today's list, unless the one on hand is fresh enough.
    func refresh(force: Bool = false) async {
        if fetching { return }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.lifetime { return }
        guard let url = AppConfig.mostWatchedTopURL(limit: Self.limit) else { return }

        fetching = true
        defer { fetching = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }

        fetchedAt = Date()
        hasLoaded = true
        if decoded != entries { entries = decoded }
    }
}
