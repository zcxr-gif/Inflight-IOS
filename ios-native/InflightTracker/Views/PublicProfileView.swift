import SwiftUI

/// A pilot, as the world sees them.
///
/// Reached from a name on the map, from the friends list, from a search, and
/// from somebody else's friends strip — which is the point: the social graph is
/// something you can walk, and every profile is a door into three more.
///
/// Nothing on this screen decides what may be shown. `pilot_profile_card()`
/// returns a row or it returns nothing, the friends list obeys the profile's
/// own visibility setting, the logbook obeys its own, and the banner and colour
/// are already blanked for an account whose Pro has lapsed. This view draws
/// what it is given and asks no questions, because the alternative is a second
/// copy of the visibility rules living in a client that people can modify.
struct PublicProfileView: View {

    /// Either the profile's own handle, or the Infinite Flight name written on
    /// an aeroplane. The second is the interesting one and is why this takes a
    /// link rather than a string: a name off the map may well belong to
    /// somebody who has never claimed a profile, and that is a different
    /// sentence from "no such handle".
    let link: ProfileLink

    init(link: ProfileLink, onShowFlight: ((Flight) -> Void)? = nil) {
        self.link = link
        self.onShowFlight = onShowFlight
    }

    init(handle: String, onShowFlight: ((Flight) -> Void)? = nil) {
        self.init(link: .handle(handle), onShowFlight: onShowFlight)
    }

    /// Focuses the map on this pilot's aircraft, where the presenting screen
    /// can do that. Nil from a sheet with no map behind it.
    var onShowFlight: ((Flight) -> Void)?

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var friends = FriendsStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var profile: PilotProfile?
    @State private var friendList: [PilotSummary] = []
    @State private var badges: [PilotBadge] = []
    @State private var logbook: [LogbookEntry] = []
    @State private var summary: LogbookSummary?

    /// What this pilot's own simulator is reporting, if they are flying, are
    /// broadcasting, and have let this viewer see it. All three are their
    /// decision; an absent status never says which one is false.
    @State private var live: PilotLiveStatus?

    @State private var isLoading = true
    @State private var isWorking = false
    @State private var problem: String?

    /// Another profile, opened from this one. Presented from here rather than
    /// pushed, because these are sheets all the way down and a sheet is the
    /// only thing a sheet can present.
    @State private var opened: ProfileLink?

    @State private var listing: Listing?
    @State private var isReporting = false
    @State private var isConfirmingBlock = false

    private var theme: FlightInfoTheme { appearance.theme }

    /// The profile's real handle once it is known.
    ///
    /// For a handle link that is the link itself; for a name off the map it is
    /// only known after the lookup, which is why everything that acts on a
    /// profile — following, blocking, reporting — reads this rather than the
    /// link and does nothing while it is nil.
    private var handle: String { profile?.handle ?? link.value }

    /// Which of the two long lists is being shown in full.
    private enum Listing: String, Identifiable {
        case followers
        case following

        var id: String { rawValue }

        var title: String { rawValue.capitalized }
    }

