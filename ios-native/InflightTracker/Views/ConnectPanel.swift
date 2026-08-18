import SwiftUI

/// The link to Infinite Flight itself.
///
/// This panel has one job the others do not: explaining a feature whose most
/// important property is that it does not always work. Connect is a local
/// network API served by the sim, so it needs a second device, the same Wi-Fi,
/// and a switch inside Infinite Flight — and when any of those is missing the
/// honest thing to show is why, not a spinner.
struct ConnectPanel: View {

    @ObservedObject private var session = ConnectSession.shared
    @ObservedObject private var publisher = LiveStatusPublisher.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var typedHost: String = ""
    @FocusState private var addressFocused: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Infinite Flight Connect", subtitle: subtitle) {

            PanelSection(title: "CONNECTION") {
                PanelToggleRow(
                    title: "Read from the sim",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: "Reads your aircraft straight from Infinite Flight over Wi-Fi. "
                          + "Needs the sim running on another device on this network, with "
                          + "Connect switched on in its settings.",
                    isOn: Binding(
                        get: { session.isEnabled },
                        set: { session.isEnabled = $0 }
                    )
                )

                PanelDivider()

                statusRow

                if session.isEnabled {
                    PanelDivider()
                    addressRow
                }
            }

            sharingSection

            if session.status.isLive {
                liveSection
            }

            if let landing = session.lastLanding, landing.isRecorded {
                landingSection(landing)
            }

            PanelSection(title: "WHAT THIS ADDS") {
                explanation
            }

