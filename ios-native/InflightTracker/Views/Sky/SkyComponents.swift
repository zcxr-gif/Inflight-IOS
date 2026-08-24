import SwiftUI
import UIKit

/// A reading over the picture: one glyph, one line, on the app's own chrome.
struct SkyChip: View {

    let text: String
    let symbol: String
    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textSecondary)

            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .flightInfoChrome(theme, in: Capsule())
        .environment(\.colorScheme, theme.colorScheme)
    }
}

/// Why the sky view is not showing a sky.
///
/// Each of these is a dead end for a different reason, and the difference
/// matters: two of them are a switch the user can throw, two are hardware, and
/// two are a vantage that has moved on without them.
enum SkyNotice {

    case cameraRefused
    case noCamera
    case noSensors
    case locationRefused
    case findingYou
    case flightGone
    case fieldGone

    var symbol: String {
        switch self {
        case .cameraRefused, .noCamera: return "camera.fill"
        case .noSensors: return "gyroscope"
        case .locationRefused: return "location.slash.fill"
        case .findingYou: return "location.magnifyingglass"
        case .flightGone: return "airplane.departure"
        case .fieldGone: return "mappin.slash"
        }
    }

    var title: String {
        switch self {
        case .cameraRefused: return "The camera is switched off"
        case .noCamera: return "No camera to look through"
        case .noSensors: return "This device cannot do it"
        case .locationRefused: return "Location is switched off"
        case .findingYou: return "Finding you"
        case .flightGone: return "That aircraft has gone"
        case .fieldGone: return "That field has gone"
        }
    }

    var detail: String {
        switch self {
        case .cameraRefused:
            return "The sky view draws the traffic over what the camera sees. "
                + "Nothing is recorded, kept or sent anywhere."
        case .noCamera:
            return "The back camera would not open, so there is nothing to draw the sky over."
        case .noSensors:
            return "Pointing at aircraft needs a gyroscope and a compass, and this device "
                + "is not offering both."
        case .locationRefused:
            return "Which way is north depends on where you are standing, so the compass "
                + "needs your location. It stays on the phone."
        case .findingYou:
            return "Waiting for a fix. Outdoors is faster than indoors, and this clears "
                + "the moment one lands."
        case .flightGone:
            return "It is no longer in the feed. Pick another vantage to carry on looking."
        case .fieldGone:
            return "The field is not in the airport dataset. Pick another vantage."
        }
    }

    /// Whether the way out of this is in Settings.
    var opensSettings: Bool {
        switch self {
        case .cameraRefused, .locationRefused: return true
        default: return false
        }
    }
}

/// The card that carries one, over a scrim heavy enough to say the view behind
/// it is not working.
struct SkyNoticeCard: View {

    let notice: SkyNotice
    let theme: FlightInfoTheme
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: notice.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Text(notice.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(notice.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)

                if notice.opensSettings {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Text("Open Settings")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background { Capsule().fill(theme.accent) }
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onClose) {
                    Text("Back to the map")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }
}
