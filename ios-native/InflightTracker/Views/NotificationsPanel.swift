import SwiftUI
import UIKit
import UserNotifications

/// Everything the app is allowed to tell you, on one screen.
///
/// The switches used to be a section at the foot of the friends list, and that
/// was the right place for them while they were four toggles about four other
/// people. They are not that any more. There are two directions now — what a
/// pilot you are watching is doing, and what your own aeroplane is doing — and
/// the second one is not about friends at all, so putting it under a heading
/// called "friends" would file the most personal notice the app sends under
/// somebody else's name.
///
/// The other half of why this is its own screen: notifications are the feature
/// with the most ways to be switched on and still not arrive. Permission can be
/// denied, the APNs token can be missing, the backend can be running without a
/// push key, and an own-flight notice additionally needs an account and a way to
/// tell which aeroplane on the map is yours. Every one of those fails silently.
/// A panel that lists the switches and *not* the state of the chain underneath
/// them is a panel that says "on" to somebody who will never hear a thing —
/// which is exactly the report this was built to answer. So the chain is drawn,
/// in order, at the bottom, with the first broken link the one thing offering to
/// be fixed.
struct NotificationsPanel: View {

    @EnvironmentObject private var feed: LiveFeed

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var identity = PilotIdentity.shared

    /// The photograph over the top, and whoever took it.
    @StateObject private var loader = RemoteImageLoader()
    @State private var photo: AircraftPhoto?

    /// The aeroplane this panel is about — see `resolveSubject`.
    ///
    /// Held rather than computed, for the reason the map's own derived state is
    /// held: finding it is a walk over the whole server, and a view's body runs
    /// far more often than a packet arrives. Four places read it, so computing
    /// it would be four scans per redraw of a screen that redraws on every
    /// switch that is flipped on it.
    @State private var subject: Flight?

    /// The sample banner, held back for a beat after the panel opens so it
    /// arrives rather than being there — see `hero`.
    @State private var isPreviewShowing = false

    @State private var isShowingAccount = false
    @State private var isShowingConnect = false

    /// Set for a few seconds after the test notification is sent, so the row
    /// can say what happened without a sheet or an alert.
    @State private var testFeedback: String?

    private var theme: FlightInfoTheme { appearance.theme }

    private var preferences: FriendsStore.NotificationPreferences { friends.preferences }

