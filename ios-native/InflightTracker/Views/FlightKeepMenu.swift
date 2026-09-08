import SwiftUI

/// The three ways to keep hold of a flight after the window is shut, behind one
/// button.
///
/// ## Why they are a menu now
///
/// They were four chips in a row of their own: Watch, Banner, Profile, Pin.
/// Four controls, each with an icon and a word, each about a *different* thing
/// — one about the pilot, one about the lock screen, one about a person, one
/// about the home screen — sitting in a strip that read as a set because they
/// were adjacent rather than because they were alike.
///
/// Two of them have also stopped needing a chip at all. Profile is gone
/// entirely: the pilot block above is the profile now, and a tap on somebody's
/// name is a better way in than a chip four along a row. And what is left is
/// three switches, which is what a menu is for — you throw one of these
/// perhaps once a flight, where Replay and Share are the things you reach for
/// while looking. So the row belongs to those, and these fold into a button on
/// the end of it.
///
/// ## What is not lost by folding them away
///
/// A menu hides state, and two of these three are stateful in a way that
/// matters — whether you are watching a pilot, and whether a Live Activity is
/// running, are things you should be able to see without opening anything. So
/// the button itself is filled whenever any of the three is on, and its icon
/// becomes the one that is: the menu is closed, and the window still says
/// there is something running.
struct FlightKeepMenu: View {

    let flight: Flight
    let theme: FlightInfoTheme

    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared
    @ObservedObject private var widgets = WidgetBridge.shared
    @ObservedObject private var push = PushService.shared

    /// Raised when the free watchlist is full — see `toggleWatch`.
    @State private var isShowingPaywall = false

    private var pilot: String? {
        guard let username = flight.username, !username.isEmpty else { return nil }
        return username
    }

    private var isWatching: Bool {
        pilot.map { friends.contains($0) } ?? false
    }

    private var isBannering: Bool { liveActivity.isTracking(flightId: flight.id) }

    private var isPinned: Bool { widgets.isPinned(flight.id) }

    private var isOn: Bool { isWatching || isBannering || isPinned }

    /// Which of the three the closed button reports.
    ///
    /// Watching first, because it is the one that outlives the flight; then the
    /// banner, which is running right now; then the pin. The ellipsis when
    /// nothing is on, which is the only case where the button is about what it
    /// can do rather than about what it is doing.
    private var symbol: String {
        if isWatching { return "person.fill.checkmark" }
        if isBannering { return "livephoto" }
        if isPinned { return "square.grid.2x2.fill" }
        return "ellipsis"
    }

    var body: some View {
        Menu {
            if let pilot = pilot {
                Button {
                    toggleWatch(pilot)
                } label: {
                    Label(
                        isWatching ? "Stop watching \(pilot)" : "Watch \(pilot)",
                        systemImage: watchSymbol
                    )
                }
            }

            Button {
                if isBannering {
                    liveActivity.stop(flightId: flight.id)
                } else {
                    liveActivity.start(for: flight)
                }
            } label: {
                Label(
                    isBannering ? "Stop the live banner" : "Live banner",
                    systemImage: isBannering ? "livephoto.slash" : "livephoto"
                )
            }
            .disabled(!liveActivity.isSupported)

            Button {
                widgets.pin(isPinned ? nil : flight.id)
            } label: {
                Label(
                    isPinned ? "Unpin from the widget" : "Pin to the widget",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        } label: {
            face
        }
        .accessibilityLabel("Keep hold of this flight")
        .accessibilityValue(accessibilityState)
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .watchlist) }
    }

    /// The icon on the watch item.
    ///
    /// Says "Pro" before it is tapped rather than after — the chip this
    /// replaced did the same, and for the same reason: being shown a paywall
    /// by something that looked available is the pattern people learn to
    /// distrust.
    private var watchSymbol: String {
        if isWatching { return "person.fill.badge.minus" }
        return entitlements.canWatchMore(current: friends.count) ? "person.badge.plus" : "lock"
    }

    private var accessibilityState: String {
        var running: [String] = []
        if isWatching, let pilot = pilot { running.append("watching \(pilot)") }
        if isBannering { running.append("live banner on") }
        if isPinned { running.append("pinned to the widget") }
        return running.isEmpty ? "Nothing running" : running.joined(separator: ", ")
    }

    /// The button, sized and dressed to be the fourth tile of the action row it
    /// sits on the end of.
    private var face: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                .frame(height: 18)
                .motionWords(symbol)

            Text("Keep")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            // The same reserved caption line the tiles keep, so this sits on
            // their baseline instead of floating a caption's height above it.
            Text(" ")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background {
            if isOn {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .fill(theme.accent)
            }
        }
        .flightInfoSurface(theme, radius: theme.radiusSmall, interactive: true)
        .contentShape(Rectangle())
        .motion(Motion.control, value: isOn)
    }

    /// Taking somebody *off* the list is never gated — a full list must still
    /// be a list you can make room in — so only the adding branch can be
    /// refused, and the store is what refuses it. This reads the answer rather
    /// than repeating the check.
    private func toggleWatch(_ pilot: String) {
        switch friends.toggle(pilot) {
        case nil, .alreadyWatching, .unusableName:
            break

        case .needsPro:
            isShowingPaywall = true

        case .added:
            // The first pilot somebody watches is the moment the permission
            // prompt has something concrete to be about, so it is asked here
            // rather than at launch.
            if push.authorization == .notDetermined {
                push.requestAuthorization()
            }
        }
    }
}
