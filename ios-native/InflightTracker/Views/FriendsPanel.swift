import SwiftUI
import UIKit

/// The friends list, from the toolbar's first button.
///
/// Three things in one panel, in the order they matter: who is flying right
/// now, who is on the list, and what the app is allowed to tell you about
/// them. The live half is first on purpose — most of the time this is opened
/// to answer "is anyone up?", not to change a setting.
struct FriendsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared

    /// Focuses the map on a friend's aircraft and closes the panel.
    let onSelect: (Flight) -> Void

    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var isTyping: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    /// Watched pilots the feed can currently see, keyed by lowercased name.
    /// Built once per render rather than searched per row — the packet is
    /// thousands of aircraft and the list is not.
    private var flying: [String: Flight] {
        let watched = Set(friends.friends)
        guard !watched.isEmpty else { return [:] }
        var found: [String: Flight] = [:]
        for flight in feed.flights {
            guard let username = flight.username?.lowercased(), watched.contains(username) else { continue }
            found[username] = flight
        }
        return found
    }

    var body: some View {
        let aloft = flying

        MapPanel(title: "Friends", subtitle: summary(aloft: aloft.count)) {
            if !push.canNotify { permissionSection }

            addSection

            if friends.friends.isEmpty {
                PanelSection(title: "WATCHING") {
                    PanelEmptyState(
                        symbol: "person.2",
                        title: "Nobody on the list",
                        detail: "Add an Infinite Flight display name above, or open an aircraft and add the pilot from its window."
                    )
                }
            } else {
                PanelSection(title: "WATCHING") {
                    ForEach(Array(friends.friends.enumerated()), id: \.element) { index, username in
                        if index > 0 { PanelDivider() }
                        FriendRow(
                            username: username,
                            flight: aloft[username],
                            theme: theme,
                            isTracking: aloft[username].map { liveActivity.isTracking(flightId: $0.id) } ?? false,
                            onOpen: { flight in onSelect(flight) },
                            onTrack: { flight in toggleTracking(flight) },
                            onRemove: { friends.remove(username) }
                        )
                    }
                }
            }

            notificationsSection

            if !friends.friends.isEmpty { widgetSection }

            HintStrip(placement: .friends)
        }
    }

    private func summary(aloft: Int) -> String {
        guard !friends.friends.isEmpty else { return "Nobody watched yet" }
        let people = friends.count == 1 ? "1 pilot" : "\(friends.count) pilots"
        return aloft == 0 ? "\(people) · none flying" : "\(people) · \(aloft) flying now"
    }

    // MARK: - Permission

    /// Only shown while notifications are actually off. A standing "turn on
    /// notifications" banner in a panel people open to check on their friends
    /// is nagging; this disappears the moment it is dealt with.
    private var permissionSection: some View {
        PanelSection(title: "NOTIFICATIONS ARE OFF") {
            VStack(alignment: .leading, spacing: 10) {
                Text(push.authorization == .denied
                     ? "Notifications were declined, so takeoffs can't be announced. Turning them back on lives in iOS Settings."
                     : "Allow notifications and you'll be told the moment a watched pilot leaves the ground.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                                .fill(theme.accent)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Adding

    private var addSection: some View {
        PanelSection(title: "ADD A PILOT") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "at")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textDim)

                    TextField("Display name", text: $draft)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isTyping)
                        .onSubmit(commit)

                    Button(action: commit) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canCommit ? theme.onAccent : theme.textDim)
                            .frame(width: 28, height: 28)
                            .background {
                                Circle().fill(canCommit ? theme.accent : theme.surfaceFill)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                }

                if let problem = problem {
                    Text(problem)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                } else {
                    Text("Their Infinite Flight display name, spelled the way it appears on the map.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var canCommit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if friends.add(name) {
            draft = ""
            problem = nil
            isTyping = false
            // Asking at the moment the list stops being empty, rather than on
            // first launch: by now the permission prompt has something to be
            // about.
            if friends.count == 1, push.authorization == .notDetermined {
                push.requestAuthorization()
            }
        } else {
            problem = friends.contains(name)
                ? "\(name) is already on your list."
                : "That doesn't look like a display name."
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        PanelSection(title: "TELL ME WHEN") {
            PanelToggleRow(
                title: "They take off",
                symbol: "airplane.departure",
                detail: "The moment the aircraft actually leaves the ground, not when they spawn in.",
                isOn: $friends.preferences.takeoff
            )

            PanelDivider()

            PanelToggleRow(
                title: "They land",
                symbol: "airplane.arrival",
                isOn: $friends.preferences.landing
            )

            PanelDivider()

            PanelToggleRow(
                title: "They come online",
                symbol: "dot.radiowaves.left.and.right",
                isOn: $friends.preferences.online
            )

            PanelDivider()

            PanelToggleRow(
                title: "They go offline",
                symbol: "moon.zzz",
                detail: "Off by default — on a busy evening this one talks a lot.",
                isOn: $friends.preferences.offline
            )

            PanelDivider()

            PanelToggleRow(
                title: "Live banner on takeoff",
                symbol: "rectangle.inset.filled.badge.record",
                detail: liveActivity.isSupported
                    ? "Puts the flight on your lock screen and Dynamic Island, and keeps it counting down until they land."
                    : "Live Activities are switched off for Inflight in iOS Settings.",
                isOn: $friends.preferences.liveActivity
            )
            .disabled(!liveActivity.isSupported)
            .opacity(liveActivity.isSupported ? 1 : 0.5)
        }
    }

    // MARK: - Widgets

    private var widgetSection: some View {
        PanelSection(title: "HOME SCREEN") {
            VStack(alignment: .leading, spacing: 6) {
                PanelRowLabel(title: "Widgets", symbol: "square.grid.2x2.fill")
                Text("Add the Inflight widget from the home screen to keep your friends — or one flight you've pinned from its window — on a tile, drawn on the aircraft's own photo.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func toggleTracking(_ flight: Flight) {
        if liveActivity.isTracking(flightId: flight.id) {
            liveActivity.stop(flightId: flight.id)
        } else {
            liveActivity.start(for: flight)
        }
    }
}

/// One watched pilot: who they are, what they're doing, and the two things you
/// might want to do about it.
private struct FriendRow: View {

    let username: String
    let flight: Flight?
    let theme: FlightInfoTheme
    let isTracking: Bool

    let onOpen: (Flight) -> Void
    let onTrack: (Flight) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let flight = flight { onOpen(flight) }
            } label: {
                HStack(spacing: 10) {
                    statusDot

                    VStack(alignment: .leading, spacing: 2) {
                        Text(username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.8)

                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .flightInfoLine(minimumScale: 0.8)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flight == nil)

            if let flight = flight {
                Button { onTrack(flight) } label: {
                    Image(systemName: isTracking ? "livephoto.badge.automatic" : "livephoto")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isTracking ? theme.onAccent : theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background {
                            Circle().fill(isTracking ? theme.accent : theme.surfaceFill)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTracking ? "Stop the live banner" : "Show a live banner for this flight")
            }

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textDim)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop watching \(username)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Filled while they are on the server, hollow while they are not — the
    /// same monochrome logic the rest of the window uses, with no colour
    /// carrying meaning on its own.
    private var statusDot: some View {
        Circle()
            .fill(flight == nil ? Color.clear : theme.accent)
            .frame(width: 7, height: 7)
            .overlay {
                Circle().strokeBorder(flight == nil ? theme.textDim : .clear, lineWidth: 1)
            }
            .frame(width: 20)
    }

    private var detail: String {
        guard let flight = flight else { return "Not on this server" }

        let phase = FlightPhase.from(flight)
        let route = "\(flight.departureIcao ?? "————") → \(flight.arrivalIcao ?? "————")"

        switch phase {
        case .ground:
            return "\(route) · on the ground"
        default:
            return "\(route) · \(Format.number(flight.altitudeFeet)) ft"
        }
    }
}