            if !session.unresolvedFields.isEmpty {
                PanelSection(title: "NOT PUBLISHED BY THIS AIRCRAFT") {
                    unresolved
                }
            }
        }
        .onAppear { typedHost = session.host }
    }

    private var subtitle: String? {
        switch session.status {
        case .off:                  return session.isEnabled ? "Idle" : "Off"
        case .searching:            return "Looking for Infinite Flight…"
        case let .connecting(host): return "Connecting to \(host)"
        case let .syncing(host):    return "Reading the manifest from \(host)"
        case let .live(host):       return "Live from \(host)"
        case .failed:               return "Not connected"
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColour)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)

                if let detail = statusDetail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if session.status.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusTitle: String {
        switch session.status {
        case .off:         return session.isEnabled ? "Waiting" : "Not reading the sim"
        case .searching:   return "Searching the network"
        case .connecting:  return "Connecting"
        case .syncing:     return "Reading what this aircraft publishes"
        case .live:        return "Connected"
        case .failed:      return "Couldn't connect"
        }
    }

    private var statusDetail: String? {
        switch session.status {
        case let .failed(reason): return reason
        case .live:               return session.manifestSummary
        case .searching:
            return "Infinite Flight announces itself on the network while Connect is on. "
                 + "If nothing is found, enter the device's address below."
        default: return nil
        }
    }

    private var statusColour: Color {
        switch session.status {
        case .live:                    return .green
        case .failed:                  return .orange
        case .searching, .connecting, .syncing: return theme.accent
        case .off:                     return theme.textDim
        }
    }

    // MARK: - Address

    private var addressRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            PanelRowLabel(title: "Device address", symbol: "network")

            HStack(spacing: 8) {
                TextField("192.168.1.42", text: $typedHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .focused($addressFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(theme.stroke.opacity(0.5))
                    )

                Button("Connect") {
                    addressFocused = false
                    session.connect(to: typedHost)
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(typedHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Find it in Infinite Flight under Settings → General → Infinite Flight Connect. "
               + "Leave it blank to search the network instead.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Sharing

    private var sharingSection: some View {
        PanelSection(title: "SHOW OTHER PILOTS") {
            PanelToggleRow(
                title: "Share what the sim reports",
                symbol: "dot.radiowaves.up.forward",
                detail: sharingDetail,
                isOn: Binding(
                    get: { publisher.isSharing },
                    set: { publisher.isSharing = $0 }
                )
            )

            if publisher.isSharing {
                PanelDivider()

                VStack(alignment: .leading, spacing: 8) {
                    if !profiles.hasProfile {
                        Text("Claim a handle first — a live status belongs to a profile, "
                           + "and there is nowhere to show one without it.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let published = publisher.lastPublished {
                        reading("Last sent", Self.relative.localizedString(for: published, relativeTo: Date()))
                    } else if session.status.isLive {
                        reading("Last sent", "not yet")
                    }

                    if let problem = publisher.problem {
                        Text(problem)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Who can see it is set on your profile, under Live status. "
                       + "It defaults to people who follow you — where you are now is a "
                       + "different thing from where you have been.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private var sharingDetail: String {
        publisher.isSharing
            ? "Your position, phase of flight and configuration go on your profile while you fly. Turning this off deletes it."
            : "Put what the sim is reporting on your profile, so people who follow you can see you flying."
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    // MARK: - Live telemetry

    private var liveSection: some View {
        PanelSection(title: "FROM THE SIM") {
            VStack(alignment: .leading, spacing: 9) {
                if let username = session.telemetry.username {
                    reading("Pilot", username)
                }
                if let server = session.telemetry.serverName {
                    reading("Server", server)
                }
                if let flight = session.telemetry.flightID {
                    // Shown truncated: it is a uuid, it is not for reading, and
                    // it being present at all is the point — it is what ties
                    // this session to the aeroplane on the map.
                    reading("Flight", String(flight.prefix(8)) + "…")
                }
                if let altitude = session.telemetry.altitudeMSL {
                    reading("Altitude", "\(Int(altitude.rounded())) ft")
                }
                if let speed = session.telemetry.groundSpeed {
                    reading("Ground speed", "\(Int(speed.rounded())) kt")
                }
                if let rate = session.telemetry.verticalSpeed {
                    reading("Vertical speed", "\(Int(rate.rounded())) fpm")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private func reading(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
        }
    }

    // MARK: - The landing

    private func landingSection(_ landing: ConnectLanding) -> some View {
        PanelSection(title: "LAST LANDING") {
            VStack(alignment: .leading, spacing: 9) {
                if let rate = landing.verticalSpeedFPM {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(Int(rate.rounded()))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                        Text("fpm")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        Spacer(minLength: 0)
                        if let verdict = landing.verdict {
                            Text(verdict)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(theme.accent.opacity(0.18)))
                                .foregroundStyle(theme.accent)
                        }
                    }
                }

                if let g = landing.maxGForce {
                    reading("Peak g", String(format: "%.2f", g))
                }
                if let score = landing.score {
                    reading("Score", "\(Int(score.rounded()))")
                }
                if let centre = landing.centrelineOffsetMetres {
                    reading("Off centreline", "\(Int(abs(centre).rounded())) m")
                }
                if let aim = landing.aimingPointOffsetMetres {
                    reading("From aiming point", "\(Int(aim.rounded())) m")
                }
                if let speed = landing.groundSpeedKnots {
                    reading("Touchdown speed", "\(Int(speed.rounded())) kt")
                }

                Text("Measured by Infinite Flight, not worked out from the map. "
                   + "It goes on the flight in your logbook.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Copy

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            bullet("Your landing rate, g-force and how straight you put it down — "
                 + "numbers the map can never measure, because a touchdown is over "
                 + "before the next position arrives.")
            bullet("The flight your logbook records is confirmed by the sim rather "
                 + "than matched by name.")
            bullet("Works only while Infinite Flight is running on another device on "
                 + "this Wi-Fi. Flights flown anywhere else are still recorded, just "
                 + "without the landing.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(theme.textDim)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unresolved: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.unresolvedFields.map(\.rawValue).joined(separator: ", "))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Different aircraft publish different things, and Infinite Flight "
               + "renames states between versions. Anything listed here is simply "
               + "not shown; nothing else is affected.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
