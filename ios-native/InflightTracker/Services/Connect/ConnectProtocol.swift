import Foundation

/// The wire format of the Infinite Flight Connect API, version 2.
///
/// A local, unauthenticated, binary TCP protocol served by the copy of Infinite
/// Flight running on a device, to anything on the same network. There is no
/// cloud endpoint and no token: if you can reach the port you can read the
/// aircraft, which is why nothing in this file is ever pointed at an address
/// the pilot did not choose.
///
/// Everything is little-endian. Two frame shapes, and that is the whole
/// protocol:
///
/// ```
///   request   [ Int32 state id ][ UInt8 0=read 1=write ][ value, if writing ]
///   response  [ Int32 state id ][ Int32 byte count     ][ value             ]
/// ```
///
/// A String value carries its length a second time, inside the payload, so a
/// string response is `id`, `count`, then `Int32 length` and that many UTF-8
/// bytes with no terminator.
enum ConnectProtocol {

    /// The port Infinite Flight serves v2 on. Version 1 — JSON, deprecated —
    /// is on 10111 and is not spoken here.
    static let port: UInt16 = 10112

    /// Where the device announces itself while Connect is enabled.
    static let broadcastPort: UInt16 = 15000

    /// The pseudo-state that returns the catalogue of every other one.
    static let manifestID: Int32 = -1

    /// A frame claiming more than this is a desynchronised stream, not a big
    /// value. The manifest is the largest thing the API sends and runs to tens
    /// of kilobytes; the ceiling is set far above that and far below anything
    /// that would exhaust memory.
    static let maximumFrameBytes = 8 * 1024 * 1024

    /// What a state holds. The manifest gives one of these for every path, and
    /// it is the only thing that says how to read the bytes that come back.
    enum ValueType: Int32 {
        case boolean = 0
        case integer = 1
        case float   = 2
        case double  = 3
        case string  = 4
        case long    = 5

        /// Not a value at all — an action. `commands/…` entries carry this and
        /// are invoked with a read frame, returning nothing.
        case command = -1
    }

    // MARK: - Encoding

    /// A read, or a command invocation. Both are the same five bytes.
    static func read(_ id: Int32) -> Data {
        var data = Data(capacity: 5)
        data.appendLittleEndian(id)
        data.append(0)
        return data
    }

    /// A write.
    ///
    /// Returns nil for a value that does not match the type the manifest
    /// declared, rather than sending bytes the far end will misread. Which
    /// states accept a write is not published anywhere — the manifest gives
    /// type and never direction — so every write is best-effort and worth
    /// reading back.
    static func write(_ id: Int32, _ value: Value, as type: ValueType) -> Data? {
        var data = Data(capacity: 13)
        data.appendLittleEndian(id)
        data.append(1)

        switch (type, value) {
        case let (.boolean, .boolean(flag)):
            data.append(flag ? 1 : 0)

        case let (.integer, .integer(number)):
            data.appendLittleEndian(number)

        case let (.float, .float(number)):
            data.appendLittleEndian(number.bitPattern)

        case let (.double, .double(number)):
            data.appendLittleEndian(number.bitPattern)

        case let (.long, .long(number)):
            data.appendLittleEndian(number)

        case let (.string, .string(text)):
            let bytes = Data(text.utf8)
            data.appendLittleEndian(Int32(bytes.count))
            data.append(bytes)

        default:
            return nil
        }

        return data
    }

    // MARK: - Decoding

    /// One value read off the wire, still carrying which kind it was.
    enum Value: Equatable {
        case boolean(Bool)
        case integer(Int32)
        case float(Float)
        case double(Double)
        case string(String)
        case long(Int64)

        /// Everything numeric as a Double, for the many callers that do not
        /// care whether an altitude arrived as a float or a double.
        var number: Double? {
            switch self {
            case let .boolean(flag):  return flag ? 1 : 0
            case let .integer(value): return Double(value)
            case let .float(value):   return Double(value)
            case let .double(value):  return value
            case let .long(value):    return Double(value)
            case .string:             return nil
            }
        }

        var text: String? {
            switch self {
            case let .string(value): return value
            default: return nil
            }
        }

        var flag: Bool? {
            switch self {
            case let .boolean(value): return value
            case let .integer(value): return value != 0
            default: return nil
            }
        }
    }

