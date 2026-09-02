import SwiftUI
import UIKit

/// What the open window's third look is built out of, and in what order.
///
/// ## Why this exists
///
/// The other two looks are fixed arrangements, and that is the right shape for
/// them: the cards look is the app's own answer and the board is a departures
/// board, and neither is improved by being negotiable. This one is a *dense*
/// look — its whole argument is having everything on one face — and "everything"
/// is not the same list for everybody. Somebody watching their own flight wants
/// the height and the vertical speed at the top; somebody looking up an
/// aeroplane they saw overhead wants the type and the tail. Both were being
/// served the same stack in the same order, and the second half of it scrolled
/// off the bottom.
///
/// So the look is a list of blocks with an order, a switch and a colour each,
/// and the window draws whatever the list says. Adding a block to the look means
/// a case in `FlightInfoBlockKind` and a branch in the head that draws it —
/// nothing here or in the editor has to be touched.
///
/// ## What it does not do
///
/// It does not invent data. Every block draws something the window already
/// knew — this is an arrangement of the same facts, and the identity band
/// cannot be switched off at all, because a flight window with no callsign on
/// it is not a flight window.

// MARK: - The blocks themselves

/// One kind of block the open window can carry.
enum FlightInfoBlockKind: String, CaseIterable, Identifiable {

    /// Callsign, operator, phase. The one block that is always drawn.
    case identity

    /// The aircraft's photograph.
    case photo

    /// Both ends of the route, with the badge between them.
    case route

    /// How far along it is: the bar, and the two distances.
    case progress

    /// When it left, and when it arrives.
    case times

    /// The four live numbers — height, speed, climb, heading.
    case telemetry

    /// What the aeroplane is: type, tail, operator, who is flying it.
    case aircraft

    /// Where it is, to the minute.
    case position

    var id: String { rawValue }

    var label: String {
        switch self {
        case .identity: return "Identity"
        case .photo: return "Photograph"
        case .route: return "Route"
        case .progress: return "Progress"
        case .times: return "Times"
        case .telemetry: return "Live numbers"
        case .aircraft: return "Aircraft"
        case .position: return "Position"
        }
    }

    var detail: String {
        switch self {
        case .identity: return "The callsign, the operator and the phase."
        case .photo: return "The aircraft's photograph, or its silhouette."
        case .route: return "Both ends, set as a headline."
        case .progress: return "The bar, and how far is flown and left."
        case .times: return "When it was first seen moving, and when it arrives."
        case .telemetry: return "Height, ground speed, climb and heading."
        case .aircraft: return "Type, tail, operator and pilot."
        case .position: return "Latitude and longitude."
        }
    }

    var symbol: String {
        switch self {
        case .identity: return "person.text.rectangle"
        case .photo: return "photo"
        case .route: return "arrow.left.arrow.right"
        case .progress: return "chart.bar.horizontal.page"
        case .times: return "clock"
        case .telemetry: return "gauge.with.dots.needle.bottom.50percent"
        case .aircraft: return "airplane"
        case .position: return "location"
        }
    }

    /// Whether the block may be switched off.
    ///
    /// Everything but the identity band. A window that does not say which
    /// aeroplane it is about is not a window, and an arrangement that allows
    /// that is an arrangement with a way to break itself.
    var isRemovable: Bool { self != .identity }

    /// Whether a colour means anything on this block.
    ///
    /// Everything but the photograph. A picture in a tinted card with a rule
    /// along the top is a picture in a frame, so the photo block takes the
    /// window's corner and nothing else — and the editor stops offering a
    /// colour that would do nothing.
    var wearsColour: Bool { self != .photo }
}

/// How a block wears a colour.
///
/// Four steps rather than a switch, because "colour this block" means four
/// different things to four people and they are all reasonable: a rule along
/// its top, the numbers picked out, the whole card tinted, or nothing at all.
enum FlightInfoBlockTint: String, CaseIterable, Identifiable {

    /// The window's own surface, untouched. The default for every block.
    case plain

    /// A rule along the top edge of the card, and nothing else.
    case line

    /// The block's own accents — the badge, the bar, the estimate mark — in
    /// the colour. The type stays as it is.
    case accent

