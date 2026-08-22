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
    @ObservedObject private var push = PushService.shared

    @State private var typedHost: String = ""
    @FocusState private var addressFocused: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Infinite Flight Connect", subtitle: subtitle) {

            PanelSection(title: "CONNECTION") {
                PanelToggleRow(
                    title: "Read from the sim",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: readDetail,
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

                PanelToggleRow(
                    title: "Tell me when it connects",
                    symbol: "bell",
                    detail: noticesDetail,
                    isOn: Binding(
                        get: { session.announcesConnection },
                        set: { session.announcesConnection = $0 }
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

    /// What the switch needs, which is not the same sentence on one device as
    /// on two — and the two-device sentence read as a flat contradiction of the
    /// switch below it to anybody flying on this phone.
    private var readDetail: String {
        if session.isSameDevice {
            return "Reads your aircraft straight from Infinite Flight on this device. "
                 + "Needs Connect switched on in the sim, under Settings → General."
        }
        return "Reads your aircraft straight from Infinite Flight over Wi-Fi. Needs the "
             + "sim running on another device on this network, with Connect switched on "
             + "in its settings."
    }

    /// Why anybody would want the banner, and why anybody would want it gone.
    private var noticesDetail: String {
        if session.announcesConnection {
            return "A banner when the link is made, and one saying why when it isn't. It "
                 + "arrives on top of Infinite Flight, which on one device is the only place "
                 + "you could see it."
        }
        return "No banners. The panel still says what happened — you just have to come and "
             + "look."
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

                if let attempt = attemptLine {
                    Text(attempt)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
            // The reason, and one short line for the thing the old "Couldn't
            // connect" never said: nobody has to come back and press anything.
            // That used to be a paragraph, which is a lot of words to read
            // every time the sim is simply not open yet.
            return reason + "\n\nStill trying."
        case .live:               return session.manifestSummary
        case .searching:
            return "Infinite Flight announces itself on the network while Connect is on. "
                 + "If nothing is found, enter the device's address below."
        default: return nil
        }
    }

    /// Proof that something is happening, or proof that nothing is.
    ///
    /// The status word alone reads identically whether the session is knocking
    /// on the sim once a second or has never once run — which is exactly the
    /// confusion that costs an evening: a pilot with the master switch off sees
    /// a screen that looks like a connection failing rather than a feature that
    /// was never started.
    private var attemptLine: String? {
        guard session.isEnabled else { return "Not running — turn on Read from the sim" }
        guard let attempt = session.lastAttempt else { return "No attempt yet" }

        let ago = Self.relative.localizedString(for: attempt.at, relativeTo: Date())
        return attempt.succeeded
            ? "Connected \(ago) · \(attempt.address)"
            : "Last tried \(ago) · \(attempt.address)"
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
        if !session.isEnabled {
            // The trap this row used to be: it moved, and nothing ran, because
            // everything is gated on the switch above it. Turning it on now
            // turns that one on too, and this says so rather than leaving the
            // pilot to infer it from a screen where nothing happens.
            return "Reading from the sim is off, so nothing is running. Turning this on turns "
                 + "it back on — the switch above is the feature, this one only says where the "
                 + "simulator is."
        }
        return session.isSameDevice
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

                bullet("Both switches above have to be on. \"Read from the sim\" is the feature; \"It's on this device\" only says where the simulator is.")

                bullet("Infinite Flight answers only while it is running, and this app runs only while it is not behind it — so the link is made in the moments either side of a switch. Inflight keeps trying for about half a minute after you leave it, and again the instant you come back.")

                bullet("The order that works: open Infinite Flight, let it finish loading, then switch back here. Coming back is usually the attempt that succeeds, because the sim is still awake behind you — and the notification arrives then.")

                bullet("Your flight is recorded from the map either way. Come back here after landing and the touchdown is read from the simulator and added to it — Infinite Flight keeps the last landing until the next one, so nothing has to be watching at the time.")

                bullet("It's checked automatically each time you open Inflight. The button above is for when you want to be sure.")

                if !push.canNotify { notificationsOff }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var notificationsOffText: String {
        if push.authorization == .denied {
            return "Notifications are off, so there is no way to tell you whether this "
                 + "connected — it happens while you are in Infinite Flight. Turning them "
                 + "back on lives in iOS Settings."
        }
        return "Allow notifications and you'll be told, on top of Infinite Flight, whether "
             + "Inflight managed to read the sim."
    }

    /// Shown only while notifications are off, and only on one device.
    ///
    /// Everywhere else in the app a notification is a convenience. Here it is
    /// the only channel there is: the moment the link is made is a moment the
    /// pilot is inside Infinite Flight, so a panel cannot tell them and a
    /// banner is the whole of the answer to "did it connect?".
    private var notificationsOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notificationsOffText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if push.authorization == .denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    push.requestAuthorization()
                }
            } label: {
                Text(push.authorization == .denied ? "Open Settings" : "Allow notifications")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func catchUpSymbol(_ result: ConnectSession.CatchUpResult) -> String {
        switch result {
        case .attached:              return "checkmark.circle.fill"
        case .nothingToAttach:       return "minus.circle"
        case .simulatorNotReachable: return "moon.zzz"
        case .needsAccount:          return "person.crop.circle.badge.exclamationmark"
        case .refused:               return "questionmark.circle"
        }
    }

    private func catchUpColour(_ result: ConnectSession.CatchUpResult) -> Color {
        switch result {
        case .attached:              return .green
        case .nothingToAttach:       return theme.textDim
        case .simulatorNotReachable: return theme.textDim
        case .needsAccount:          return .orange
        case .refused:               return theme.textDim
        }
    }

    /// The sim says one name and the profile says another.
    ///
    /// Worth a whole block because it is the likeliest reason a pilot who has
    /// set everything up correctly hears nothing about their own flight: the
    /// server looks for the name on the profile, the map shows the name in the
    /// sim, and when they differ the join between the two simply does not
    /// exist. Not fixed silently — a profile is public, and the handle on it is
    /// the pilot's to choose.
    private func identityMismatch(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your profile says @\(profiles.profile?.ifUsername ?? "") and the sim says "
               + "\(name). Announcements about your own flight are addressed by the name on "
               + "your profile, so while these differ they cannot reach you.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await profiles.replaceIFUsername(with: name) }
            } label: {
                Text("Use \(name)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
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

            if let blocker = sharingBlocker {
                PanelDivider()

                Text(blocker)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }

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

    /// Why the flight window is empty, in the order the publisher checks.
    ///
    /// Every one of these is a condition `LiveStatusPublisher.publishIfAble`
    /// returns silently on, and a silent return looks identical from the
    /// outside to a feature that does not work. The switch being off is the
    /// commonest by a distance — it is a second switch, defaulting off, on a
    /// screen whose first switch is the one everybody is thinking about — and
    /// the position being unpublished is the one nobody would ever guess.
    ///
    /// Only shown once the sim is actually attached. Before that there is
    /// nothing to publish and saying so would be nagging.
    private var sharingBlocker: String? {
        guard session.status.isLive else { return nil }

        if !publisher.isSharing {
            return "Nothing about this flight is being sent anywhere, so your flight window "
                 + "has nothing to show. That is what the switch above does."
        }
        if !profiles.hasProfile {
            return "Sign in and claim a handle. A live status belongs to a profile, and "
                 + "there is nowhere to put one without it."
        }
        if !session.telemetry.hasPosition {
            return "This aircraft isn't publishing a position over Connect, so there is "
                 + "nothing to send. See NOT PUBLISHED BY THIS AIRCRAFT below — that list "
                 + "is what to send me."
        }
        if publisher.lastPublished == nil {
            return "Connected, and nothing sent yet. The first row goes out on the first "
                 + "full pass; if this stays here, the reason is above or below it."
        }
        return nil
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
                if let mismatch = session.simUsernameMismatch { identityMismatch(mismatch) }
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
                if let atc = session.telemetry.atcFacility {
                    reading("On frequency", atc)
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
                VStack(alignment: .leading, spacing: 8) {
                    if let atc = session.telemetry.atcFacility {
                        Text("Tuned to \(atc).")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                    }

                    // Two different things, and conflating them is what makes
                    // this look broken: the comm radio publishes the name of
                    // the controller, and that is all it publishes. The
                    // transcript is a separate pushed stream that this build of
                    // Infinite Flight does not appear to expose at all.
                    Text(atcNoTranscriptText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    /// Why a panel headed "on frequency" has no words on it.
    ///
    /// The comm radio publishes who you are tuned to and nothing else. The
    /// transcript is a separate pushed stream that this build of Infinite
    /// Flight does not appear to expose, and saying so is better than an empty
    /// box that looks like a bug in this app.
    private var atcNoTranscriptText: String {
        if session.telemetry.atcFacility == nil {
            return "Nothing on frequency. Infinite Flight publishes the controller's name "
                 + "over Connect but not what is said, so there is no transcript to show — "
                 + "everything else still works."
        }
        return "Infinite Flight publishes the controller's name over Connect but not the "
             + "messages themselves, so this is as far as it goes. Everything else still "
             + "works."
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
