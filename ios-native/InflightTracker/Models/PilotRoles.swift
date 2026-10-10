import SwiftUI

/// Who a pilot is, beyond their grade: one of Inflight's own moderators, or an
/// Infinite Flight air traffic controller.
///
/// Both are drawn the same two ways — a colour on the map, and a small badge in
/// the flight window — and each has its own switch under Settings › Layers.
enum PilotRole: Equatable {

    /// Inflight's own team. Light blue.
    case moderator

    /// IFATC: an Infinite Flight account with an ATC rank above Observer. Dark
    /// green.
    case controller

    var badge: String {
        switch self {
        case .moderator: return "MOD"
        case .controller: return "IFATC"
        }
    }

    var detail: String {
        switch self {
        case .moderator: return "Inflight moderator"
        case .controller: return "Infinite Flight air traffic controller"
        }
    }

    /// `#7dd3fc` — light blue for the team.
    static let moderatorColour = Color(red: 0x7d / 255, green: 0xd3 / 255, blue: 0xfc / 255)

    /// `#1f8a4c` — a dark-ish green for controllers.
    static let controllerColour = Color(red: 0x1f / 255, green: 0x8a / 255, blue: 0x4c / 255)

    var colour: Color {
        switch self {
        case .moderator: return Self.moderatorColour
        case .controller: return Self.controllerColour
        }
    }

    /// Inflight's moderators, by Infinite Flight username, lowercased.
    static let moderators: Set<String> = [
        "eggs_aviation",
        "randomaviator2",
        "hilo",
        "_servernoob",
    ]

    static func isModerator(_ username: String?) -> Bool {
        guard let key = username?.lowercased(), !key.isEmpty else { return false }
        return moderators.contains(key)
    }

    /// Infinite Flight's ATC ranks run from 0, Observer, upwards. Anything
    /// above it is a controller.
    static func isController(atcRank: Int?) -> Bool {
        (atcRank ?? 0) >= 1
    }

    /// The roles to badge a pilot with, moderator first.
    static func roles(username: String?, atcRank: Int?) -> [PilotRole] {
        var roles: [PilotRole] = []
        if isModerator(username) { roles.append(.moderator) }
        if isController(atcRank: atcRank) { roles.append(.controller) }
        return roles
    }
}

/// A role as a small capsule: "MOD" or "IFATC" in the role's colour.
struct PilotRoleBadge: View {

    let role: PilotRole

    /// Whether it sits on something dark — a banner under a scrim — where the
    /// role's own colour reads as it is.
    var isLight = false

    var body: some View {
        Text(L(role.badge))
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background { Capsule().fill(role.colour.opacity(isLight ? 0.18 : 0.22)) }
            .overlay { Capsule().strokeBorder(role.colour.opacity(0.6), lineWidth: 1) }
            .fixedSize()
            .accessibilityLabel(L(role.detail))
    }

    /// The light blue is pale enough to vanish on white, and the green dark
    /// enough to vanish on night, so each is moved towards the side it is on.
    private var ink: Color {
        switch (role, isLight) {
        case (.moderator, true): return Color(red: 0x03 / 255, green: 0x69 / 255, blue: 0xa1 / 255)
        case (.controller, false): return Color(red: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255)
        default: return role.colour
        }
    }
}

/// Which pilots in the air are IFATC.
///
/// The feed sends who is flying but not what they are, so this asks the
/// backend's batch lookup — the Live API's `/users`, which carries each
/// account's `atcRank` — about every account it has not seen, twenty-five at a
/// time, and remembers the answer for a few days. Ranks change a few times a
/// year; asking once per pilot per few days is plenty.
///
/// Only runs while the IFATC colour is switched on, and publishes in steps
/// rather than per batch: every change repaints every aeroplane on the map.
@MainActor
final class ControllerDirectory: ObservableObject {

    static let shared = ControllerDirectory()

    /// Lowercased usernames of the controllers seen so far.
    @Published private(set) var controllerNames: Set<String> = []