    /// Reads a value out of a response payload — the bytes after the id and
    /// the byte count.
    ///
    /// Returns nil rather than trapping when the payload is shorter than the
    /// type needs. A truncated frame is a bug somewhere, and the honest
    /// response to one is no value, not a crash in the middle of somebody's
    /// flight.
    static func decode(_ type: ValueType, from payload: Data) -> Value? {
        switch type {
        case .boolean:
            guard payload.count >= 1 else { return nil }
            return .boolean(payload[payload.startIndex] == 1)

        case .integer:
            guard let raw: UInt32 = payload.littleEndian(at: 0) else { return nil }
            return .integer(Int32(bitPattern: raw))

        case .float:
            guard let raw: UInt32 = payload.littleEndian(at: 0) else { return nil }
            return .float(Float(bitPattern: raw))

        case .double:
            guard let raw: UInt64 = payload.littleEndian(at: 0) else { return nil }
            return .double(Double(bitPattern: raw))

        case .long:
            guard let raw: UInt64 = payload.littleEndian(at: 0) else { return nil }
            return .long(Int64(bitPattern: raw))

        case .string:
            guard let raw: UInt32 = payload.littleEndian(at: 0) else { return nil }
            let length = Int(Int32(bitPattern: raw))
            guard length >= 0, payload.count >= 4 + length else { return nil }

            let start = payload.index(payload.startIndex, offsetBy: 4)
            let end = payload.index(start, offsetBy: length)
            return .string(String(decoding: payload[start..<end], as: UTF8.self))

        case .command:
            return nil
        }
    }
}

// MARK: - Framing

/// Turns a stream of arbitrary chunks into whole frames.
///
/// TCP does not preserve message boundaries: a reply can be split across
/// packets and two replies can share one. Bytes accumulate here and a frame is
/// only handed on once every byte it declared has arrived — which is the
/// difference between a client that works and one that works until the manifest
/// gets big enough to be split.
struct ConnectFrameReader {

    struct Frame {
        let id: Int32
        let payload: Data
    }

    enum Failure: Error {
        /// A length field no real value would carry. The stream has lost
        /// alignment and cannot be recovered by reading further, so the
        /// connection is dropped rather than left buffering forever.
        case desynchronised(claimed: Int)
    }

    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)

        var frames: [Frame] = []

        while true {
            guard buffer.count >= 8 else { break }

            guard let rawID: UInt32 = buffer.littleEndian(at: 0),
                  let rawLength: UInt32 = buffer.littleEndian(at: 4) else { break }

            let id = Int32(bitPattern: rawID)
            let length = Int(Int32(bitPattern: rawLength))

            guard length >= 0, length <= ConnectProtocol.maximumFrameBytes else {
                throw Failure.desynchronised(claimed: length)
            }

            guard buffer.count >= 8 + length else { break }

            let start = buffer.index(buffer.startIndex, offsetBy: 8)
            let end = buffer.index(start, offsetBy: length)
            frames.append(Frame(id: id, payload: Data(buffer[start..<end])))

            buffer = Data(buffer[end...])
        }

        return frames
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

// MARK: - Byte helpers

private extension Data {

    /// Appends an integer least-significant byte first.
    ///
    /// Written as a shift loop rather than through `withUnsafeBytes`, which is
    /// the obvious way and the one that made the Swift 6.2 type checker fall
    /// over on this file — "failed to produce diagnostic for expression",
    /// which is a compiler bug rather than a mistake here, but is just as
    /// fatal to the build. This version has no generic pointer conversion for
    /// it to choke on, is endianness-independent by construction rather than
    /// by trusting the host, and costs nothing at these widths.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for byte in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> (8 * byte)))
        }
    }

    /// Reads a fixed-width integer at a byte offset from the start of this
    /// slice, honouring the slice's own indices rather than assuming zero.
    ///
    /// `Data` slices keep the parent's indices, so `data[0]` on a slice that
    /// begins at 8 traps. Every read here goes through `startIndex`, which is
    /// the only reason this survives being handed a subrange.
    func littleEndian<T: FixedWidthInteger>(at offset: Int) -> T? {
        let width = MemoryLayout<T>.size
        guard count >= offset + width else { return nil }

        let start = index(startIndex, offsetBy: offset)

        // Most significant byte first — which in a little-endian buffer is the
        // LAST one — shifting each into place. See `appendLittleEndian` for why
        // this is a loop and not a pointer cast.
        var value: T = 0
        for byte in stride(from: width - 1, through: 0, by: -1) {
            value = (value &<< 8) | T(truncatingIfNeeded: self[start + byte])
        }
        return value
    }
}
