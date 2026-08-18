import SwiftUI

/// The strip under the action tiles: the four ways to keep hold of a flight,
/// or of its pilot, after you have closed the window.
///
/// Separate from `FlightActionRow` rather than a fourth and fifth tile on it,
/// because these are a different kind of thing. Those three act on the flight
/// now — how long it has been going, where it has been, sending it to someone.
/// These outlive the window: watching the pilot survives the flight entirely,
/// and the banner and the tile go on running with the app closed. Squeezing
/// them all onto one row would also have shrunk each of them past the point
/// where the labels read.
///
/// The profile chip is a fourth of the same kind: it leads to the person
/// rather than the aeroplane, and it is the thing that turns a name on the map
/// into somebody you can follow.
struct FlightWatchRow: View {

    let flight: Flight
    let theme: FlightInfoTheme

    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared
    @ObservedObject private var widgets = WidgetBridge.shared
    @ObservedObject private var push = PushService.shared

    /// Raised when the free watchlist is full — see `toggleWatch`.
    @State private var isShowingPaywall = false

    /// The pilot's Inflight profile, opened from the chip. Looked up by the
    /// name on the aeroplane, which most pilots have never claimed — the view
    /// says so rather than this having to check first.
    @State private var opened: ProfileLink?

    private var pilot: String? {
        guard let username = flight.username, !username.isEmpty else { return nil }
        return username
    }

    private var isWatching: Bool {
        pilot.map { friends.contains($0) } ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            // An aircraft with no pilot name attached — rare, but the feed does
            // it — has nobody to watch, so the chip isn't offered at all
            // rather than sitting there disabled.
            if let pilot = pilot {
                // The chip says "Pro" before it is tapped rather than after.
                // Tapping something that looks available and being shown a
                // paywall is the pattern people learn to distrust; a lock they
                // can see, and can still tap to find out about, is not.
                let locked = !isWatching
                    && !entitlements.canWatchMore(current: friends.count)

                chip(
                    symbol: isWatching ? "person.fill.checkmark"
                        : locked ? "lock" : "person.badge.plus",
                    title: isWatching ? "Watching" : locked ? "Pro" : "Watch",
                    isOn: isWatching
                ) {
                    toggleWatch(pilot)
                }
                .accessibilityLabel(
                    isWatching ? "Stop watching \(pilot)"
                        : locked ? "Watching \(pilot) needs Inflight Pro"
                        : "Watch \(pilot)"
                )
            }

            chip(
                symbol: "livephoto",
                title: "Banner",
                isOn: liveActivity.isTracking(flightId: flight.id)
            ) {
                if liveActivity.isTracking(flightId: flight.id) {
                    liveActivity.stop(flightId: flight.id)
                } else {
                    liveActivity.start(for: flight)
                }
            }
            .disabled(!liveActivity.isSupported)
            .opacity(liveActivity.isSupported ? 1 : 0.45)
            .accessibilityLabel("Live banner for this flight")

            if let pilot = pilot {
                chip(
                    symbol: "person.crop.circle",
                    title: "Profile",
                    isOn: false
                ) {
                    opened = .pilot(pilot)
                }
                .accessibilityLabel("Open \(pilot)'s Inflight profile")
            }

            chip(
                symbol: "square.grid.2x2",
                title: "Pin",
                isOn: widgets.isPinned(flight.id)
            ) {
                widgets.pin(widgets.isPinned(flight.id) ? nil : flight.id)
            }
            .accessibilityLabel("Pin this flight to the home screen widget")
        }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .watchlist) }
        .sheet(item: $opened) { link in PublicProfileView(link: link) }
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

    private func chip(
        symbol: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .flightInfoLine(minimumScale: 0.75)
            }
            .foregroundStyle(isOn ? theme.onAccent : theme.textSecondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                let shape = Capsule(style: .continuous)
                if isOn {
                    shape.fill(theme.accent)
                } else {
                    shape.fill(theme.surfaceFill)
                        .overlay { shape.strokeBorder(theme.stroke, lineWidth: 1) }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
