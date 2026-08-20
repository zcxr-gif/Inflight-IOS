import SwiftUI
import UIKit

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

                PanelToggleRow(
                    title: "It's on this device",
                    symbol: "iphone",
                    detail: sameDeviceDetail,
                    isOn: Binding(
                        get: { session.isSameDevice },
                        set: { session.isSameDevice = $0 }
                    )
                )

                PanelDivider()

                statusRow

                // Nothing to type when the simulator is right here.
                if session.isEnabled && !session.isSameDevice {
                    PanelDivider()
                    addressRow
                }
            }

            if session.isSameDevice { sameDeviceSection }

            sharingSection

            if session.status.isLive {
                liveSection
            }

            if let landing = session.lastLanding, landing.isRecorded {
                landingSection(landing)
            }

            atcSection

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
        case .waiting:              return "Waiting for Infinite Flight"
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
        case .waiting:     return "Waiting for Infinite Flight"
        }
    }

    private var statusDetail: String? {
        switch session.status {
        case let .waiting(reason):
            // The reason, and then the thing the old "Couldn't connect" never
            // said: nobody has to come back and press anything. The session
            // keeps trying on a backoff for as long as the switch is on, so
            // starting the sim at any point is enough.
            return reason + "\n\nStill trying. Start Infinite Flight whenever you like — "
                 + "this connects by itself and tells you when it does."
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
        // Amber rather than the red-adjacent orange a failure had: this is a
        // state that resolves itself.
        case .waiting:                 return .orange
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
               + "Or search the network for it.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            // The session goes back out to look by itself after a few failed
            // attempts, so this is not the only way out of a stale address --
            // it is the way out for somebody who already knows the sim moved
            // and would rather not wait through the backoff.
            if !session.host.isEmpty {
                Button {
                    addressFocused = false
                    typedHost = ""
                    session.searchAgain()
                } label: {
                    Label("Search the network again", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - One device

    private var sameDeviceDetail: String {
        session.isSameDevice
            ? "Talks to Infinite Flight over this device's own loopback. No Wi-Fi, no address, and no local network permission."
            : "Turn on if you fly on this same iPhone or iPad rather than a second device."
    }

    private var sameDeviceSection: some View {
        PanelSection(title: "ON ONE DEVICE") {
            VStack(alignment: .leading, spacing: 10) {

                if let result = session.lastCatchUp {
                    HStack(spacing: 8) {
                        Image(systemName: catchUpSymbol(result))
                            .font(.system(size: 12))
                            .foregroundStyle(catchUpColour(result))
                        Text(result.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                }

                Button {
                    Task { await session.catchUp() }
                } label: {
                    Text("Check for a landing now")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)

                bullet(isPad
                    ? "Open Inflight beside Infinite Flight in Split View and everything works live — the whole flight, as it happens."
                    : "While you fly, iOS suspends Inflight behind the simulator, so it cannot watch the flight itself.")

                bullet("Your flight is recorded from the map either way. Come back here after landing and the touchdown is read from the simulator and added to it — Infinite Flight keeps the last landing until the next one, so nothing has to be watching at the time.")

                bullet("It's checked automatically each time you open Inflight. The button above is for when you want to be sure.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func catchUpSymbol(_ result: ConnectSession.CatchUpResult) -> String {
        switch result {
        case .attached:              return "checkmark.circle.fill"
        case .nothingToAttach:       return "minus.circle"
        case .simulatorNotReachable: return "moon.zzz"
        }
    }

    private func catchUpColour(_ result: ConnectSession.CatchUpResult) -> Color {
        switch result {
        case .attached:              return .green
        case .nothingToAttach:       return theme.textDim
        case .simulatorNotReachable: return theme.textDim
        }
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
                if let fuel = session.telemetry.fuelRemainingKg, fuel > 0 {
                    reading("Fuel", fuel >= 1000
                            ? String(format: "%.1f t", fuel / 1000)
                            : "\(Int(fuel.rounded())) kg")
                }
                if let n1 = session.telemetry.engineN1, n1 > 0 {
                    reading("N1", "\(Int(n1.rounded()))%")
                }
                if let wind = session.telemetry.windSummary {
                    reading("Wind", wind)
                }
                if let squawk = session.telemetry.transponderCode {
                    reading("Squawk", String(format: "%04d", squawk))
                }
                // Only when true. A panel that says "Stalling: no" is a panel
                // nobody reads the day it says yes.
                if session.telemetry.isStalling == true {
                    reading("Warning", "Stalling")
                }
                if session.telemetry.isOverspeeding == true {
                    reading("Warning", "Overspeed")
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

    // MARK: - ATC

    @ViewBuilder
    private var atcSection: some View {
        if !session.atcLog.isEmpty {
            PanelSection(title: "ON FREQUENCY") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.atcLog) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            if let from = line.from {
                                Text(from.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(theme.accent)
                            }
                            Text(line.text)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("The last few things said on your frequency. Kept while you fly "
                       + "and thrown away afterwards — nothing here is recorded.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        } else if session.status.isLive,
                  session.unresolvedFields.contains(.atcMessage) {
            PanelSection(title: "ON FREQUENCY") {
                Text("This build of Infinite Flight doesn't publish ATC messages over "
                   + "Connect, so there is nothing to show. Everything else still works.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
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
            bullet(session.isSameDevice
                ? "On one device the live parts need both apps on screen at once, which is an iPad thing. Landings are picked up whatever you fly on."
                : "Works only while Infinite Flight is running on another device on this Wi-Fi. Flights flown anywhere else are still recorded, just without the landing.")
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