    /// The whole card tinted, with the accents to match.
    case filled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "None"
        case .line: return "Line"
        case .accent: return "Accent"
        case .filled: return "Filled"
        }
    }

    var detail: String {
        switch self {
        case .plain: return "The window's own surface, as every other card."
        case .line: return "A rule along the top of the card."
        case .accent: return "The block's own accents in the colour."
        case .filled: return "The whole card tinted."
        }
    }

    /// Whether this treatment needs a colour at all. `plain` does not, so the
    /// editor stops offering one.
    var usesColour: Bool { self != .plain }
}

/// One block, as arranged.
struct FlightInfoBlock: Identifiable, Equatable {

    let kind: FlightInfoBlockKind

    var isOn: Bool

    var tint: FlightInfoBlockTint

    /// The colour this block wears, or nil for the window's own accent — which
    /// is what an airline-coloured window puts on everything else, so a block
    /// that has not been given a colour goes on matching the window.
    var colour: Color?

    var id: String { kind.rawValue }
}

// MARK: - The arrangement

/// The stored arrangement of the open window's third look.
///
/// Persisted as one property-list value rather than a key per block: the order
/// is the whole point of the thing, and an order stored as several keys is an
/// order that can be half-written.
final class FlightInfoBlocks: ObservableObject {

    static let shared = FlightInfoBlocks()

    private static let key = "flightInfo.blocks"

    /// What the look is out of the box.
    ///
    /// Who, then what it looks like, then where it is going, then how far along
    /// it is, then what it is doing, then when, then what it is. Close to the
    /// order the look was fixed at before it was arrangeable — the two changes
    /// are that the live numbers are now a block of four rather than two cells
    /// wedged between the route and the times, and that the progress bar has a
    /// block of its own so it can be moved away from the route or dropped.
    ///
    /// `position` ships off. A latitude is the sort of thing you want
    /// occasionally and never want in the way, and a block that starts off is
    /// how this list says "and there is more, if you want it".
    static let standard: [FlightInfoBlock] = [
        FlightInfoBlock(kind: .identity, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .photo, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .route, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .progress, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .telemetry, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .times, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .aircraft, isOn: true, tint: .plain, colour: nil),
        FlightInfoBlock(kind: .position, isOn: false, tint: .plain, colour: nil)
    ]

    @Published var blocks: [FlightInfoBlock] {
        didSet { save() }
    }

    /// The blocks actually drawn, in order.
    var visible: [FlightInfoBlock] { blocks.filter(\.isOn) }

    /// Whether the arrangement is still the one it shipped with, so the editor
    /// can offer to put it back only when there is something to put back.
    var isStandard: Bool { blocks == Self.standard }

    private init() {
        blocks = Self.load() ?? Self.standard
    }

    // MARK: Editing

    /// Moves one block up or down the list.
    ///
    /// By kind rather than by index: the editor's rows are identified by what
    /// they are, and an index that was read a frame ago is an index that may
    /// have moved.
    func move(_ kind: FlightInfoBlockKind, by step: Int) {
        guard let from = blocks.firstIndex(where: { $0.kind == kind }) else { return }
        let to = from + step
        guard to >= 0, to < blocks.count else { return }
        blocks.swapAt(from, to)
    }