    private struct Entry: Codable {
        let rank: Int
        let name: String
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var namesById: [String: String] = [:]
    private var worker: Task<Void, Never>?
    private var lastPublish = Date.distantPast

    /// Set when a lookup fails, so a backend that is down is not asked about
    /// the whole server again on every packet.
    private var retryAfter = Date.distantPast

    private static let storeKey = "controllerDirectory.v1"
    private static let lifetime: TimeInterval = 3 * 24 * 3600
    private static let batchSize = 25
    private static let pause: Duration = .milliseconds(600)
    private static let publishInterval: TimeInterval = 4

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored.filter { Date().timeIntervalSince($0.value.at) < Self.lifetime }
        }
        controllerNames = Self.names(in: entries)
    }

    /// Queues every pilot in this packet the directory does not know yet.
    func note(flights: [Flight]) {
        for flight in flights where !Flight.isRealWorld(id: flight.id) {
            guard let id = flight.userId, !id.isEmpty else { continue }
            if let name = flight.username, !name.isEmpty { namesById[id] = name }
            guard entries[id] == nil, !queued.contains(id) else { continue }
            queued.insert(id)
            queue.append(id)
        }
        guard worker == nil, !queue.isEmpty, Date() >= retryAfter else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let batch = Array(queue.prefix(Self.batchSize))
            queue.removeFirst(batch.count)

            guard let answers = await Self.lookup(batch) else {
                // Down, or answering something this cannot read: everything
                // waiting is let go and asked about again in a few minutes.
                queue.removeAll()
                queued.removeAll()
                retryAfter = Date().addingTimeInterval(5 * 60)
                break
            }
            let now = Date()
            for id in batch {
                let answer = answers[id]
                let name = namesById[id] ?? answer?.name ?? ""
                entries[id] = Entry(rank: answer?.rank ?? 0, name: name, at: now)
            }
            batch.forEach { queued.remove($0) }

            if queue.isEmpty || Date().timeIntervalSince(lastPublish) > Self.publishInterval {
                publish()
            }
            try? await Task.sleep(for: Self.pause)
        }
        publish()
        worker = nil
    }

    /// What is known of one pilot's rank, by the name they fly under. Nil when
    /// they have not been looked up.
    func rank(forUsername username: String?) -> Int? {
        guard let key = username?.lowercased(), !key.isEmpty else { return nil }
        return entries.values.first { $0.name.lowercased() == key }?.rank
    }

    private func publish() {
        lastPublish = Date()
        let names = Self.names(in: entries)
        if names != controllerNames { controllerNames = names }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private static func names(in entries: [String: Entry]) -> Set<String> {
        Set(entries.values.filter { PilotRole.isController(atcRank: $0.rank) && !$0.name.isEmpty }
            .map { $0.name.lowercased() })
    }

    /// One batch: account id → rank and name. Nil when the request failed.
    private static func lookup(_ ids: [String]) async -> [String: (rank: Int, name: String?)]? {
        guard let url = URL(string: "\(AppConfig.socketURLString)/users") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["userIds": ids])
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // The proxy answers `{ users: [...] }`; the Live API itself answers
        // `{ result: [...] }`. Either, or a bare array.
        let rows: [[String: Any]]
        if let object = json as? [String: Any] {
            rows = (object["users"] as? [[String: Any]]) ?? (object["result"] as? [[String: Any]]) ?? []
        } else {
            rows = (json as? [[String: Any]]) ?? []
        }

        var answers: [String: (rank: Int, name: String?)] = [:]
        for row in rows {
            guard let id = row["userId"] as? String else { continue }
            let rank = (row["atcRank"] as? NSNumber)?.intValue ?? 0
            answers[id] = (rank, row["discourseUsername"] as? String)
        }
        // Nothing recognisable at all is a failure, not a server with no
        // controllers on it — caching it would hide them for days.
        return answers.isEmpty ? nil : answers
    }
}
