import Foundation

/// What the pilot is doing, as distinct from what the aircraft is doing.
///
/// The feed has always sent this alongside the position (`pilotState` in the
/// `all_flights_update` payload, written up in `old/www/SocketDataHub.js`); the
/// native app simply wasn't reading it. It answers the question a phase can't:
/// an aircraft at cruise reads the same whether someone is flying it or whether
/// it is holding a heading with nobody at the controls.
enum PilotState: Int, CaseIterable {

    /// At the controls.
    case active = 0

    /// Connected, but not touching anything.
    case away = 1

    /// Away, and on the ground.
    case parked = 2

    /// Flying on the server without the app in the foreground — the cloud
    /// session the web tracker labels AUTO-PILOT+.
    case autopilotPlus = 3

    /// Short enough for a chip beside a callsign.
    var label: String {
        switch self {
        case .active: return "ACTIVE"
        case .away: return "AWAY"
        case .parked: return "PARKED"
        case .autopilotPlus: return "AP+"
        }
    }

    /// What the label actually means, for the places with room to say it.
    var detail: String {
        switch self {
        case .active: return "At the controls"
        case .away: return "Online, no input"
        case .parked: return "Away, on the ground"
        case .autopilotPlus: return "Cloud session"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "person.fill.checkmark"
        case .away: return "cup.and.saucer.fill"
        case .parked: return "parkingsign"
        case .autopilotPlus: return "cloud.fill"
        }
    }

    /// Active is the ordinary case — everything else is worth pointing out.
    /// Used where there is only room for a badge when it says something.
    var isNoteworthy: Bool { self != .active }

    /// Anything the backend sends outside the table reads as active, which is
    /// what the web tracker defaults to as well.
    static func from(_ value: Int?) -> PilotState {
        guard let value = value, let state = PilotState(rawValue: value) else { return .active }
        return state
    }
}
