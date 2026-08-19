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

    /// One waiter per outstanding request, answered in the order asked, each
    /// remembering which state it asked about.
    ///
    /// The id is not decoration. Infinite Flight can send frames NOBODY asked
    /// for — the ATC message stream pushes one every time the controller says
    /// something — and a reader that hands every arriving frame to the next
    /// waiter in the queue would give an ATC transcript to something expecting
    /// an altitude, and then be permanently one answer behind. Matching on the
    /// id means an unsolicited frame is recognised as unsolicited.
    private struct Waiter {
        let id: Int32
        let continuation: CheckedContinuation<Data, Error>
    }

    private var pending: [Waiter] = []

    /// Where frames nobody asked for go.
    ///
    /// Set by the session. Without it they are dropped, which is the correct
    /// behaviour for a stream nothing is listening to.
    private var unsolicited: (@Sendable (Int32, Data) -> Void)?

    func onUnsolicited(_ handler: @escaping @Sendable (Int32, Data) -> Void) {
        unsolicited = handler
    }

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
                    if settled.claim() {
                        continuation.resume(throwing: Failure.socket(explain(error, dialling: host)))
                    }
                case .cancelled:
                    if settled.claim() { continuation.resume(throwing: Failure.cancelled) }
                case let .waiting(error):
                    // Waiting is where a refusal lands. Network.framework does
                    // not treat ECONNREFUSED as fatal — it holds the connection
                    // open and retries until something answers — so a sim that
                    // is not running would sit here forever with the UI showing
                    // a spinner. Reported instead, because "nothing is
                    // listening" is an answer the pilot can act on and waiting
                    // is not.
                    if settled.claim() {
                        continuation.resume(throwing: Failure.socket(explain(error, dialling: host)))
                    }
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
        for waiter in waiting {
            waiter.continuation.resume(throwing: Failure.cancelled)
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
                try await self.send(id, ConnectProtocol.read(id), on: connection)
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

    private func send(_ id: Int32, _ data: Data, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Waiter(id: id, continuation: continuation))

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.failAll(Failure.socket(error.localizedDescription)) }
            })
        }
    }

    /// Sets a state.
    ///
    /// Nothing comes back. The API acknowledges neither a write nor a command,
    /// so there is no frame to wait for and no error to surface — which is why
    /// this returns as soon as the bytes are handed to the socket, and why the
    /// `timeout` is accepted only to match `read`.
    ///
    /// Which states accept a write is published nowhere — the manifest gives
    /// type and never direction — so this is best-effort by nature and the
    /// caller is expected to read the value back rather than assume.
    @discardableResult
    func write(
        _ id: Int32,
        _ value: ConnectProtocol.Value,
        as type: ConnectProtocol.ValueType,
        timeout: TimeInterval = 5
    ) async throws -> Bool {
        guard let connection else { throw Failure.notConnected }
        guard let frame = ConnectProtocol.write(id, value, as: type) else { return false }

        // A write is not acknowledged with a frame of its own, so there is
        // nothing to wait for: it is sent, and whether it took effect is a
        // question only a subsequent read can answer.
        connection.send(content: frame, completion: .contentProcessed { _ in })
        return true
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
            // Only the waiter that asked about THIS state is answered. Anything
            // else is a push — the ATC stream, or a state the sim volunteered —
            // and goes to the sink rather than stealing somebody's answer.
            if let next = pending.first, next.id == frame.id {
                pending.removeFirst()
                next.continuation.resume(returning: frame.payload)
            } else {
                unsolicited?(frame.id, frame.payload)
            }
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: error) }

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reader.reset()
    }
}

/// Turns a Network.framework error into something a pilot can act on.
///
/// The default is `error.localizedDescription`, which for a refused connection
/// reads "The operation couldn't be completed. (Network.NWError error 61 —
/// Connection refused)". That is shown directly under "Couldn't connect" in the
/// Connect panel, and it tells somebody trying to switch the feature on
/// precisely nothing about what to do next — even though the error code is one
/// of the most specific diagnostics available here.
///
/// The distinction that matters most is **refused versus timed out**, because
/// they mean opposite things. Refused is a machine answering and saying "not
/// here": the address is right and reachable, and nothing is listening on
/// 10112 — Infinite Flight is closed, or Connect is switched off inside it.
/// Timed out is silence: wrong address, wrong network, or a sleeping device.
private func explain(_ error: NWError, dialling host: String) -> String {
    let loopback = host == ConnectSession.loopback
    let device = loopback ? "this device" : host

    guard case let .posix(code) = error else {
        if case let .dns(status) = error {
            return "Couldn't look up \(host) (DNS error \(status)). An IP address like "
                 + "192.168.1.42 is more reliable here than a name."
        }
        return error.localizedDescription
    }

    switch code {
    case .ECONNREFUSED:
        if loopback {
            return "Infinite Flight isn't answering on this device. Something is there to "
                 + "refuse the connection, so the address is right and the sim is not "
                 + "listening on port \(ConnectProtocol.port): open Infinite Flight, then "
                 + "check Settings → General → "
                 + "Enable Infinite Flight Connect. If it is already on, turn off "
                 + "\"It's on this device\" and enter the address of the device running "
                 + "the sim instead."
        }
        return "\(host) answered, but nothing is listening on port \(ConnectProtocol.port). "
             + "That is the right device and the wrong state: check Infinite Flight is running on "
             + "it, and that Settings → General → Enable Infinite Flight Connect is on."

    case .ETIMEDOUT, .EHOSTDOWN:
        return "No answer from \(device). Either the address is wrong, or that device is "
             + "asleep or off this network."

    case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN:
        return "Can't reach \(device) from here. Both devices need to be on the same "
             + "Wi-Fi network — a phone that has dropped to cellular cannot see one on "
             + "the Wi-Fi."

    case .EPERM, .EACCES:
        // Not a network problem at all, and the one case where nothing the
        // pilot does inside either app will help.
        return "iOS is blocking this app from reaching devices on your network. Allow it "
             + "in Settings → Inflight → Local Network, then try again."

    case .ECONNRESET, .EPIPE, .ENOTCONN:
        return "\(device) closed the connection. Infinite Flight was probably shut down, "
             + "or Connect was switched off inside it, part-way through."

    case .EADDRNOTAVAIL, .EINVAL:
        return "\(host) isn't a usable address. It should look like 192.168.1.42 — find "
             + "it in Infinite Flight under Settings → General → Infinite Flight Connect."

    default:
        return error.localizedDescription
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
