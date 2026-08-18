import Foundation
import Network

/// Owns the socket and turns the byte stream into request/response pairs.
///
/// An actor because the whole thing is a mutable queue driven by callbacks from
/// Network.framework's own dispatch queue: the pending list, the frame buffer
/// and the connection all have to be touched from there and from whoever is
/// awaiting a read, and an actor is what makes that safe without a lock in
/// every method.
///
/// ## Why requests are issued one at a time
///
/// A response carries the state id it answers and nothing else — no sequence
/// number, no correlation token. That is enough to tell a latitude from an
/// altitude, and not enough to tell one read of latitude from the next one, so
/// two outstanding reads of the same state cannot be told apart. Pipelining
/// would be faster and would occasionally attribute one state's value to
/// another, which for a logbook is worse than slow. One in flight, answered in
/// order.
actor ConnectTransport {

    enum Failure: LocalizedError {
        case notConnected
        case timedOut(Int32)
        case cancelled
        case socket(String)
        case desynchronised

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to Infinite Flight."
            case .timedOut:
                return "Infinite Flight stopped answering."
            case .cancelled:
                return "The connection was closed."
            case let .socket(detail):
                return detail
            case .desynchronised:
                return "The connection lost sync and was closed."
            }
        }
    }

    private var connection: NWConnection?
    private var reader = ConnectFrameReader()

    /// One waiter per outstanding request, answered in the order asked.
    private var pending: [CheckedContinuation<Data, Error>] = []

    private let queue = DispatchQueue(label: "com.tracker.Inflight.connect")

    // MARK: - Lifecycle

    func connect(host: String, port: UInt16 = ConnectProtocol.port, timeout: TimeInterval = 8) async throws {
        close()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.socket("\(port) is not a usable port.")
        }

        let parameters = NWParameters.tcp
        // Telemetry is a stream of small reads where latency is the whole
        // point; Nagle would hold a five-byte request waiting for company.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = Int(timeout)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Network.framework will happily call the state handler more than
            // once; a continuation may only be resumed once.
            let settled = Settled()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if settled.claim() { continuation.resume() }
                case let .failed(error):
                    if settled.claim() { continuation.resume(throwing: Failure.socket(error.localizedDescription)) }
                case .cancelled:
                    if settled.claim() { continuation.resume(throwing: Failure.cancelled) }
                case let .waiting(error):
                    // Waiting means the path is not viable — usually the device
                    // is asleep, off this network, or Connect is switched off.
                    // Reported rather than waited on, because the honest answer
                    // arrives faster than the retry does.
                    if settled.claim() { continuation.resume(throwing: Failure.socket(error.localizedDescription)) }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }

        receive()
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reader.reset()

        let waiting = pending
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: Failure.cancelled)
        }
    }

    var isConnected: Bool { connection != nil }

    // MARK: - Reading

    /// Sends one read and waits for its answer.
    ///
    /// The timeout is per request rather than per connection: a device that has
    /// gone to sleep leaves a socket that is open and silent, and without this
    /// the poll loop would wait on it forever with the UI still claiming to be
    /// live.
    ///
    /// A timeout takes the whole connection down with it, and that is not
    /// heavy-handedness. Answers are matched to questions by their order and
    /// nothing else, so a request that is abandoned while its answer is still
    /// in flight leaves every later answer off by one — altitudes arriving as
    /// latitudes, silently and permanently. There is no way to resynchronise a
    /// stream that has no message boundaries, so the only safe response to a
    /// lost answer is to start again.
    func read(_ id: Int32, timeout: TimeInterval = 5) async throws -> Data {
        guard let connection else { throw Failure.notConnected }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.send(ConnectProtocol.read(id), on: connection)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut(id)
            }

            do {
                guard let first = try await group.next() else { throw Failure.cancelled }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                // `error` is an existential, so the case has to be reached
                // through a cast rather than matched against directly.
                if let failure = error as? Failure, case .timedOut = failure {
                    failAll(failure)
                }
                throw error
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.failAll(Failure.socket(error.localizedDescription)) }
            })
        }
    }

    /// Fetches the manifest and returns it as the raw catalogue string.
    ///
    /// Given far longer than an ordinary read: it is tens of kilobytes arriving
    /// over many packets, and on a busy network the tail can take seconds.
    func manifest(timeout: TimeInterval = 25) async throws -> String {
        let payload = try await read(ConnectProtocol.manifestID, timeout: timeout)
        guard case let .string(text)? = ConnectProtocol.decode(.string, from: payload) else {
            throw Failure.socket("The manifest came back unreadable.")
        }
        return text
    }

    // MARK: - The stream

    private func receive() {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task {
                if let data, !data.isEmpty {
                    await self.ingest(data)
                }

                if let error {
                    await self.failAll(Failure.socket(error.localizedDescription))
                    return
                }

                if isComplete {
                    await self.failAll(Failure.cancelled)
                    return
                }

                await self.receive()
            }
        }
    }

    private func ingest(_ data: Data) {
        let frames: [ConnectFrameReader.Frame]
        do {
            frames = try reader.append(data)
        } catch {
            // A length field no value would carry means the stream has lost
            // alignment. There is no recovering by reading on — every
            // subsequent frame boundary would be wrong — so the connection goes
            // and the session reconnects from a known state.
            failAll(Failure.desynchronised)
            return
        }

        for frame in frames {
            guard !pending.isEmpty else { continue }
            let continuation = pending.removeFirst()
            continuation.resume(returning: frame.payload)
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reader.reset()
    }
}

/// A one-shot latch, so a continuation resumed from a callback that fires more
/// than once is only resumed the first time.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
