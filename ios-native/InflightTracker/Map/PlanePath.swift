import CoreGraphics
import Foundation

/// Builds a `CGPath` from the artwork's path data.
///
/// The generator normalises everything it emits to absolute `M`, `L`, `H`, `V`,
/// `C` and `Z` — arcs and shorthand curves are resolved before they get here —
/// so this only has to understand those six, and anything else is a sign the
/// artwork was regenerated with different settings.
enum PlanePath {

    static func path(from data: String) -> CGPath {
        let path = CGMutablePath()
        var cursor = Cursor(data)
        var command: UInt8 = 0
        var point = CGPoint.zero
        var start = CGPoint.zero

        while cursor.hasMore {
            // A command letter, or another set of parameters for the last one:
            // path data repeats the arguments rather than the letter.
            if let next = cursor.takeCommand() {
                command = next
            } else if command == 0 {
                break
            }

            switch command {
            case UInt8(ascii: "M"):
                guard let x = cursor.number(), let y = cursor.number() else { return path }
                point = CGPoint(x: x, y: y)
                start = point
                path.move(to: point)
                // Repeated pairs after a moveto are implicit linetos.
                command = UInt8(ascii: "L")

            case UInt8(ascii: "L"):
                guard let x = cursor.number(), let y = cursor.number() else { return path }
                point = CGPoint(x: x, y: y)
                path.addLine(to: point)

            case UInt8(ascii: "H"):
                guard let x = cursor.number() else { return path }
                point.x = x
                path.addLine(to: point)

            case UInt8(ascii: "V"):
                guard let y = cursor.number() else { return path }
                point.y = y
                path.addLine(to: point)

            case UInt8(ascii: "C"):
                guard let x1 = cursor.number(), let y1 = cursor.number(),
                      let x2 = cursor.number(), let y2 = cursor.number(),
                      let x = cursor.number(), let y = cursor.number() else { return path }
                point = CGPoint(x: x, y: y)
                path.addCurve(
                    to: point,
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x2, y: y2)
                )

            case UInt8(ascii: "Z"):
                path.closeSubpath()
                point = start

            default:
                // Anything else means the artwork was generated with different
                // settings than this understands. Better a short path than a
                // wrong one.
                return path
            }
        }

        return path
    }

    /// A cursor over the path data. Bytes rather than characters: the data is
    /// pure ASCII and this runs once per icon on the way to a cached bitmap.
    private struct Cursor {

        private let bytes: [UInt8]
        private var index = 0

        init(_ string: String) {
            bytes = Array(string.utf8)
        }

        var hasMore: Bool {
            var probe = index
            while probe < bytes.count, isSeparator(bytes[probe]) { probe += 1 }
            return probe < bytes.count
        }

        /// The next command letter, if the cursor is on one, stepping over it.
        mutating func takeCommand() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") else { return nil }
            index += 1
            return byte
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index

            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                index += 1
            }
            while index < bytes.count, isNumeric(bytes[index]) {
                index += 1
            }

            guard index > begin,
                  let text = String(bytes: bytes[begin..<index], encoding: .utf8),
                  let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < bytes.count, isSeparator(bytes[index]) { index += 1 }
        }

        private func isSeparator(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t")
        }

        private func isNumeric(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: ".")
        }
    }
}