    var body: some View {
        MapPanel(title: "Notifications", subtitle: summary) {
            hero
                .panelEntrance(0)

            if !push.canNotify {
                permissionSection.panelEntrance(1)
            }

            ownFlightSection.panelEntrance(2)

            watchlistSection.panelEntrance(3)

            deliverySection.panelEntrance(4)

            HintStrip(placement: .notifications)
                .panelEntrance(5)
        }
        .onAppear {
            resolveSubject()
            // A tenth of a second is under the time the sheet itself takes to
            // finish arriving, so the banner lands on a window that has already
            // stopped moving — which is the difference between a preview that
            // pops and one that is dragged in with the sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(Motion.panel) { isPreviewShowing = true }
            }
        }
        // Keyed on the packet's stamp rather than on the array, which is
        // rebuilt in full every time one lands.
        .onChange(of: feed.lastUpdate) { _, _ in resolveSubject() }
        .onChange(of: identity.username) { _, _ in resolveSubject() }
        .onChange(of: friends.friends) { _, _ in resolveSubject() }
        .sheet(isPresented: $isShowingAccount) { AccountPanel().environmentObject(feed) }
        .sheet(isPresented: $isShowingConnect) { ConnectPanel() }
    }

    // MARK: - The picture, and what a notification looks like

    /// The aeroplane the panel should be about, in the order it is worth being
    /// about: yours, then whichever watched pilot is flying, then nothing.
    ///
    /// Nothing is a perfectly good answer — the hero falls back to the sprite
    /// for the type, which is what every other photo in the app does when the
    /// lookup has nothing.
    private func resolveSubject() {
        let found = findSubject()

        // Assigning an identical flight would still publish a change and redraw
        // the panel on every packet.
        guard found?.id != subject?.id else { return }
        subject = found
        fetchPhoto()
    }

    private func findSubject() -> Flight? {
        if identity.isSet, let mine = feed.flights.first(where: { identity.isMe($0.username) }) {
            return mine
        }
        let watched = friends.watched
        guard !watched.isEmpty else { return nil }
        return feed.flights.first { flight in
            guard let username = flight.username?.lowercased() else { return false }
            return watched.contains(username)
        }
    }

    /// A photograph with a notification lying on it.
    ///
    /// This is the panel's whole argument in one picture: the thing being
    /// configured is a banner about an aeroplane, so the screen that configures
    /// it shows a banner about an aeroplane. It is drawn from live data where
    /// there is any — your flight, or a watched pilot's — so most of the time it
    /// is not a mock-up at all but the exact notice the switches below would
    /// produce for the aircraft in the picture.
    private var hero: some View {
        ZStack(alignment: .bottom) {
            AircraftPhotoImage(
                image: loader.image,
                spriteKey: subject?.spriteKey ?? AircraftCatalog.spriteKey(for: nil),
                theme: theme,
                iconSize: 54,
                contentMode: .fill
            )
            .frame(height: 176)

            // The photograph is somebody's holiday snap and the banner has to
            // read over all of them, so the card gets its own darkness under it
            // rather than trusting the picture to be dark.
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            samplePreview
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .opacity(isPreviewShowing ? 1 : 0)
                // Comes up from under the bottom edge of the photograph and
                // settles, which is the movement a real banner makes.
                .offset(y: isPreviewShowing ? 0 : 26)
                .scaleEffect(isPreviewShowing ? 1 : 0.94, anchor: .bottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                .strokeBorder(theme.strokeStrong, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if let contributor = photo?.contributor {
                Text("© \(contributor)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background { Capsule().fill(.black.opacity(0.35)) }
                    .padding(8)
            }
        }
    }

    /// A lock-screen banner, drawn the way iOS draws one.
    private var samplePreview: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accent)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.onAccent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(sampleTitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .flightInfoLine(minimumScale: 0.7)

                Text(sampleBody)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("now")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        // Real content where there is any, so the wording changes when the
        // aeroplane does.
        .motion(Motion.content, value: sampleTitle)
    }

    private var sampleTitle: String {
        guard let flight = subject else { return "\(approachMinutes) minutes out" }
        if identity.isMe(flight.username) { return "\(approachMinutes) minutes out" }
        return flight.username ?? "A pilot you watch"
    }

    private var sampleBody: String {
        guard let flight = subject else {
            return "About \(approachMinutes) minutes to your destination at your current speed."
        }
        let route = [flight.departureIcao, flight.arrivalIcao].compactMap { $0 }
        if identity.isMe(flight.username) {
            guard let arrival = flight.arrivalIcao else {
                return "About \(approachMinutes) minutes to your destination at your current speed."
            }
            return "About \(approachMinutes) minutes to \(arrival) at your current speed."
        }
        guard route.count == 2 else { return "Airborne · \(flight.aircraftName)" }
        return "\(route[0]) → \(route[1]) · \(flight.aircraftName)"
    }

    /// The number the backend actually fires at, not a number written twice.
    private var approachMinutes: Int {
        friends.capabilities?.approachMinutes ?? 30
    }

    // MARK: - Permission

    private var permissionSection: some View {
        PanelSection(title: "PERMISSION") {
            Button {
                if push.authorization == .denied {
                    openSystemSettings()
                } else {
                    push.requestAuthorization()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        PanelRowLabel(
                            title: push.authorization == .denied
                                ? "Turn notifications on in Settings"
                                : "Allow notifications",
                            symbol: "bell.badge"
                        )

                        Text(push.authorization == .denied
                             ? "You said no to this once, and iOS will not ask twice — the switch lives in Settings now. Nothing below can arrive until it is on."
                             : "Nothing on this screen can reach you until iOS is allowed to show a banner.")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .padding(.leading, 30)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    // MARK: - Your own flight

    private var ownFlightSection: some View {
        PanelSection(title: "YOUR OWN FLIGHT") {
            PanelToggleRow(
                title: "You leave the ground",
                symbol: "airplane.departure",
                detail: "The moment the aircraft is actually flying, from the feed — so it arrives whether or not Inflight is the app in front of you.",
                isOn: binding(\.ownAirborne)
            )

            PanelDivider()

            PanelToggleRow(
                title: "Top of descent",
                symbol: "arrow.down.right",
                detail: "You reached a cruise and have started down — the seatbelt-sign moment. Arrives with a sound.",
                isOn: binding(\.ownDescent)
            )

            PanelDivider()

            PanelToggleRow(
                title: "\(approachMinutes) minutes from your destination",
                symbol: "timer",
                detail: approachDetail,
                isOn: binding(\.ownApproach)
            )
            .disabled(!(friends.capabilities?.knowsOwnFlightEvent("ownApproach") ?? true))

            PanelDivider()

            PanelToggleRow(
                title: "You are on the ground",
                symbol: "airplane.arrival",
                detail: "Down at your destination, with the landing ready to record from the sim.",
                isOn: binding(\.ownLanded)
            )

            PanelDivider()

            PanelToggleRow(
                title: "The sim link drops",
                symbol: "antenna.radiowaves.left.and.right.slash",
                detail: "Your flight stays on the map, but the fuel, lights and configuration stop updating when iOS suspends Inflight behind Infinite Flight.",
                isOn: binding(\.connectDropped)
            )

            // Drawn under the switches rather than instead of them. A pilot who
            // has not signed in should still be able to see and set what they
            // want to hear — the switches are not broken, the join to their
            // aeroplane is, and that is a different sentence.
            if let obstacle = ownFlightObstacle {
                PanelDivider()
                obstacleRow(obstacle)
            }
        }
    }

    private var approachDetail: String {
        guard friends.capabilities?.knowsOwnFlightEvent("ownApproach") ?? true else {
            return "This backend cannot work out an arrival time yet. The switch is here so it is on when it can."
        }
        return "How far out is worked out from the distance still to run and the speed you are actually making good, so it holds for a Cessna as well as a 777. Nothing is said on a flight that was already inside \(approachMinutes) minutes when we first saw it."
    }

    /// Something standing between a pilot and hearing about their own aeroplane.
    struct Obstacle {
        let title: String
        let detail: String
        let symbol: String
        let fix: () -> Void
    }

    /// The first of them, or nil when there is nothing in the way.
    ///
    /// In order, because they stack: a device with no account cannot be
    /// addressed at all, and an account with no way to recognise which
    /// aeroplane is yours has nothing to be told about. Showing both at once
    /// would be showing somebody two problems when they have one thing to do.
    private var ownFlightObstacle: Obstacle? {
        if !accounts.isSignedIn {
            return Obstacle(
                title: "Sign in to hear about your flight",
                detail: "This is the one notice addressed to a person rather than to a phone, so the server has to know which account this device belongs to.",
                symbol: "person.crop.circle.badge.exclamationmark",
                fix: { isShowingAccount = true }
            )
        }
        if !identity.isSet {
            return Obstacle(
                title: "Tell us which aeroplane is yours",
                detail: "Either your Infinite Flight display name on your profile, or thirty seconds of Connect while the sim is running — either one joins an aircraft on the map to your account.",
                symbol: "questionmark.circle",
                fix: { isShowingConnect = true }
            )
        }
        return nil
    }

    private func obstacleRow(_ obstacle: Obstacle) -> some View {
        Button(action: obstacle.fix) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: obstacle.title, symbol: obstacle.symbol)

                    Text(obstacle.detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Pilots you watch

    private var watchlistSection: some View {
        PanelSection(title: "PILOTS YOU WATCH") {
            PanelToggleRow(
                title: "They take off",
                symbol: "airplane.departure",
                detail: "The moment the aircraft actually leaves the ground, not when they spawn in.",
                isOn: binding(\.takeoff)
            )

            PanelDivider()

            PanelToggleRow(
                title: "They land",
                symbol: "airplane.arrival",
                isOn: binding(\.landing)
            )

            PanelDivider()

            PanelToggleRow(
                title: "They come online",
                symbol: "dot.radiowaves.left.and.right",
                detail: "Somebody you already watch appearing on a server. Adding a pilot who is already flying is not this — nothing has happened to them.",
                isOn: binding(\.online)
            )

            PanelDivider()

            PanelToggleRow(
                title: "They go offline",
                symbol: "moon.zzz",
                detail: "The noisiest of the four. On a busy server, people drop and come back all evening.",
                isOn: binding(\.offline)
            )

            PanelDivider()

            PanelToggleRow(
                title: "Live banner on takeoff",
                symbol: "livephoto",
                detail: liveActivity.isSupported
                    ? "A watched pilot leaving the ground raises a Live Activity on the lock screen, without the app being opened."
                    : "This device cannot run Live Activities.",
                isOn: binding(\.liveActivity)
            )
            .disabled(!liveActivity.isSupported)
            .opacity(liveActivity.isSupported ? 1 : 0.45)

            // The switches above are all perfectly correct and govern an empty
            // list, which is a state worth naming rather than leaving somebody
            // to work out from silence.
            if friends.friends.isEmpty {
                PanelDivider()

                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: "Nobody on the list yet", symbol: "person.2")

                    Text("Add a pilot from the friends panel, or from the window of any aircraft on the map. Until then these four have nobody to be about.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Does any of this actually work

    /// The chain, in the order it breaks.
    ///
    /// Every link here fails silently on its own, which is the whole reason
    /// notifications are hard to diagnose from a phone: nothing errors, nothing
    /// is logged where anybody can read it, and a switch that says "on" is
    /// telling the truth about a preference and nothing about delivery.
    private var deliverySection: some View {
        PanelSection(title: "DELIVERY") {
            deliveryRow(
                "iOS permission",
                ok: push.canNotify,
                value: push.canNotify ? "Allowed" : "Not allowed"
            )

            PanelDivider()

            deliveryRow(
                "This device's address",
                ok: push.deviceToken != nil,
                value: push.deviceToken == nil ? "Not registered" : "Registered"
            )

            PanelDivider()

            deliveryRow(
                "Server push",
                ok: friends.capabilities?.push ?? true,
                // Nil is the probe not having answered, which says nothing
                // about the server and should not be drawn as a fault.
                value: friends.capabilities.map { $0.push ? "Ready" : "Unavailable" } ?? "Checking…"
            )

            PanelDivider()

            deliveryRow(
                "Your account",
                ok: accounts.isSignedIn,
                value: accounts.account?.handle ?? "Signed out"
            )

            PanelDivider()

            testRow
        }
    }

    private func deliveryRow(_ title: String, ok: Bool, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(ok ? theme.accent : theme.textDim)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .motion(Motion.content, value: value)
    }

    /// One notification, from this device, with no server involved.
    ///
    /// It proves exactly one thing — that iOS will draw a banner for this app —
    /// and it is careful not to claim more than that. What it rules out is the
    /// commonest cause of "I get nothing": notifications switched off for the
    /// app, or delivered silently to a summary nobody reads.
    private var testRow: some View {
        Button {
            sendTest()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: "Send a test banner", symbol: "paperplane")

                    Text(testFeedback
                         ?? "From this device, so it proves iOS will show one — not that the server can reach you.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .motion(Motion.row, value: testFeedback)
    }

    private func sendTest() {
        guard push.canNotify else {
            withAnimation(Motion.row) {
                testFeedback = "Notifications are not allowed yet, so iOS has nowhere to draw this."
            }
            return
        }

        push.post(
            title: sampleTitle,
            body: sampleBody,
            identifier: "notification-settings-test"
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        withAnimation(Motion.row) {
            testFeedback = "Sent — it should appear over the top of this, because the app asks for banners while it is open as well as while it is not."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            withAnimation(Motion.row) { testFeedback = nil }
        }
    }

    // MARK: - Plumbing

    /// One switch, written back through the store so it is persisted and
    /// re-synced to the backend in one place.
    private func binding(
        _ key: WritableKeyPath<FriendsStore.NotificationPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { friends.preferences[keyPath: key] },
            set: { friends.preferences[keyPath: key] = $0 }
        )
    }

    private var summary: String {
        guard push.canNotify else { return "Not allowed yet" }
        let on = preferences.enabledCount
        if on == 0 { return "Nothing switched on" }
        return "\(on) of \(FriendsStore.NotificationPreferences.totalCount) on"
    }

    private func fetchPhoto() {
        guard let flight = subject else {
            photo = nil
            loader.load(nil)
            return
        }
        AircraftPhotoService.shared.photo(
            type: flight.aircraftName,
            livery: flight.liveryName
        ) { found in
            photo = found
            loader.load(found?.url)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
