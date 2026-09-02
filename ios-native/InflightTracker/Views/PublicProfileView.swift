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

    /// A VA opened from the badge strip.
    @State private var openedVa: VaAd?

    @State private var listing: Listing?
    @State private var isReporting = false
    @State private var isConfirmingBlock = false

    /// Editing your own profile without leaving it — see `actions`.
    @State private var isEditing = false

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
        // Same handle as every other window: pull it down and the profile
        // goes. Floating rather than stacked, because a profile opens on a
        // full-width banner and a band of plain ground above it would read as
        // the banner having been pushed down the window.
        SheetWindow(theme: theme, handleFloats: true) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if let profile = profile {
                        header(profile)
                        if let problem = problem { problemLine(problem) }
                        relationship(profile)
                        counts(profile)
                        actions(profile)
                        if let bio = profile.bio, !bio.isEmpty { bioCard(bio) }
                        liveCard
                        simCard
                        favouriteCard(profile)
                        vaCard(profile)
                        statsCard
                        recordsCard
                        landingsCard
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
            // On the content, not on the window: this is a halo behind text,
            // and hung on an opaque card it would be a drop shadow around it.
            .flightInfoLegible(theme)
        }
        .environment(\.colorScheme, theme.colorScheme)
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
        .sheet(isPresented: $isEditing) {
            // Re-read on the way out: the editor writes through ProfileStore,
            // and this screen holds a card it fetched rather than that store's
            // row, so without this a pilot saves a change and watches their own
            // profile go on showing the old one.
            AnyView(ProfileEditorView().onDisappear { Task { await load() } })
        }
        .sheet(item: $openedVa) { ad in
            AnyView(VaDetailSheet(ad: ad).environmentObject(feed))
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

                    // No cross here either: the window is closed by pulling
                    // its handle down, which is a gesture rather than a
                    // quarter-inch target in the corner of a photograph.
                    if !profile.isSelf { overflowMenu(profile) }
                }
                .padding(.top, 12)
                .padding(.trailing, 14)
            }

            HStack(alignment: .bottom, spacing: 12) {
                PilotAvatar(
                    url: profile.avatarURL,
                    initials: profile.initials,
                    side: 88,
                    isPro: profile.isPro,
                    tint: profile.accentColor
                )
                // The backdrop goes on BEFORE the avatar is moved, so it is
                // centred on the picture and travels with it.
                //
                // It used to be applied after both the offset and a negative
                // bottom padding, which put it about 45pt too high: `.background`
                // centres itself on the layout rect it is attached to, the
                // negative padding had already shortened that rect by 30, and
                // the circle then carried an offset of its own on top. The
                // result was a dark disc floating above the avatar's head.
                .background {
                    Circle()
                        .fill(theme.windowFill)
                        .frame(width: 96, height: 96)
                }
                // Lifted onto the banner, which is what makes the header read
                // as one thing rather than as a picture with a card under it.
                // The padding cancels the space the lift would otherwise leave
                // below, so the name sits where it looks like it should.
                .offset(y: -30)
                .padding(.bottom, -30)

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

    /// Whether this pilot follows *you*, which the card has always known and the
    /// profile has never said.
    ///
    /// It is the difference between a stranger and somebody who chose you back,
    /// and it changes what the follow button means — so it sits next to it
    /// rather than being buried in a count.
    @ViewBuilder
    private func relationship(_ profile: PilotProfile) -> some View {
        if !profile.isSelf, profile.isFriend || profile.followsViewer {
            HStack(spacing: 5) {
                Image(systemName: profile.isFriend ? "person.2.fill" : "arrow.turn.down.left")
                    .font(.system(size: 9, weight: .bold))
                Text(profile.isFriend ? "Friends" : "Follows you")
                    .font(.system(size: 10.5, weight: .bold))
            }
            .foregroundStyle(profile.accentColor ?? theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill((profile.accentColor ?? theme.accent).opacity(0.15))
            )
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Friends, followers, following — directly above the follow button.
    ///
    /// These were at the bottom of the stats card, four cards down, which is
    /// the wrong place for them twice over: they are the numbers somebody
    /// checks before deciding whether to follow, and they are the only stats on
    /// the profile that are about *people* rather than about flying. Sitting
    /// them on top of the button puts the decision and its evidence together,
    /// and leaves the stats card to be what it says it is.
    private func counts(_ profile: PilotProfile) -> some View {
        HStack(spacing: 0) {
            PilotStat(value: "\(profile.friendCount)", label: "FRIENDS")
            PilotStat(value: "\(profile.followerCount)", label: "FOLLOWERS") {
                listing = .followers
            }
            PilotStat(value: "\(profile.followingCount)", label: "FOLLOWING") {
                listing = .following
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func actions(_ profile: PilotProfile) -> some View {
        HStack(spacing: 8) {
            if profile.isSelf {
                // This used to be the words "This is you." and nothing else,
                // which is the one place in the app where a pilot is looking
                // straight at the thing they want to change and is told only
                // that it is theirs. Editing lived in the account panel, two
                // screens away, and had to be gone and found.
                Button {
                    isEditing = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .bold))
                        Text("Edit profile")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.elevatedFill)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(theme.stroke, lineWidth: 1)
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit your profile")
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
                            .fill(profile.viewerFollows ? theme.surfaceFill : (profile.accentColor ?? theme.accent))
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

    /// The VAs this pilot flies for.
    ///
    /// Handed the ids the profile asked for and the handle to check them
    /// against; `VaBadgeStrip` is what decides which of them are actually
    /// worn, and it decides it against the VAs' own rosters every time it
    /// draws. See the note on that view.
    @ViewBuilder
    private func vaCard(_ profile: PilotProfile) -> some View {
        if !profile.vaAdIds.isEmpty {
            VaBadgeStrip(
                ifUsername: profile.ifUsername,
                wanted: profile.vaAdIds,
                onOpen: { openedVa = $0 }
            )
            .padding(.horizontal, 16)
        }
    }

    /// The flying, and only the flying. Friends and followers moved up to sit
    /// on the follow button; repeating them here would be two answers to the
    /// same question on one screen.
    @ViewBuilder
    private var statsCard: some View {
        // Nothing at all rather than an empty card. The counts that used to
        // guarantee this card had something in it now live above the follow
        // button, so a pilot with no flights logged would otherwise get a bare
        // rounded rectangle.
        if let summary = summary, !summary.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    PilotStat(value: "\(summary.flights)", label: "FLIGHTS")
                    PilotStat(value: "\(summary.hours)", label: "HOURS")
                    PilotStat(value: Format.number(Double(summary.distanceNm)), label: "MILES")
                }

                PanelDivider()

                HStack(spacing: 0) {
                    PilotStat(value: "\(summary.airports)", label: "FIELDS")
                    PilotStat(value: "\(summary.aircraftTypes)", label: "AIRCRAFT")
                    PilotStat(value: "\(summary.regions)", label: "REGIONS")
                }
            }
            .frame(maxWidth: .infinity)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            .padding(.horizontal, 16)
        }
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

                    if let elapsed = live.flightTimeLabel {
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
                    // Fuel sits in the stat row rather than in a detail line
                    // because it is the thing people came to look at.
                    if let fuel = live.fuelLabel {
                        PilotStat(value: fuel, label: "FUEL")
                    }
                }

                // What is being warned about, before what is switched on. An
                // aeroplane that is stalling is the only fact on this card that
                // matters while it is true.
                if live.isStalling == true {
                    detailLine("Warning", "Stalling", symbol: "exclamationmark.triangle.fill")
                }
                if live.isOverspeeding == true {
                    detailLine("Warning", "Overspeed", symbol: "exclamationmark.triangle.fill")
                }

                if let burn = live.fuelBurnLabel {
                    // The endurance is the burn made useful, so it goes on the
                    // same line rather than competing with it for space.
                    if let endurance = live.enduranceLabel {
                        detailLine("Burning", "\(burn) · \(endurance) left", symbol: "fuelpump")
                    } else {
                        detailLine("Burning", burn, symbol: "fuelpump")
                    }
                }
                if let configuration = live.configurationLabel {
                    detailLine("Configured", configuration, symbol: "slider.horizontal.3")
                }
                if let n1 = live.engineN1, n1 > 0 {
                    let engines = live.engineCount.map { "\($0) × " } ?? ""
                    detailLine("Engines", "\(engines)N1 \(n1)%", symbol: "gauge.with.dots.needle.50percent")
                }
                if let wind = live.windLabel {
                    detailLine("Wind", wind, symbol: "wind")
                }
                if let temperature = live.temperatureC {
                    detailLine("Outside", "\(temperature)°C", symbol: "thermometer.medium")
                }
                if let squawk = live.transponderCode {
                    detailLine("Squawk", String(format: "%04d", squawk), symbol: "dot.radiowaves.left.and.right")
                }
                if let waypoint = live.nextWaypoint {
                    detailLine("Next", waypoint, symbol: "point.topleft.down.to.point.bottomright.curvepath")
                }
                if let aircraft = live.aircraft {
                    detailLine("Aircraft", aircraft, symbol: "airplane")
                }

                if !live.atcMessages.isEmpty {
                    PanelDivider()

                    VStack(alignment: .leading, spacing: 7) {
                        Text("ON FREQUENCY")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(theme.textDim)

                        ForEach(live.atcMessages.prefix(5)) { line in
                            HStack(alignment: .top, spacing: 6) {
                                if let from = line.from {
                                    Text(from)
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(theme.accent)
                                        .lineLimit(1)
                                }
                                Text(line.text)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Text("Reported by their simulator, not worked out from the map.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            .padding(.horizontal, 16)

        } else if let live = live, live.hasLastKnown {
            lastKnownCard(live)
        }
    }

    /// The same aeroplane, after the simulator stopped reporting.
    ///
    /// Deliberately not a dimmed copy of the live card. The position is gone —
    /// the server drops it within four minutes of a pilot going quiet, whether
    /// or not their app got the chance to say so — and what is left is the
    /// flight: what they were flying, where to, and what fuel they had. That is
    /// the thing somebody actually wants when they look and find their friend
    /// has dropped off, and it is a fact about an aeroplane rather than a
    /// location.
    @ViewBuilder
    private func lastKnownCard(_ live: PilotLiveStatus) -> some View {
        VStack(alignment: .leading, spacing: 11) {

            HStack(spacing: 8) {
                Circle()
                    .fill(theme.textDim)
                    .frame(width: 7, height: 7)

                Text("Last known")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 8)

                if let seen = live.lastSeenLabel {
                    Text(seen)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                }
            }

            if let route = live.routeLabel {
                Text(route)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
            }

            if let fuel = live.fuelLabel {
                if let burn = live.fuelBurnLabel {
                    detailLine("Fuel", "\(fuel) · burning \(burn)", symbol: "fuelpump")
                } else {
                    detailLine("Fuel", fuel, symbol: "fuelpump")
                }
            }
            if let phase = live.phaseLabel {
                detailLine("Doing", phase, symbol: "airplane.circle")
            }
            if let aircraft = live.aircraft {
                detailLine("Aircraft", aircraft, symbol: "airplane")
            }
            if let elapsed = live.flightTimeLabel {
                detailLine("Airborne", elapsed, symbol: "clock")
            }

            Text("Their simulator stopped reporting. The position is not kept; this is the last reading of the flight.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
        .padding(.horizontal, 16)
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

    /// The bests, which are the part of a logbook people actually read.
    ///
    /// Everything here was already being computed by `pilot_logbook_summary`
    /// and thrown away by the client — the longest flight, the furthest, the
    /// highest, the aircraft and route flown most, and the span the logbook
    /// covers. A profile that shows three numbers out of thirteen is a profile
    /// keeping most of itself to itself.
    @ViewBuilder
    private var recordsCard: some View {
        if let summary = summary, !summary.isEmpty {
            PanelSection(title: "RECORDS") {
                VStack(alignment: .leading, spacing: 9) {
                    if summary.longestMinutes > 0 {
                        detailLine("Longest flight",
                                   Self.blockTime(summary.longestMinutes),
                                   symbol: "clock")
                    }
                    if summary.longestDistanceNm > 0 {
                        detailLine("Furthest flight",
                                   "\(Format.number(Double(summary.longestDistanceNm))) nm",
                                   symbol: "arrow.left.and.right")
                    }
                    if summary.highestFeet > 0 {
                        detailLine("Highest",
                                   "\(Format.number(Double(summary.highestFeet))) ft",
                                   symbol: "arrow.up.to.line")
                    }
                    if let aircraft = summary.topAircraft, !aircraft.isEmpty {
                        detailLine("Flown most", aircraft, symbol: "airplane")
                    }
                    if let route = summary.topRoute, !route.isEmpty {
                        detailLine("Favourite run", route, symbol: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    if let first = summary.firstFlightAt {
                        detailLine("Logbook opened", Self.day.string(from: first), symbol: "calendar")
                    }
                    if let last = summary.lastFlightAt {
                        detailLine("Last flight", Self.day.string(from: last), symbol: "clock.arrow.circlepath")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
        }
    }

    /// The touchdowns, when there are measured ones.
    ///
    /// Its own card rather than another row on the stats block, because it is
    /// the only group here that is *measured* rather than worked out from the
    /// map — and a card can say so, where a row of three numbers cannot.
    @ViewBuilder
    private var landingsCard: some View {
        if let summary = summary, summary.hasMeasuredLandings {
            PanelSection(title: "LANDINGS") {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if let best = summary.bestLandingFPM {
                            PilotStat(value: "\(best)", label: "BEST FPM")
                        }
                        if let average = summary.averageLandingFPM {
                            PilotStat(value: "\(average)", label: "AVG FPM")
                        }
                        if let recent = summary.recentLandingFPM {
                            PilotStat(value: "\(recent)", label: "LAST")
                        }
                    }

                    PanelDivider()

                    HStack(spacing: 0) {
                        PilotStat(value: "\(summary.landingsMeasured)", label: "MEASURED")
                        PilotStat(value: "\(summary.greasers)", label: "GREASED")
                        if let score = summary.bestLandingScore {
                            PilotStat(value: "\(score)", label: "BEST SCORE")
                        }
                    }

                    PanelDivider()

                    Text("Measured by Infinite Flight over Connect, not worked out from the map.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// "6h 20m", or "45m" under the hour — the same shape `LogbookEntry` uses,
    /// so a record and the flight it came from read alike.
    private static func blockTime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

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
