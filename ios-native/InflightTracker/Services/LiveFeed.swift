import Foundation
import SocketIO

/// Live traffic from the ACARS backend.
///
/// Mirrors what `initializeSectorOpsSocket()` does in the web tracker:
/// connect, `emit("join_server_room", <server>)`, then listen for
/// `all_flights_update` and `secondary_data_update` — traffic on one channel,
/// the controllers working it on the other. Payloads are decoded off the main
/// thread and only the finished arrays are published back to SwiftUI.
final class LiveFeed: ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case live
        case offline(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .connecting: return "Connecting…"
            case .live: return "Live"
            case .offline(let reason): return reason
            }
        }

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }
    }

    @Published private(set) var flights: [Flight] = []

    /// Who is on frequency, grouped by the field or FIR they are working.
    /// Broadcast on its own channel and on its own schedule, so this updates
    /// independently of the traffic.
    @Published private(set) var atcStations: [AtcStation] = []

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var server: String

    /// Total positions open, which is what the toolbar badges. Counted here
    /// rather than by the views, which would each walk the stations to do it.
    @Published private(set) var atcCount = 0

    /// When the controllers last changed.
    ///
    /// The traffic has `lastUpdate` for exactly this reason and the stations
    /// needed their own: anything derived from who is working — the ranked
    /// fields the map marks, chiefly — wants to be rebuilt when a packet lands
    /// and at no other time, and comparing the grouped stations on every
    /// redraw to find that out is the thing being avoided.
    @Published private(set) var stationsUpdate: Date?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let decodeQueue = DispatchQueue(label: "com.tracker.inflight.feed", qos: .userInitiated)

    /// The room the socket callbacks should be joining/filtering against.
    /// Written from the main thread, read from `decodeQueue`, so it is
    /// guarded rather than read directly off `server`.
    private let roomLock = NSLock()
    private var unsafeRoom: String
    private var room: String {
        get {
            roomLock.lock()
            defer { roomLock.unlock() }
            return unsafeRoom
        }
        set {
            roomLock.lock()
            unsafeRoom = newValue
            roomLock.unlock()
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: AppConfig.serverDefaultsKey)
        let resolved = AppConfig.servers.contains(saved ?? "") ? (saved ?? AppConfig.defaultServer)
                                                              : AppConfig.defaultServer
        server = resolved
        unsafeRoom = resolved
    }

    // MARK: - Connection

    func connect() {
        guard socket == nil else { return }
        guard let url = URL(string: AppConfig.socketURLString) else {
            status = .offline("Bad feed URL")
            return
        }

        status = .connecting

        let manager = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .reconnects(true),
            .reconnectAttempts(-1),
            .reconnectWait(3),
            .forceNew(true)
        ])
        manager.handleQueue = decodeQueue

        let socket = manager.defaultSocket

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            self.socket?.emit("join_server_room", self.room)
            self.publish { $0.status = .connecting }
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.publish { $0.status = .offline("Disconnected") }
        }

        socket.on(clientEvent: .error) { [weak self] _, _ in
            self?.publish { $0.status = .offline("Connection error") }
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] _, _ in
            self?.publish { $0.status = .connecting }
        }

        socket.on("all_flights_update") { [weak self] data, _ in
            self?.handle(data)
        }

        socket.on("secondary_data_update") { [weak self] data, _ in
            self?.handleSecondary(data)
        }

        self.manager = manager
        self.socket = socket

        socket.connect()
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        status = .idle
    }

    // MARK: - Server selection

    func select(server newServer: String) {
        guard newServer != server, AppConfig.servers.contains(newServer) else { return }

        server = newServer
        room = newServer
        UserDefaults.standard.set(newServer, forKey: AppConfig.serverDefaultsKey)

        // Traffic from the previous room is no longer relevant, and neither is
        // who was controlling it.
        flights = []
        atcStations = []
        atcCount = 0
        stationsUpdate = Date()
        status = .connecting

        socket?.emit("join_server_room", newServer)
    }

    // MARK: - Payload handling

    private func handle(_ data: [Any]) {
        guard let payload = data.first as? [String: Any] else { return }

        // Ignore packets still arriving for a room we just left. Checked before
        // parsing so a stale packet costs nothing.
        if let packetServer = payload["server"] as? String, !packetServer.isEmpty,
           packetServer.caseInsensitiveCompare(room) != .orderedSame {
            return
        }

        guard let rawFlights = payload["flights"] as? [Any] else { return }

        var parsed: [Flight] = []
        parsed.reserveCapacity(rawFlights.count)

        for case let entry as [String: Any] in rawFlights {
            if let flight = Flight(payload: entry) { parsed.append(flight) }
        }

        // Still on the decode queue: the trail store is what lets the map draw
        // where a flight has been, and it only ever sees what we receive.
        FlightTrailStore.shared.record(parsed)

        publish { feed in
            feed.flights = parsed
            feed.lastUpdate = Date()
            feed.status = .live
        }
    }

    /// `secondary_data_update`: the controllers currently open on this server.
    ///
    /// Same room guard as the traffic — the socket keeps delivering the old
    /// room's packets for a moment after a switch, and a list of controllers
    /// working a server you just left is worse than an empty one.
    private func handleSecondary(_ data: [Any]) {
        guard let payload = data.first as? [String: Any] else { return }

        if let packetServer = payload["server"] as? String, !packetServer.isEmpty,
           packetServer.caseInsensitiveCompare(room) != .orderedSame {
            return
        }

        guard let rawFacilities = payload["atc"] as? [Any] else { return }

        var parsed: [AtcFacility] = []
        parsed.reserveCapacity(rawFacilities.count)

        for case let entry as [String: Any] in rawFacilities {
            if let facility = AtcFacility(payload: entry) { parsed.append(facility) }
        }

        // Grouped here, on the decode queue, rather than in the panel's body:
        // the panel is rebuilt on every packet either way, and this is the part
        // that costs something.
        let stations = AtcStation.group(parsed)
        let count = parsed.count

        publish { feed in
            feed.atcStations = stations
            feed.atcCount = count
            feed.stationsUpdate = Date()
        }
    }

    private func publish(_ change: @escaping (LiveFeed) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            change(self)
        }
    }
}
