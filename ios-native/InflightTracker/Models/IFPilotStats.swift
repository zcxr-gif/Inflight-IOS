import SwiftUI

/// What Infinite Flight itself knows about a pilot.
///
/// Deliberately not `PilotProfile`. That is the thing somebody made here — a
/// handle they chose, a picture they uploaded, a bio they wrote — and every
/// word of it is a claim. This is the other kind of fact entirely: the grade
/// the server has them at, the virtual airline the server has them flying for,
/// and the totals behind both. Nobody types any of it and nobody can edit it.
///
/// Keeping the two apart matters at the point they are drawn together. A
/// profile says "says they fly as EggsAviation" because nothing verifies the
/// join; the grade beside it says "Grade 4" flatly, because that one is not a
/// claim. Merging them into one struct would have lost exactly that
/// distinction, and it is the distinction the whole feature rests on.
///
/// Decoded from the backend's `/api/users/:id/stats` and
/// `/api/pilots/:name/stats`, which are the same block reached two ways.
struct IFPilotStats: Decodable, Equatable {

    /// The Infinite Flight account id. Present when the block was reached by
    /// name, which is the case that needed to resolve one.
    var userId: String?

    /// The Discourse handle, as Infinite Flight spells it — which is not
    /// necessarily how the person typed it.
    var username: String?

    /// 1 to 5, or nil when the server sent a block with no grade in it. Nil is
    /// an ordinary answer and everything drawing this treats it as one: a new
    /// account has no grade yet.
    var grade: Int?

    /// The virtual airline the server has them down as flying for. Free text,
    /// and often absent — most pilots are in none.
    var virtualOrganization: String?

    var totalXP: Double?
    var flightTimeMinutes: Double?
    var landingCount: Int?
    var onlineFlights: Int?
    var violations: Int?
    var atcRank: Int?
    var atcOperations: Int?

    /// What the grade is worth showing as. See `IFGrade`.
    var gradeBadge: IFGrade? { grade.flatMap(IFGrade.init(number:)) }

    /// Blank once the name and the numbers are all missing, which is what the
    /// backend answers with for a pilot it could resolve but knows nothing
    /// about. Views draw nothing rather than an empty row of dashes.
    var isEmpty: Bool {
        grade == nil
            && (virtualOrganization?.isEmpty ?? true)
            && totalXP == nil
            && landingCount == nil
    }

    enum CodingKeys: String, CodingKey {
        case grade
        case calculatedGrade
        case virtualOrganization
        case discourseUsername
        case totalXP
        case flightTime
        case landingCount
        case onlineFlights
        case violations
        case atcRank
        case atcOperations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `grade` first and `calculatedGrade` behind it: the backend sends both
        // and they carry the same resolved number, but an older deployment sent
        // only the second. Reading either means the app works against both.
        grade = (try? c.decode(Int.self, forKey: .grade))
            ?? (try? c.decode(Int.self, forKey: .calculatedGrade))
        virtualOrganization = (try? c.decode(String.self, forKey: .virtualOrganization))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        username = try? c.decode(String.self, forKey: .discourseUsername)
        totalXP = try? c.decode(Double.self, forKey: .totalXP)
        flightTimeMinutes = try? c.decode(Double.self, forKey: .flightTime)
        landingCount = try? c.decode(Int.self, forKey: .landingCount)
        onlineFlights = try? c.decode(Int.self, forKey: .onlineFlights)
        violations = try? c.decode(Int.self, forKey: .violations)
        atcRank = try? c.decode(Int.self, forKey: .atcRank)
        atcOperations = try? c.decode(Int.self, forKey: .atcOperations)
    }

    /// For previews and for the sample flight the settings panel draws.
    init(
        userId: String? = nil,
        username: String? = nil,
        grade: Int? = nil,
        virtualOrganization: String? = nil
    ) {
        self.userId = userId
        self.username = username
        self.grade = grade
        self.virtualOrganization = virtualOrganization
    }
}

/// A grade, and the colour it is drawn in.
///
/// ## Why a colour at all
///
/// Everything else in the flight window is monochrome on purpose — the palette
/// spends its one accent on the few things that have to be picked out, and a
/// window that colours every fact colours none of them. A grade is the
/// exception worth making, because it is the one number on the card that is
/// read comparatively: nobody wants to know that a pilot is Grade 3, they want
/// to know whether that is high. A ramp answers that before the digit is read.
///
/// ## Why these colours
///
/// A cool-to-warm ramp, ending in gold. It is the ordering people already read
/// out of a scale, it survives being drawn small, and it does not reuse the
/// app's accent — which means the grade never competes with the one thing the
/// window was already using colour to say. The colours are fixed rather than
/// derived from the theme for the same reason a flag is: Grade 5 that is gold
/// in the dark and blue in the light is not a badge, it is a decoration.
///
/// Each has a light and a dark variant, because a single colour that reads on
/// slate is a colour that vanishes on white.
enum IFGrade: Int, CaseIterable, Identifiable {

    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    /// Anything outside 1...5 is not a grade we know how to draw. A future
    /// sixth tier reads as no badge rather than as a wrong one.
    init?(number: Int) {
        self.init(rawValue: number)
    }

    var id: Int { rawValue }

    var label: String { "GRADE \(rawValue)" }

    /// Where there is room for one line about what the tier is. Infinite
    /// Flight's own gating, not our summary of it.
    var detail: String {
        switch self {
        case .one:   return "Casual and Training servers"
        case .two:   return "Training server"
        case .three: return "Expert server"
        case .four:  return "Expert server"
        case .five:  return "Expert server, the top tier"
        }
    }

    func colour(isLight: Bool) -> Color {
        switch self {
        case .one:
            return isLight ? Color(red: 0.42, green: 0.46, blue: 0.53)
                           : Color(red: 0.62, green: 0.67, blue: 0.75)
        case .two:
            return isLight ? Color(red: 0.11, green: 0.50, blue: 0.36)
                           : Color(red: 0.31, green: 0.80, blue: 0.60)
        case .three:
            return isLight ? Color(red: 0.11, green: 0.40, blue: 0.75)
                           : Color(red: 0.38, green: 0.68, blue: 0.98)
        case .four:
            return isLight ? Color(red: 0.44, green: 0.24, blue: 0.72)
                           : Color(red: 0.70, green: 0.55, blue: 0.98)
        case .five:
            return isLight ? Color(red: 0.63, green: 0.44, blue: 0.03)
                           : Color(red: 0.98, green: 0.78, blue: 0.30)
        }
    }
}
