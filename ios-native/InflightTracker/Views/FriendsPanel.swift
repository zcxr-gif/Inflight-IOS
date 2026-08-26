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

    /// The one screen all the switches live on now — see `notificationsSection`.
    @State private var isShowingNotifications = false

    private var theme: FlightInfoTheme { appearance.theme }

    /// Watched pilots the feed can currently see, keyed by lowercased name.
    /// Built once per render rather than searched per row — the packet is
    /// thousands of aircraft and the list is not.
    ///
    /// A list per pilot, not one flight. This used to be `found[username] =
    /// flight`, which silently kept whichever aircraft the packet happened to
    /// mention last: the feed covers several servers, a pilot can appear on
    /// more than one of them, and one of their aeroplanes would simply vanish
    /// from the list — including, sometimes, the one they were actually flying.
    ///
    /// Ordered highest first so the aeroplane in the air leads and one parked
    /// on a stand does not, with the flight id breaking ties so the order does
    /// not shuffle between packets.
    private var flying: [String: [Flight]] {
        let watched = Set(friends.friends)
        guard !watched.isEmpty else { return [:] }

        var found: [String: [Flight]] = [:]
        for flight in feed.flights {
            guard let username = flight.username?.lowercased(), watched.contains(username) else { continue }
            found[username, default: []].append(flight)
        }

        for (username, flights) in found where flights.count > 1 {
            found[username] = flights.sorted {
                if $0.altitudeFeet != $1.altitudeFeet { return $0.altitudeFeet > $1.altitudeFeet }
                return $0.id < $1.id
            }
        }
        return found
    }

    var body: some View {
        let aloft = flying

        MapPanel(title: "Friends", subtitle: summary(aloft: aloft.count, flights: aloft.values.reduce(0) { $0 + $1.count })) {
            // Each section is dealt in a beat after the one above it, so the
            // panel arrives rather than being there. See Motion.
            if !push.canNotify { permissionSection.panelEntrance(0) }

            addSection.panelEntrance(1)

            if friends.friends.isEmpty {
                PanelSection(title: "WATCHING") {
                    PanelEmptyState(
                        symbol: "person.2",
                        title: "Nobody on the list",
                        detail: "Add an Infinite Flight display name above, or open an aircraft and add the pilot from its window."
                    )
                }
                .panelEntrance(2)
            } else {
                PanelSection(title: "WATCHING") {
                    ForEach(Array(friends.friends.enumerated()), id: \.element) { index, username in
                        if index > 0 { PanelDivider() }
                        FriendRow(
                            username: username,
                            flight: aloft[username]?.first,
                            theme: theme,
                            isTracking: aloft[username]?.first.map { liveActivity.isTracking(flightId: $0.id) } ?? false,
                            onOpen: { flight in onSelect(flight) },
                            onTrack: { flight in toggleTracking(flight) },
                            onProfile: { opened = .pilot(username) },
                            onRemove: { friends.remove(username) }
                        )

                        // Everything else this pilot has in the air. Rare, and
                        // silently dropped until now — which is worse than rare,
                        // because the one that got dropped was as likely as not
                        // the one being flown.
                        ForEach(aloft[username]?.dropFirst().map { $0 } ?? []) { extra in
                            AlsoFlyingRow(
                                flight: extra,
                                theme: theme,
                                isTracking: liveActivity.isTracking(flightId: extra.id),
                                onOpen: { onSelect(extra) },
                                onTrack: { toggleTracking(extra) }
                            )
                        }
                    }
                }
                .panelEntrance(2)
            }

            flyingNowSection.panelEntrance(3)

            directorySection.panelEntrance(4)

            notificationsSection.panelEntrance(5)

            if !friends.friends.isEmpty { widgetSection.panelEntrance(6) }

            HintStrip(placement: .friends)
                .panelEntrance(7)
        }
        .task { await refreshFlyingNow() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .watchlist) }
        .sheet(isPresented: $isShowingLandingBoard) { LandingBoardView() }
        .sheet(isPresented: $isShowingNotifications) {
            NotificationsPanel().environmentObject(feed)
        }
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

    /// `aloft` is how many watched pilots the feed can see; `flights` is how
    /// many aeroplanes they are between them. The two differ when somebody
    /// appears on more than one server, and reporting the second as the first
    /// would say there are more people watching than there are.
    private func summary(aloft: Int, flights: Int) -> String {
        guard !friends.friends.isEmpty else { return "Nobody watched yet" }
        let people = friends.count == 1 ? "1 pilot" : "\(friends.count) pilots"
        guard aloft > 0 else { return "\(people) · none flying" }
        guard flights > aloft else { return "\(people) · \(aloft) flying now" }
        return "\(people) · \(aloft) flying now, \(flights) aircraft"
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

    /// A door rather than the switches themselves.
    ///
    /// These used to be five toggles right here, and that was right while the
    /// only thing the app could tell you about was somebody else. It is not any
    /// more — there are notices about your own aeroplane now, and they have no
    /// business under a heading called "friends". Two screens carrying five
    /// switches each, one of them a copy, is also how the two quietly come to
    /// disagree; there is one screen, and this is the way to it.
    private var notificationsSection: some View {
        PanelSection(title: "TELL ME WHEN") {
            PanelActionRow(
                title: "Notifications",
                symbol: "bell.badge",
                detail: notificationsDetail
            ) {
                isShowingNotifications = true
            }
        }
    }

    private var notificationsDetail: String {
        guard push.canNotify else {
            return "Not allowed yet, so nothing about these pilots can reach you."
        }
        if friends.preferences.isSilent {
            return "Nothing about a watched pilot is switched on."
        }
        return watchedSummary
    }

    /// Which of the four are on, in the order the panel lists them.
    private var watchedSummary: String {
        let preferences = friends.preferences
        let on = [
            preferences.takeoff ? "take off" : nil,
            preferences.landing ? "land" : nil,
            preferences.online ? "come online" : nil,
            preferences.offline ? "go offline" : nil
        ].compactMap { $0 }

        switch on.count {
        case 1: return "When they \(on[0])."
        case 2: return "When they \(on[0]) and \(on[1])."
        default: return "When they \(on.dropLast().joined(separator: ", ")) and \(on[on.count - 1])."
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

/// A second aeroplane the same pilot has in the air.
///
/// Indented under their row rather than given one of its own, because it is the
/// same person: a list that shows one name twice reads as two friends. It
/// carries the callsign, which is the only thing that tells two of somebody's
/// flights apart at a glance, and the same two actions as the row above.
private struct AlsoFlyingRow: View {

    let flight: Flight
    let theme: FlightInfoTheme
    let isTracking: Bool

    let onOpen: () -> Void
    let onTrack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("also \(flight.callsign ?? "flying")")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
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

            Button(action: onTrack) {
                Image(systemName: isTracking ? "livephoto.badge.automatic" : "livephoto")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isTracking ? theme.onAccent : theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background {
                        Circle().fill(isTracking ? theme.accent : theme.surfaceFill)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTracking ? "Stop the live banner" : "Show a live banner for this flight")
        }
        .padding(.leading, 28)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
    }

    private var detail: String {
        let route = "\(flight.departureIcao ?? "————") → \(flight.arrivalIcao ?? "————")"
        switch FlightPhase.from(flight) {
        case .ground: return "\(route) · on the ground"
        default:      return "\(route) · \(Format.number(flight.altitudeFeet)) ft"
        }
    }
}
