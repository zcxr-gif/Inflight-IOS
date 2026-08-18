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
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var liveActivity = LiveActivityController.shared

    /// Raised when the free list is full. The limit is a Pro thing, so the
    /// place it is explained is the place Pro is explained.
    @State private var isShowingPaywall = false

    /// Focuses the map on a friend's aircraft and closes the panel.
    let onSelect: (Flight) -> Void

    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var isTyping: Bool

    /// A profile opened from a row, and the directory.
    @State private var opened: ProfileLink?
    @State private var isSearchingPilots = false

    /// Pilots this account follows who are in the air right now, straight from
    /// their own simulators. Empty for everybody who is not flying, is not
    /// sharing, or has not let this account see it.
    @State private var flyingNow: [PilotLiveSummary] = []
    @State private var isShowingLandingBoard = false

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
                            onProfile: { opened = .pilot(username) },
                            onRemove: { friends.remove(username) }
                        )
                    }
                }
            }

            flyingNowSection

            directorySection

            notificationsSection

            if !friends.friends.isEmpty { widgetSection }

            HintStrip(placement: .friends)
        }
        .task { await refreshFlyingNow() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .watchlist) }
        .sheet(isPresented: $isShowingLandingBoard) { LandingBoardView() }
        .sheet(item: $opened) { link in
            PublicProfileView(link: link, onShowFlight: onSelect)
                .environmentObject(feed)
        }
        .sheet(isPresented: $isSearchingPilots) {
            PilotSearchPanel().environmentObject(feed)
        }
    }

    /// The other kind of friend.
    ///
    /// The watchlist above is about aeroplanes: names the tracker recognises on
    /// the map, so it can tell you when they take off. This is about people —
    /// profiles, followers, the pilots somebody flies with. The two live in one
    /// panel because "friends" is one word to the person reading it, and the
    /// difference between them is a sentence, not a screen.
    private var directorySection: some View {
        PanelSection(title: "PILOTS ON INFLIGHT") {
            PanelActionRow(
                title: "Find a pilot",
                symbol: "magnifyingglass",
                detail: "Search by handle, by name, or by the Infinite Flight name on somebody's aeroplane."
            ) {
                isSearchingPilots = true
            }

            PanelDivider()

            PanelActionRow(
                title: "Landing board",
                symbol: "chart.bar.fill",
                detail: "Who you follow has put one down best, as the simulator measured it."
            ) {
                isShowingLandingBoard = true
            }
        }
    }

    /// Everybody you follow who is flying, as their own simulator reports them.
    ///
    /// Nothing here can be derived from the map. The map knows an aeroplane is
    /// at 34,000 feet; this knows the pilot is descending with the gear down,
    /// because it came from inside the aircraft. Drawn only when somebody is
    /// actually flying — an empty "nobody is flying" card every time you open
    /// the panel is a worse thing than no card.
    @ViewBuilder
    private var flyingNowSection: some View {
        if !flyingNow.isEmpty {
            PanelSection(title: "FOLLOWING · IN THE AIR") {
                ForEach(Array(flyingNow.enumerated()), id: \.element.id) { index, pilot in
                    if index > 0 { PanelDivider() }

                    Button {
                        opened = .handle(pilot.handle)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(pilot.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                    if pilot.isPro {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(theme.accent)
                                    }
                                }

                                Text(pilot.detail)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func refreshFlyingNow() async {
        guard AccountStore.shared.isSignedIn else {
            flyingNow = []
            return
        }
        flyingNow = await PilotDirectory.shared.liveFollowing()
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
                    Text(hint)
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

    /// What the field says when nothing has gone wrong.
    ///
    /// A free account is told how much room is left BEFORE it runs out, rather
    /// than finding out by being refused. The limit is not a secret and being
    /// coy about it only makes the refusal feel arbitrary when it arrives.
    private var hint: String {
        let spelling = "Their Infinite Flight display name, spelled the way it appears on the map."
        guard !entitlements.isPro else { return spelling }

        let left = max(ProFeature.freeWatchlistLimit - friends.count, 0)
        switch left {
        case 0:
            return "\(spelling) Your free list is full — Inflight Pro lifts the limit."
        case 1:
            return "\(spelling) Room for one more on a free account."
        default:
            return "\(spelling) Room for \(left) more on a free account."
        }
    }

    /// The store decides; this says what it decided.
    ///
    /// Every refusal used to be re-derived here — the free limit checked before
    /// the add, then the two remaining failures told apart afterwards by asking
    /// `contains` again. The limit now lives on the mutation itself, so this
    /// has one job: turn an outcome into a sentence.
    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        switch friends.add(name) {
        case .added:
            draft = ""
            problem = nil
            isTyping = false
            // Asking at the moment the list stops being empty, rather than on
            // first launch: by now the permission prompt has something to be
            // about.
            if friends.count == 1, push.authorization == .notDetermined {
                push.requestAuthorization()
            }

        case .alreadyWatching:
            problem = "\(name) is already on your list."

        case .unusableName:
            problem = "That doesn't look like a display name."

        case .needsPro(let limit):
            problem = "Free keeps \(limit) pilots. Inflight Pro lifts the limit."
            isShowingPaywall = true
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

    /// Opens whoever is flying under this name on Inflight, if anybody is. The
    /// lookup is unverified and may find nothing — the profile view says which.
    let onProfile: () -> Void

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

            Button(action: onProfile) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(username)'s Inflight profile")

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
