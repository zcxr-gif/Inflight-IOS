import Combine
import Foundation

/// A field's stand *names*, from the backend's own dataset.
///
/// Not a second `GateStore`, and not a replacement for one. `GateStore` answers
/// "where is B24", which is what the map needs and what the field panel uses to
/// work out which stands are occupied. This answers the weaker question —
/// "what are this field's stands called" — for the fields where nobody has an
/// answer to the first one.
///
/// ## Why both exist
///
/// OpenStreetMap's coverage of aprons is excellent at large European fields and
/// thin almost everywhere else, and a gate picker that is empty at half the
/// world's airports is a gate picker people stop opening. The backend has
/// carried a community stand list since the web tracker — `/api/gates/:icao`,
/// which its own gate board falls back to when every Overpass mirror refuses —
/// and those rows are names, imported from somebody's export, with no
/// coordinates on them.
///
/// So: the map when the field is mapped, the list when it is not, and the app
/// says which it is looking at rather than presenting a name-only list as if it
/// were a survey.
///
/// Fetched per field, on demand, and kept for the session. Deliberately *not*
/// written to disk, unlike `GateStore`: this is a small request to our own
/// backend rather than a polite ration of somebody's donated Overpass mirror,
/// and the dataset behind it is edited far more often than a terminal is
/// rebuilt.
@MainActor
final class StandDirectory: ObservableObject {

    static let shared = StandDirectory()

    enum State: Equatable {
        case idle
        case loading
        /// Stand names in the field's own order. May legitimately be empty:
        /// plenty of fields are not in the dataset either, and that is an
        /// answer rather than a failure.
        case ready([String])
        case failed
    }

    @Published private(set) var states: [String: State] = [:]

    private var inFlight: Set<String> = []

    private init() {}

    func state(for icao: String) -> State { states[icao.uppercased()] ?? .idle }

    func names(for icao: String) -> [String] {
        if case .ready(let names) = state(for: icao) { return names }
        return []
    }

    /// Safe to call on every appearance: a field already asked about does
    /// nothing.
    func load(_ icao: String) {
        let code = icao.uppercased()

        switch state(for: code) {
        case .ready, .loading, .failed: return
        case .idle: break
        }
        guard !inFlight.contains(code), let url = AppConfig.airportGatesURL(icao: code) else {
            return
        }

        inFlight.insert(code)
        states[code] = .loading

        Task { [weak self] in
            let names = await Self.fetch(url)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.inFlight.remove(code)
                // A 404 is the backend saying it has never heard of this field,
                // which is an answer — an empty list — rather than a failure to
                // ask. Only a transport error or an unreadable body is `failed`.
                self.states[code] = names.map(State.ready) ?? .failed
            }
        }
    }

    /// Nil means the lookup itself failed. An empty array means the dataset has
    /// nothing for this field.
    private static func fetch(_ url: URL) async -> [String]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return [] }
        guard (200..<300).contains(status) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        return parse(root)
    }

    /// Reads whichever shape the dataset happens to be in for this field.
    ///
    /// Three of them are in there, because the import route takes whatever
    /// somebody uploads: a bare list of names, a list of objects that spell the
    /// name as `ref`, `gate`, `name` or `stand`, and an object keyed by stand
    /// name. The backend's own fallback reader does exactly this — see
    /// `localAirportGates` in the database repo's `server.js` — and this is the
    /// same tolerance on the client, for the same reason: one dataset, several
    /// vintages, and the failure when they disagree is an empty picker rather
    /// than an error.
    private static func parse(_ root: Any) -> [String] {
        let raw: [Any]
        if let array = root as? [Any] {
            raw = array
        } else if let object = root as? [String: Any] {
            // Keyed by stand name: the keys are the answer, and a value that is
            // itself a named object is read below in case it is richer.
            raw = object.map { key, value in
                (value as? [String: Any]).flatMap(name(in:)) ?? key
            }
        } else {
            return []
        }

        var seen = Set<String>()
        var out: [String] = []

        for element in raw {
            let candidate: String?
            if let text = element as? String {
                candidate = text
            } else if let object = element as? [String: Any] {
                candidate = name(in: object)
            } else {
                candidate = nil
            }

            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }
            // Twelve is what the plans table takes, so a dataset with an essay
            // in the name column is cut here rather than refused on save.
            let ref = String(trimmed.prefix(12))
            guard !ref.isEmpty else { continue }

            // Case-folded for the duplicate check only. `2b` and `2B` are one
            // stand; whichever spelling the dataset used first is the one kept,
            // because it is the one somebody actually wrote down.
            guard seen.insert(ref.uppercased()).inserted else { continue }
            out.append(ref)
        }

        return out.sorted { GateOccupancy.naturalOrder($0, $1) }
    }

    private static func name(in object: [String: Any]) -> String? {
        for key in ["ref", "gate", "name", "stand"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
            if let number = object[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }
}