    /// This pilot's aircraft, if the server can see it right now.
    ///
    /// Matched on the Infinite Flight handle they claim, which is unverified —
    /// so the row that shows it says "claims to be" and this is drawn as
    /// "someone flying under that name" rather than as a fact about them.
    private var flying: Flight? {
        guard let name = profile?.ifUsername?.lowercased(), !name.isEmpty else { return nil }
        return feed.flights.first { $0.username?.lowercased() == name }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let profile = profile {
                    header(profile)
                    if let problem = problem { problemLine(problem) }
                    actions(profile)
                    if let bio = profile.bio, !bio.isEmpty { bioCard(bio) }
                    liveCard
                    simCard
                    favouriteCard(profile)
                    statsCard(profile)
                    friendsCard(profile)
                    badgesCard
                    logbookCard
                    footer(profile)
                } else if isLoading {
                    loading
                } else {
                    missing
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize)
        .flightInfoLegible(theme)
        .background { theme.windowFill.ignoresSafeArea() }
        .environment(\.colorScheme, theme.colorScheme)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: link) { await load() }
        // AnyView, and not for laziness.
        //
        // A profile presents another profile — that is the whole point of a
        // social graph you can walk — and a followers list presents a profile
        // which presents a followers list. Written plainly, `body`'s opaque
        // return type would be defined in terms of itself and the compiler
        // refuses it. Erasing the type at the recursion point is the standard
        // way out, and the cost is one allocation on a sheet that a person has
        // just tapped to open.
        .sheet(item: $opened) { next in
            AnyView(
                PublicProfileView(link: next, onShowFlight: onShowFlight)
                    .environmentObject(feed)
            )
        }
        .sheet(item: $listing) { which in
            AnyView(
                PilotListPanel(
                    title: which.title,
                    handle: handle,
                    direction: which == .followers ? .followers : .following
                )
                .environmentObject(feed)
            )
        }
        .sheet(isPresented: $isReporting) {
            ReportProfileSheet(handle: handle) { reason, detail in
                await submitReport(reason: reason, detail: detail)
            }
        }
        .confirmationDialog(
            "Block @\(handle)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await setBlocked(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to see your profile or follow you, and you'll each stop appearing on the other's lists. They aren't told.")
        }
    }

    // MARK: - Header

    private func header(_ profile: PilotProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                PilotBanner(
                    url: profile.bannerURL,
                    preset: BannerPreset.resolved(profile.bannerPreset),
                    height: 148
                )

                HStack(spacing: 8) {
                    if let url = AppConfig.publicProfileURL(handle: profile.handle) {
                        ShareLink(item: url) {
                            headerButton("square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share this profile")
                    }

                    if !profile.isSelf { overflowMenu(profile) }

                    Button { dismiss() } label: { headerButton("xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                }
                .padding(.top, 12)
                .padding(.trailing, 14)
            }

            HStack(alignment: .bottom, spacing: 12) {
                PilotAvatar(
                    url: profile.avatarURL,
                    initials: profile.initials,
                    side: 88,
                    isPro: profile.isPro
                )
                // Lifted onto the banner, which is what makes the header read
                // as one thing rather than as a picture with a card under it.
                .offset(y: -30)
                .padding(.bottom, -30)
                .background {
                    Circle()
                        .fill(theme.windowFill)
                        .frame(width: 96, height: 96)
                        .offset(y: -30)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.75)

                        if profile.isPro { ProBadge() }
                    }

                    Text("@\(profile.handle)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func headerButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background { Circle().fill(.black.opacity(0.38)) }
    }

    private func overflowMenu(_ profile: PilotProfile) -> some View {
        Menu {
            Button {
                isReporting = true
            } label: {
                Label("Report this profile", systemImage: "flag")
            }

            if profile.viewerBlocked {
                Button { Task { await setBlocked(false) } } label: {
                    Label("Unblock @\(profile.handle)", systemImage: "hand.raised.slash")
                }
            } else {
                Button(role: .destructive) {
                    isConfirmingBlock = true
                } label: {
                    Label("Block @\(profile.handle)", systemImage: "hand.raised")
                }
            }
        } label: {
            headerButton("ellipsis")
        }
        .accessibilityLabel("More")
    }

    // MARK: - Follow

    private func actions(_ profile: PilotProfile) -> some View {
        HStack(spacing: 8) {
            if profile.isSelf {
                Text("This is you.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    Task { await setFollowing(!profile.viewerFollows) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: followSymbol(profile))
                            .font(.system(size: 12, weight: .bold))
                        Text(followLabel(profile))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(profile.viewerFollows ? theme.textPrimary : theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                            .fill(profile.viewerFollows ? theme.surfaceFill : theme.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .opacity(isWorking ? 0.6 : 1)

                // Watching is the tracker's own idea of a friend and is
                // deliberately separate from following: one is "tell me when
                // they take off", the other is "I know this person". Somebody
                // may well want either without the other.
                if let name = profile.ifUsername, !name.isEmpty {
                    Button { watchToggle(name) } label: {
                        Image(systemName: friends.contains(name)
                              ? "bell.fill" : "bell")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(friends.contains(name)
                                             ? theme.onAccent : theme.textSecondary)
                            .frame(width: 42, height: 42)
                            .background {
                                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                                    .fill(friends.contains(name) ? theme.accent : theme.surfaceFill)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        friends.contains(name)
                            ? "Stop being told when \(name) flies"
                            : "Tell me when \(name) flies"
                    )
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func followLabel(_ profile: PilotProfile) -> String {
        switch profile.relationship {
        case .friends: return "Friends"
        case .following: return "Following"
        case .followsYou: return "Follow back"
        case .none: return "Follow"
        case .you: return "You"
        }
    }

    private func followSymbol(_ profile: PilotProfile) -> String {
        switch profile.relationship {
        case .friends: return "person.2.fill"
        case .following: return "checkmark"
        default: return "plus"
        }
    }

    // MARK: - Cards

    private func bioCard(_ bio: String) -> some View {
        card {
            Text(bio)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    /// Where they are right now, if they are anywhere.
    ///
    /// The thing a profile on a *tracker* can do that a profile anywhere else
    /// cannot, so it sits above everything except the bio.
    @ViewBuilder
    private var liveCard: some View {
        if let flight = flying {
            PanelSection(title: "FLYING NOW") {
                Button {
                    if let onShowFlight = onShowFlight {
                        dismiss()
                        onShowFlight(flight)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "airplane")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: 32, height: 32)
                            .background { Circle().fill(theme.accent) }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(flight.departureIcao ?? "————") → \(flight.arrivalIcao ?? "————")")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.textPrimary)

                            Text(liveDetail(flight))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .flightInfoLine(minimumScale: 0.8)
                        }

                        Spacer(minLength: 6)

                        if onShowFlight != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onShowFlight == nil)
            }
            .padding(.horizontal, 16)
        }
    }

    private func liveDetail(_ flight: Flight) -> String {
        let phase = FlightPhase.from(flight)
        let aircraft = flight.aircraftName.isEmpty ? "Aircraft" : flight.aircraftName
        if phase == .ground {
            return "\(aircraft) · on the ground · \(feed.server)"
        }
        return "\(aircraft) · \(Format.number(flight.altitudeFeet)) ft · \(feed.server)"
    }

    /// The aeroplane they would fly if they could only fly one, drawn on a
    /// photograph of it.
    ///
    /// The photo is the community one the rest of the app already uses, looked
    /// up by type and livery — so a profile that names a 777 in BA colours
    /// shows that aircraft in those colours rather than a stock silhouette.
    @ViewBuilder
    private func favouriteCard(_ profile: PilotProfile) -> some View {
        if let aircraft = profile.favouriteAircraft, !aircraft.isEmpty {
            PanelSection(title: "FAVOURITE AIRCRAFT") {
                FavouriteAircraftCard(
                    aircraft: aircraft,
                    livery: profile.favouriteLivery,
                    homeAirport: profile.homeAirport
                )
            }
            .padding(.horizontal, 16)
        } else if let home = profile.homeAirport, !home.isEmpty {
            PanelSection(title: "HOME") {
                HStack(spacing: 10) {
                    PanelRowLabel(title: home, symbol: "mappin.and.ellipse")
                    Spacer(minLength: 6)
                    if let name = AirportStore.shared.airport(home)?.name {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .flightInfoLine(minimumScale: 0.7)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
        }
    }

    private func statsCard(_ profile: PilotProfile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PilotStat(value: "\(profile.friendCount)", label: "FRIENDS")
                PilotStat(value: "\(profile.followerCount)", label: "FOLLOWERS") {
                    listing = .followers
                }
                PilotStat(value: "\(profile.followingCount)", label: "FOLLOWING") {
                    listing = .following
                }
            }

            if let summary = summary, !summary.isEmpty {
                PanelDivider()
                HStack(spacing: 0) {
                    PilotStat(value: "\(summary.flights)", label: "FLIGHTS")
                    PilotStat(value: "\(summary.hours)", label: "HOURS")
                    PilotStat(value: "\(summary.airports)", label: "FIELDS")
                }

                // Only for a pilot who has actually flown with the simulator
                // attached. An empty landing row on everybody else's profile
                // would be advertising at people on a page that is not the
                // place for it.
                if summary.hasMeasuredLandings {
                    PanelDivider()
                    HStack(spacing: 0) {
                        if let best = summary.bestLandingFPM {
                            PilotStat(value: "\(best)", label: "BEST FPM")
                        }
                        if let average = summary.averageLandingFPM {
                            PilotStat(value: "\(average)", label: "AVG FPM")
                        }
                        PilotStat(value: "\(summary.greasers)", label: "GREASERS")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
        .padding(.horizontal, 16)
    }

    /// What the pilot's own simulator says, which is a different and better
    /// thing than what the map says.
    ///
    /// The map can report a position and a groundspeed. This can report that the
    /// gear is down, the landing lights are on and there is a twenty knot
    /// crosswind — because it is coming from inside the aeroplane rather than
    /// from an observer outside it.
    @ViewBuilder
    private var simCard: some View {
        if let live = live, live.isFresh {
            VStack(alignment: .leading, spacing: 11) {

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)

                    Text(live.phaseLabel ?? "Flying now")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)

                    Spacer(minLength: 8)

                    if let elapsed = live.elapsedLabel {
                        Text(elapsed)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                    }
                }

                if let route = live.routeLabel {
                    Text(route)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                }

                HStack(spacing: 0) {
                    if let altitude = live.altitudeMSL {
                        PilotStat(value: "\(altitude.formatted())", label: "FEET")
                    }
                    if let speed = live.groundSpeedKnots {
                        PilotStat(value: "\(speed)", label: "KNOTS")
                    }
                    if let rate = live.verticalSpeedFPM, abs(rate) > 50 {
                        PilotStat(value: "\(rate)", label: "FPM")
                    }
                }

                if let configuration = live.configurationLabel {
                    detailLine("Configured", configuration, symbol: "slider.horizontal.3")
                }
                if let wind = live.windLabel {
                    detailLine("Wind", wind, symbol: "wind")
                }
                if let waypoint = live.nextWaypoint {
                    detailLine("Next", waypoint, symbol: "point.topleft.down.to.point.bottomright.curvepath")
                }
                if let aircraft = live.aircraft {
                    detailLine("Aircraft", aircraft, symbol: "airplane")
                }

                Text("Reported by their simulator, not worked out from the map.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            .padding(.horizontal, 16)
        }
    }

    private func detailLine(_ name: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(theme.textDim)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func friendsCard(_ profile: PilotProfile) -> some View {
        if !friendList.isEmpty {
            PanelSection(title: "FLIES WITH") {
                PilotStrip(pilots: friendList) { opened = .handle($0) }
            }
            .padding(.horizontal, 16)
        } else if profile.friendsVisibility != "public" && !profile.isSelf {
            PanelSection(title: "FLIES WITH") {
                PanelEmptyState(
                    symbol: "lock",
                    title: "Kept private",
                    detail: profile.friendsVisibility == "followers"
                        ? "\(profile.displayName) shows their friends to the people who follow them."
                        : "\(profile.displayName) keeps their friends list to themselves."
                )
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var badgesCard: some View {
        let earned = badges.filter(\.earned)
        let next = badges.filter { !$0.earned }.sorted { $0.fraction > $1.fraction }.prefix(3)
        let shown = earned + next

        if !shown.isEmpty {
            PanelSection(title: earned.isEmpty ? "WORKING TOWARDS" : "EARNED") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(shown) { badge in BadgeChip(badge: badge) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var logbookCard: some View {
        if !logbook.isEmpty {
            PanelSection(title: "LOGBOOK") {
                ForEach(Array(logbook.prefix(12).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { PanelDivider() }
                    LogbookRow(entry: entry)
                }

                // The free limit, said out loud rather than left as a list that
                // appears to have lost half of itself. Only ever about the
                // profile's OWNER — reading somebody's logbook is free.
                if logbook.first?.truncated == true {
                    PanelDivider()
                    Text(profile?.isSelf == true
                         ? "A free account keeps its last \(ProFeature.freeLogbookEntries) flights on show. Inflight Pro shows the lot."
                         : "\(profile?.displayName ?? "This pilot") is on a free account, so the last \(ProFeature.freeLogbookEntries) flights are shown.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func footer(_ profile: PilotProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = profile.ifUsername, !name.isEmpty {
                // Said plainly, because it is not verified and pretending
                // otherwise is how somebody gets impersonated.
                Text(profile.ifUsernameVerified
                     ? "Flies as \(name) on Infinite Flight."
                     : "Says they fly as \(name) on Infinite Flight. We haven't checked.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let joined = profile.joinedAt {
                Text("On Inflight since \(joined.formatted(.dateTime.month(.wide).year())).")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - States

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().tint(theme.textSecondary)
            Text("Looking up @\(handle)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    /// One answer for "no such pilot" and for "not one you may see".
    ///
    /// Deliberate, and it comes from the server: telling the two apart would
    /// turn a profile lookup into a way of finding out who has blocked you and
    /// which handles are held by private accounts.
    private var missing: some View {
        VStack(spacing: 14) {
            PanelEmptyState(
                symbol: "person.crop.circle.badge.questionmark",
                title: "No profile here",
                detail: link.kind == .ifUsername
                    ? "\(link.value) hasn't set up an Inflight profile — most pilots on the server haven't yet."
                    : "@\(link.value) hasn't set up a profile, or theirs isn't public."
            )

            Button { dismiss() } label: {
                Text("Close")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                            .fill(theme.accent)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private func problemLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            .padding(.horizontal, 16)
    }

    // MARK: - Work

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let card: PilotProfile?
        switch link.kind {
        case .handle:
            card = await PilotDirectory.shared.card(handle: link.value)
        case .ifUsername:
            card = await PilotDirectory.shared.card(ifUsername: link.value)
        }
        profile = card
        guard let found = card else { return }
        let handle = found.handle

        // In parallel: four independent reads, none of which the others need.
        // Serially this is four round trips before the badges appear.
        async let friendsTask = PilotDirectory.shared.friends(of: handle)
        async let badgesTask = PilotDirectory.shared.badges(of: handle)
        async let logbookTask = PilotDirectory.shared.logbook(of: handle, limit: 12)
        async let summaryTask = PilotDirectory.shared.logbookSummary(of: handle)
        async let liveTask = PilotDirectory.shared.liveStatus(of: handle)

        friendList = await friendsTask
        badges = await badgesTask
        logbook = await logbookTask
        summary = await summaryTask
        live = await liveTask
    }

    @MainActor
    private func setFollowing(_ following: Bool) async {
        guard accounts.isSignedIn else {
            problem = "Sign in to follow pilots."
            return
        }

        isWorking = true
        problem = nil
        defer { isWorking = false }

        do {
            profile = try await PilotDirectory.shared.setFollowing(following, handle: handle)
            // A new friendship changes the strip, and only the server knows
            // whether this follow made one.
            friendList = await PilotDirectory.shared.friends(of: handle)
        } catch {
            problem = (error as? SupabaseData.Failure)?.message ?? error.localizedDescription
        }
    }

    @MainActor
    private func setBlocked(_ blocked: Bool) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await PilotDirectory.shared.setBlocked(blocked, handle: handle)
            if blocked {
                dismiss()
            } else {
                await load()
            }
        } catch {
            problem = (error as? SupabaseData.Failure)?.message ?? error.localizedDescription
        }
    }

    @MainActor
    private func submitReport(
        reason: PilotDirectory.ReportReason,
        detail: String
    ) async -> String? {
        do {
            try await PilotDirectory.shared.report(
                handle: handle,
                reason: reason,
                detail: detail
            )
            return nil
        } catch {
            return (error as? SupabaseData.Failure)?.message ?? error.localizedDescription
        }
    }

    private func watchToggle(_ name: String) {
        switch friends.toggle(name) {
        case .needsPro(let limit):
            problem = "Free keeps \(limit) pilots on the watchlist. Inflight Pro lifts the limit."
        case .unusableName:
            problem = "That pilot's Infinite Flight name can't be watched."
        default:
            problem = nil
        }
    }
}

/// The favourite aeroplane, drawn on a photograph of itself.
private struct FavouriteAircraftCard: View {

    let aircraft: String
    let livery: String?
    let homeAirport: String?

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @StateObject private var loader = RemoteImageLoader()
    @State private var photo: AircraftPhoto?

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .clipped()
                        // The text sits on the photograph, so the photograph
                        // has to stop competing with it at the bottom.
                        .overlay {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.68)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                        }
                } else {
                    // No photo for this type and livery. A silhouette rather
                    // than a gap, so the card still reads as an aeroplane.
                    ZStack {
                        theme.elevatedFill
                        Image(systemName: "airplane")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(theme.textDim)
                    }
                    .frame(height: 110)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(aircraft)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(loader.image == nil ? theme.textPrimary : .white)
                        .flightInfoLine(minimumScale: 0.75)

                    if let livery = livery, !livery.isEmpty {
                        Text(livery)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(loader.image == nil
                                             ? theme.textDim : .white.opacity(0.85))
                            .flightInfoLine(minimumScale: 0.8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }

            if let contributor = photo?.contributor, !contributor.isEmpty {
                // The community photographers are credited wherever their work
                // is used, the same as in the flight window.
                Text("Photo by \(contributor)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }

            if let home = homeAirport, !home.isEmpty {
                PanelDivider()
                HStack(spacing: 8) {
                    PanelRowLabel(title: "Flies out of \(home)", symbol: "mappin.and.ellipse")
                    Spacer(minLength: 6)
                    if let name = AirportStore.shared.airport(home)?.name {
                        Text(name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .flightInfoLine(minimumScale: 0.7)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        .onAppear(perform: fetch)
        .onChange(of: aircraft) { _, _ in fetch() }
    }

    private func fetch() {
        AircraftPhotoService.shared.photo(
            type: aircraft,
            livery: livery ?? ""
        ) { found in
            photo = found
            loader.load(found?.url)
        }
    }
}
