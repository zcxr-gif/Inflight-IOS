import Foundation
import SocketIO

/// Live traffic from the ACARS backend.
///
/// Mirrors what `initializeSectorOpsSocket()` does in the web tracker:
/// connect, `emit("join_server_room", <server>)`, then listen for
/// `all_flights_update`. Payloads are decoded off the main thread and only
/// the finished array is published back to SwiftUI.
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
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var server: String

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

        // Traffic from the previous room is no longer relevant.
        flights = []
        status = .connecting

        socket?.emit("join_server_room", newServer)
    }

    // MARK: - Payload handling

    private func handle(_ data: [Any]) {
        guard let dictionary = data.first as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary),
              let raw = try? JSONSerialization.data(withJSONObject: dictionary),
              let payload = try? JSONDecoder().decode(FlightsPayload.self, from: raw) else { return }

        // Ignore packets still arriving for a room we just left.
        if let packetServer = payload.server, !packetServer.isEmpty,
           packetServer.caseInsensitiveCompare(room) != .orderedSame {
            return
        }

        let parsed = payload.validFlights

        publish { feed in
            feed.flights = parsed
            feed.lastUpdate = Date()
            feed.status = .live
        }
    }

    private func publish(_ change: @escaping (LiveFeed) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            change(self)
        }
    }
}