    /// SwiftUI's own reorder, for a list that has one.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        blocks.move(fromOffsets: offsets, toOffset: destination)
    }

    func setOn(_ isOn: Bool, for kind: FlightInfoBlockKind) {
        guard kind.isRemovable || isOn else { return }
        update(kind) { $0.isOn = isOn }
    }

    func setTint(_ tint: FlightInfoBlockTint, for kind: FlightInfoBlockKind) {
        update(kind) { $0.tint = tint }
    }

    func setColour(_ colour: Color?, for kind: FlightInfoBlockKind) {
        update(kind) { $0.colour = colour }
    }

    func block(_ kind: FlightInfoBlockKind) -> FlightInfoBlock {
        blocks.first { $0.kind == kind }
            ?? FlightInfoBlock(kind: kind, isOn: false, tint: .plain, colour: nil)
    }

    func reset() {
        blocks = Self.standard
    }

    private func update(_ kind: FlightInfoBlockKind, _ change: (inout FlightInfoBlock) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.kind == kind }) else { return }
        var block = blocks[index]
        change(&block)
        guard block != blocks[index] else { return }
        blocks[index] = block
    }

    // MARK: Persistence

    /// Three components rather than an archived `Color`, the same way the pilot
    /// colours are stored — `Color` has no stable archive format across OS
    /// versions, and the components are what it is built from anyway.
    private func save() {
        let encoded: [[String: Any]] = blocks.map { block in
            var row: [String: Any] = [
                "kind": block.kind.rawValue,
                "on": block.isOn,
                "tint": block.tint.rawValue
            ]
            if let parts = FlightInfoBlocks.components(of: block.colour) {
                row["colour"] = parts
            }
            return row
        }
        UserDefaults.standard.set(encoded, forKey: Self.key)
    }

    /// Reads the stored arrangement, and repairs it on the way through.
    ///
    /// A stored list is a list written by an older version of this app, so it
    /// is not to be trusted to be complete: a block added since is missing from
    /// it, and a block removed since is still in it. Unknown kinds are dropped
    /// and new ones are appended in their standard state, which means adding a
    /// block to the look never costs anybody their arrangement — the new one
    /// simply turns up at the bottom.
    ///
    /// Nil for no stored value at all, which is a first run rather than a
    /// broken one and takes the standard order.
    private static func load() -> [FlightInfoBlock]? {
        guard let stored = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else {
            return nil
        }

        var restored: [FlightInfoBlock] = []
        for row in stored {
            guard let raw = row["kind"] as? String,
                  let kind = FlightInfoBlockKind(rawValue: raw),
                  !restored.contains(where: { $0.kind == kind }) else { continue }

            let tint = FlightInfoBlockTint(rawValue: row["tint"] as? String ?? "") ?? .plain
            let isOn = row["on"] as? Bool ?? true

            restored.append(
                FlightInfoBlock(
                    kind: kind,
                    // The one block that cannot be off stays on however it was
                    // written down.
                    isOn: kind.isRemovable ? isOn : true,
                    tint: tint,
                    colour: colour(from: row["colour"] as? [Double])
                )
            )
        }

        guard !restored.isEmpty else { return nil }

        for block in standard where !restored.contains(where: { $0.kind == block.kind }) {
            restored.append(block)
        }

        return restored
    }

    private static func colour(from parts: [Double]?) -> Color? {
        guard let parts = parts, parts.count == 3 else { return nil }
        return Color(red: parts[0], green: parts[1], blue: parts[2])
    }

    private static func components(of colour: Color?) -> [Double]? {
        guard let colour = colour else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return [Double(red), Double(green), Double(blue)]
    }
}

// MARK: - Wearing the colour

extension FlightInfoTheme {

    /// This theme as one block wears it.
    ///
    /// `accent` and `onAccent` move and nothing else, which is the same
    /// discipline `accented(by:)` keeps for an airline's colour: what a block's
    /// colour touches is the badge, the bar, the estimate mark and the
    /// callsign — the things already drawn in the accent — and never the type
    /// or the ground it is written on.
    ///
    /// `plain` and `line` hand the theme back untouched: a rule along the top
    /// of a card is drawn by the card, and has no business restyling what is
    /// inside it.
    func wearing(_ block: FlightInfoBlock) -> FlightInfoTheme {
        guard let colour = block.colour,
              block.tint == .accent || block.tint == .filled else { return self }

        var tinted = self
        tinted.accent = colour
        tinted.onAccent = FlightInfoTheme.ink(on: colour)
        return tinted
    }

    /// Black or white, whichever can be read on this colour.
    ///
    /// Rec. 709 luminance against the midpoint. A block's colour is picked in a
    /// system colour well and can be anything at all, including a yellow that
    /// white glyphs vanish into — so what sits *on* the accent is computed
    /// rather than assumed.
    static func ink(on colour: Color) -> Color {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .white
        }
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        return luminance > 0.55 ? Color(white: 0.06) : .white
    }
}
