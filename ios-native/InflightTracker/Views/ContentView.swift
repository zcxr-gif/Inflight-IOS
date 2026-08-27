import CoreLocation
import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var feed: LiveFeed
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared
    @ObservedObject private var weatherPreferences = WeatherPreferences.shared
    /// Which tile layers are actually being served, for the chip's menu.
    @ObservedObject private var tiles = RainViewerService.shared
    /// Observed for its arrivals rather than read here: a grid of model wind
    /// lands well after the switch that asked for it, and the map only draws
    /// what it is holding when something redraws it. Without this the barbs
    /// waited for the next packet, which is a switch that appears to do
    /// nothing for several seconds.
    @ObservedObject private var winds = WindsAloftStore.shared
    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var entitlements = Entitlements.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var identity = PilotIdentity.shared
    @ObservedObject private var highlightPreferences = PilotHighlightPreferences.shared
    /// The claimed profile, for the avatar in the corner. Observed rather
    /// than read once: a picture uploaded in the editor should appear up here
    /// without the map being rebuilt.
    @ObservedObject private var profiles = ProfileStore.shared

    @State private var selection: SelectedFlight?

    /// Whatever this pilot is flying right now, refreshed once per packet.
    ///
    /// Held in state rather than computed in `body` deliberately: the body runs
    /// far more often than the feed changes, and scanning several thousand
    /// aircraft for one name on every layout pass is the wrong way round — the
    /// same reasoning as the logbook hook below.
    ///
    /// A list, because a pilot can be on more than one server and the feed
    /// reports both. Picking one and hiding the rest is how the friends list
    /// used to lose people's flights.
    @State private var myFlights: [Flight] = []

    /// Height the peak state needs for its own content, reported back by the
    /// window once it has measured itself.
    @State private var peakHeight = FlightInfoLayout.basePeakHeight

    /// The flight window's handle, held under a finger.
    @GestureState private var isWindowHeld = false

    /// Which phase the info window is in. Owned here so it can be reset to the
    /// peak state each time a different aircraft is tapped.
    @State private var detent: PresentationDetent = .height(FlightInfoLayout.basePeakHeight)

    /// Latest camera request from the chrome around the map.
    @State private var mapCommand: MapCommand?

    /// The ruler: whether it is down, and the leg it is measuring.
    @State private var measurement = MapMeasurement()

    /// Whether the stats are pulled up over the toolbar. Here rather than in
    /// the tab itself because the chrome in the two bottom corners has to move
    /// out of the way of the card while it is up.
    @State private var isStatsUp = false

    /// Whether the sky view is up: the camera, with the traffic drawn over it.
    @State private var isShowingSky = false

    /// Whether the map is staying with the open aircraft. Lives here rather
    /// than in the map so it can be turned off by the things that contradict
    /// it — framing a whole route, or closing the window entirely.
    @State private var isFollowing = false

    /// The flight an open field panel was reached from, so it can be gone back
    /// to. Nil whenever the field was opened from anywhere with nothing behind
    /// it — the search results, the ATC panel, the board.
    @State private var airportOrigin: SelectedFlight?

    /// What has been typed into the search field at the top of the map.
    @State private var query = ""

    /// Weather for the field the map is over, and for the open flight's route.
    @StateObject private var weather = WeatherModel()

    /// The weather drawn under the traffic — which layer, and which frame of
    /// it while the radar is running.
    @StateObject private var mapWeather = MapWeatherModel()
    @State private var isWeatherExpanded = false

    /// Playback of the open aircraft's own track, started from the window and
    /// watched on the map.
    @StateObject private var replay = FlightReplay()

    private var theme: FlightInfoTheme { appearance.theme }

    private var peakDetent: PresentationDetent { .height(peakHeight) }

    /// Rebuilt each redraw, and compared by value inside the map — so watching
    /// a new pilot, picking a colour, or Pro lapsing all repaint the traffic
    /// without anything here having to know that it should.
    private var highlighting: PilotHighlighting { PilotHighlighting.current() }

    /// How many uncontrolled fields the map marks, on top of every field
    /// somebody is working. Enough to show where the server actually is,
    /// short of littering the map with places one aircraft filed through.
    private static let busiestAirportsOnMap = 40

    /// Fields to mark. Empty when the toggle is off, which is the whole switch.
    ///
    /// Held in state and recounted once per packet rather than worked out in
    /// `body`, for the same reason `myFlights` is: ranking the fields walks
    /// every aircraft on the server twice over, upper-casing two ICAOs apiece,
    /// and the body runs far more often than the feed changes — on every
    /// keystroke in the search field, every time a chip opens, and twenty times
    /// a second for the length of a replay.
    @State private var mapAirports: [MapAirport] = []

    /// Bumped whenever the list above is rebuilt, so the map can tell whether
    /// its markers need re-diffing without comparing the two lists.
    @State private var airportsRevision = 0

    /// Watched pilots the feed can currently see, for the toolbar's badge.
    /// Counted per packet rather than per redraw, and for the same reason: it
    /// is a walk over the whole server, lower-casing a name per aircraft.
    @State private var friendsAloft = 0

    private func refreshMapAirports() {
        let fields = filters.showsAirports
            ? MapAirport.active(
                in: feed.flights,
                stations: feed.atcStations,
                busiestLimit: Self.busiestAirportsOnMap
            )
            : []

        // `MapAirport` compares by what is drawn, so an unchanged ranking
        // publishes nothing and the map is left alone.
        guard fields != mapAirports else { return }
        mapAirports = fields
        airportsRevision &+= 1
    }

    private func refreshFriendsAloft() {
        // The store keeps this set, lowercased, and rebuilds it only when
        // somebody is added or removed.
        let watched = friends.watched
        guard !watched.isEmpty else {
            if friendsAloft != 0 { friendsAloft = 0 }
            return
        }

        var seen = Set<String>()
        for flight in feed.flights {
            guard let username = flight.username?.lowercased(), watched.contains(username) else { continue }
            seen.insert(username)
        }

        if friendsAloft != seen.count { friendsAloft = seen.count }
    }

    /// Opened from the avatar button, and from Settings.
    @State private var isShowingAccount = false

    /// The pilot page the avatar opened. Held as a link rather than a flag so
    /// the same sheet can later be pointed at somebody else.
    @State private var viewingProfile: ProfileLink?

    /// Raised from the avatar's menu, for an account without Pro.
    @State private var isShowingProPaywall = false

    /// Raised when a locked map style is picked.
    @State private var isShowingStylePaywall = false

    /// Raised when somebody without Pro asks to be taken to their own aircraft.
    @State private var isShowingFindMePaywall = false

    /// A widget tap that hasn't been acted on yet.
    ///
    /// A field resolves offline and lands immediately. An aircraft cannot: the
    /// tap may well have launched the app, and the feed is still connecting, so
    /// the id is held here and retried as packets arrive — the same shape as a
    /// tapped push notification. It is dropped after a while rather than
    /// waiting forever for an aircraft that has landed.
    @State private var pendingFlightId: String?
    @State private var pendingSince = Date.distantPast

    /// How long a widget tap keeps looking for its aircraft.
    private static let pendingLinkWindow: TimeInterval = 20

    /// What the sheet is showing. A view can only present one thing at a time,
    /// so the flight window, the toolbar's panels and a field all share this
    /// rather than each carrying their own `.sheet`.
    ///
    /// The flight case's id doesn't change with the aircraft, which is what
    /// lets tapping a second plane swap the window's contents instead of
    /// dismissing and re-presenting the sheet — a re-presentation loses the
    /// peak detent and comes back at full height.
    private enum WindowSheet: Identifiable, Equatable {
        case flight
        case panel(MapPanelKind)

        /// A field — from the search results, the ATC panel, the board, or an
        /// open flight's route card. Carries the ICAO rather than the `Airport`
        /// so the case stays `Equatable` and cheap; the dataset resolves it
        /// back when the sheet is built.
        case airport(String)

        var id: String {
            switch self {
            case .flight: return "flight"
            case .panel(let kind): return kind.rawValue
            case .airport(let icao): return "airport|\(icao)"
            }
        }
    }

    @State private var sheet: WindowSheet?

    /// The traffic the map draws: the packet, narrowed by the filters, with the
    /// open aircraft kept whatever they say.
    private var visibleFlights: [Flight] {
        filters.apply(to: feed.flights, keeping: selection?.id)
    }

    /// Search runs over the whole packet rather than `visibleFlights` — a
    /// callsign you have typed out in full is one you want found, not one the
    /// altitude filter gets to hide.
    private var results: [MapSearchResult] {
        MapSearch.results(for: query, in: feed.flights, limit: 6)
    }

    /// A stamp of everything that decides which aircraft the map should be
    /// drawing: the packet it came from, the filters narrowing it, and the one
    /// aircraft that is kept whatever they say.
    ///
    /// The map skips its whole annotation diff when this has not moved. Without
    /// it every redraw walked the server — and the body redraws for reasons
    /// that have nothing to do with the traffic.
    private var trafficRevision: Int {
        var hasher = Hasher()
        hasher.combine(feed.lastUpdate)
        hasher.combine(filters.signature)
        hasher.combine(selection?.id)
        return hasher.finalize()
    }

    /// How much of the bottom of the map is spoken for: the toolbar, or the
    /// window sitting over it.
    ///
    /// Hoisted out of the map's argument list along with the two below it, and
    /// not for tidiness. Swift type-checks a view's body as one expression, and
    /// the cost of that climbs steeply with the size of it — a `body` this long
    /// with conditionals and operators buried in a twenty-argument call is how
    /// a build starts failing with "unable to type-check this expression in
    /// reasonable time". Every one of these is a separate, trivially solved
    /// expression now.
    private var mapBottomInset: CGFloat {
        selection == nil ? MapDock.reservedHeight : peakHeight
    }

    /// How far up the map has to hold Apple's "Legal" link so the app's own
    /// chrome is not sitting on it.
    ///
    /// The same bottom edge the camera keeps clear of, plus the stats card
    /// while it is up. The card *is* counted here and deliberately is not
    /// counted above: framing a route is a one-off the card has no business
    /// shrinking, but a link hidden behind the card for as long as the card is
    /// up is a link Apple's terms say has to be visible.
    ///
    /// The map reads this as a height above the bottom safe area, which is
    /// exactly what the toolbar is. The flight window is a sheet and measures
    /// itself from the edge of the screen instead, so with one open the link
    /// clears it by the safe area as well — a little generous, and generous is
    /// the side of this to be wrong on.
    private var mapLegalInset: CGFloat {
        mapBottomInset + statsLift
    }

    /// Where the chrome in the two bottom corners starts: above the bar, and
    /// above the lane the legal link now sits in.
    private var cornerInset: CGFloat {
        MapDock.reservedHeight + MapDock.legalLane
    }

    /// How far a pull on the flight window's handle has to be heading to close
    /// it, and how far the other way to open it out. Judged on where the drag
    /// was predicted to end rather than where the finger stopped, so a flick
    /// does it without the travel.
    private static let windowCloseTravel: CGFloat = 90
    private static let windowOpenTravel: CGFloat = 44

    /// How tall the map's own control stack is: three rows with a hairline
    /// between each. Written down because the find-me button stacks on top of
    /// it, and a control that overlaps the one underneath is the kind of thing
    /// a fixed offset quietly becomes when a row is added.
    private static let mapControlsHeight: CGFloat = 42 * 3 + 2

    /// A replay is driving the camera down the old track; following the live
    /// aircraft at the same time would be two things fighting over one map.
    private var isFollowingLive: Bool { isFollowing && !replay.isActive }

    /// A field tapped on the map. No origin: it was not arrived at from an
    /// aircraft, even if one happens to be open behind it, and offering to go
    /// "back" to one would be inventing a history.
    private func openAirport(fromMap icao: String) {
        guard let field = AirportStore.shared.airport(icao) else { return }
        selection = nil
        openAirport(field)
    }

    /// The map itself, under everything.
    private var map: some View {
        TrackerMapView(
            flights: visibleFlights,
            selection: $selection,
            command: mapCommand,
            bottomInset: mapBottomInset,
            legalInset: mapLegalInset,
            replayFrame: replay.frame,
            isFollowing: isFollowingLive,
            // The map's own answer, which is the app's until a palette says
            // otherwise. The chrome over the map keeps the app's either way: a
            // light map under a dark app is a choice about the cartography,
            // not about the furniture.
            colorScheme: appearance.resolvedMapScheme,
            style: appearance.resolvedMapStyle,
            trafficRevision: trafficRevision,
            airports: mapAirports,
            airportsRevision: airportsRevision,
            showsGroundLayout: filters.showsGroundLayout,
            showsFlightPlan: filters.showsFlightPlan,
            weatherTiles: mapWeather.tiles,
            onWeatherLegibility: { mapWeather.report(legible: $0) },
            measurement: $measurement,
            showsTerminator: filters.showsTerminator,
            showsNatTracks: filters.showsNatTracks,
            showsWinds: weatherPreferences.showsWinds,
            windLevel: weatherPreferences.windLevel,
            showsFieldConditions: weatherPreferences.showsFieldConditions,
            onSelectAirport: { openAirport(fromMap: $0) },
            highlighting: highlighting
        )
        .ignoresSafeArea()
    }

    /// The top row: what you are looking for, or what you have found, and your
    /// own face beside it.
    ///
    /// The avatar is outside the search field's own condition on purpose. It
    /// used to go with it, which meant the one way in to your own profile
    /// disappeared the moment you tapped an aeroplane — and watching an
    /// aeroplane is what people are doing almost all of the time they have this
    /// app open.
    ///
    /// Top-aligned, so the results card drops below the field rather than
    /// pushing the avatar down the screen with it, and so opening the weather
    /// chip drops its card without moving anything either.
    private var topRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if selection == nil {
                MapSearchField(
                    query: $query,
                    results: results,
                    theme: theme,
                    onSelect: open
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // In the corner the search field has just vacated, rather than
                // on a line of its own underneath it. The chip used to sit
                // below this row, which left the top left of the map — the one
                // corner a window at its peak does not cover — empty, with the
                // weather pushed a row down for no reason.
                if weatherPreferences.isChipVisible {
                    WeatherChip(model: weather, theme: theme, isExpanded: $isWeatherExpanded)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: 0)
            }

            profileButton
        }
    }

    /// Map chrome, top down: the search field until an aircraft is open, then
    /// the weather chip in its place — it reports on where that aircraft is, so
    /// there is nothing for it to say without one.
    ///
    /// The search field gives way for the same reason the toolbar does. Once
    /// you have found the aircraft, the field has done its job, and leaving it
    /// there costs the top of the map — which is precisely where a window open
    /// at its peak leaves room to actually watch the thing you just tapped.
    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow

            if weatherPreferences.mapLayer != .off {
                MapWeatherBar(model: mapWeather, theme: theme)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if measurement.isOn {
                MeasureBar(measurement: $measurement, theme: theme)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// Everything on screen: the map, and the chrome floating over it.
    ///
    /// Separated from the modifiers below it so the two are type-checked as two
    /// expressions rather than one very large one.
    private var mapStack: some View {
        ZStack(alignment: .top) {
            map
            topChrome
            mapControls
            weatherControl
            mapStyleControl
            findMeControl
            mapToolbar
            replayBar
        }
    }

    /// The stack, with everything that watches for a change attached.
    private var watchedStack: some View {
        mapStack
        .animation(FlightInfoMotion.panel, value: selection?.id)
        .animation(FlightInfoMotion.panel, value: replay.isActive)
        // The same spring the dock settles its own handle with, so the card
        // and everything that lifts out of its way move as one thing.
        .animation(FlightInfoMotion.panel, value: isStatsUp)
        .onChange(of: selection?.id) { _, id in
            // A replay belongs to the aircraft it was started from, and to the
            // window that drew the track under it. Opening another aircraft,
            // or closing the window, ends it rather than leaving a ghost
            // flying a path nothing on screen refers to.
            if replay.isActive, id != replay.flightId { replay.stop() }

            // Following is about one aircraft. Another one — or none — is not
            // something to carry the mode over to.
            isFollowing = false

            detent = peakDetent

            // The field is on its way out, and it should come back empty rather
            // than holding the query that found this aircraft. Cleared here
            // rather than in the search field itself, which has no idea why it
            // is being dismissed.
            if id != nil { query = "" }

            if id == nil {
                if sheet == .flight { sheet = nil }
            } else if sheet != .flight {
                sheet = .flight
            }

            isWeatherExpanded = false

            // The toolbar and its tab are going away with the window opening
            // over them; the stats should not be waiting up when it closes
            // again, half an hour and three aeroplanes later.
            isStatsUp = false

            updateWeather(force: true)
        }
        // The aircraft keeps moving while its window is open, so the field it
        // is passing is re-resolved as it goes. The model only refetches once
        // the position has actually moved on.
        .onChange(of: feed.lastUpdate) { _, _ in
            // Keeps the home-screen tiles fed. Cheap on every packet — the
            // bridge does the throttling, because only it knows what a widget
            // would actually notice.
            WidgetBridge.shared.update(flights: feed.flights, atcStations: feed.atcStations)

            // And the live banners, which otherwise carry whatever estimate
            // they were started with until the backend next pushes.
            LiveActivityController.shared.refresh(with: feed.flights)

            // A widget tap waiting on the aircraft to appear in a packet.
            if let wanted = pendingFlightId {
                if feed.flights.contains(where: { $0.id == wanted }) {
                    pendingFlightId = nil
                    openFlight(wanted)
                } else if Date().timeIntervalSince(pendingSince) > Self.pendingLinkWindow {
                    pendingFlightId = nil
                }
            }

            // The frame index goes stale on its own clock; this is just the
            // regular tick that notices, and it is a date comparison until the
            // interval is actually up.
            mapWeather.refresh()

            guard selection != nil else { return }
            updateWeather()
        }
        // A tapped notification names a pilot; the map goes and finds them.
        .onChange(of: push.pendingPilot) { _, username in
            guard let username = username else { return }
            push.pendingPilot = nil
            openPilot(username)
        }
        // Whatever takes the sheet away — a drag, or a panel opening — also
        // lets the map go of the aircraft.
        .onChange(of: sheet) { _, value in
            if value != .flight, selection != nil { selection = nil }
        }
    }

    /// The map, everything watching it, and everything it can present.
    ///
    /// The chain is split in two here for the same reason the view tree above
    /// was broken up: one expression carrying a dozen modifiers, several of
    /// them presenting whole view trees of their own, is the sort the compiler
    /// gives up type-checking.
    var body: some View {
        watchedStack
        .sheet(item: $sheet) { which in
            sheetContent(for: which)
        }
        // The detent set changes with the measurement, so the selection has to
        // move to the new value or the sheet snaps to whatever is left.
        .onChange(of: peakHeight) { _, height in
            guard detent != .large else { return }
            // Animated, because this fires on every re-measurement of the peak
            // — a photograph arriving and giving the bar its real height, a
            // route card appearing once the plan is fetched, the peek style
            // being changed with the window already open. Assigned bare, the
            // sheet jumped to the new stop; the whole point of a spring here is
            // that a second measurement arriving mid-travel retargets it rather
            // than restarting it.
            withAnimation(FlightInfoMotion.panel) { detent = .height(height) }
        }
        .sheet(isPresented: $isShowingAccount) {
            // Handed the feed explicitly rather than left to inherit it: the
            // account panel opens a profile, and a profile says whether that
            // pilot is in the air right now.
            AccountPanel().environmentObject(feed)
        }
        .sheet(item: $viewingProfile) { link in
            // Handed the feed explicitly, like every other sheet that opens a
            // profile: a profile says whether that pilot is in the air, and
            // tapping the aircraft it names has to be able to fly the map to it.
            PublicProfileView(link: link) { flight in
                viewingProfile = nil
                selection = SelectedFlight(id: flight.id)
                focus(on: flight.coordinate, spanMeters: 240_000)
            }
            .environmentObject(feed)
        }
        // Full screen rather than a sheet: it is a camera, and a camera behind
        // a card with the map showing round the edges is a viewfinder nobody
        // can aim.
        .fullScreenCover(isPresented: $isShowingSky) {
            SkyView(myFlights: myFlights) { id in
                isShowingSky = false
                openFlight(id)
            }
            // Handed the feed explicitly, like every other thing this view
            // presents: the sky is drawn from the same packet the map is.
            .environmentObject(feed)
        }
        .sheet(isPresented: $isShowingProPaywall) { ProPanel() }
        .sheet(isPresented: $isShowingStylePaywall) { ProPanel(highlighted: .mapStyles) }
        .sheet(isPresented: $isShowingFindMePaywall) { ProPanel(highlighted: .findMyAircraft) }
        .onOpenURL { url in
            guard let link = InflightLink.parse(url) else { return }
            open(link)
        }
        .onAppear {
            feed.connect()
            mapWeather.refresh()
            // Whatever the feed already has, for a view appearing over a
            // connection that has been running — coming back from a sheet, or
            // a second appearance of the map.
            refreshMapAirports()
            refreshFriendsAloft()
        }
        .animation(FlightInfoMotion.fade, value: weatherPreferences.mapLayer)
        .animation(FlightInfoMotion.fade, value: measurement)
        // Pro can end while the app is open, and a tracker is an app people
        // leave open for hours. Coming back to the foreground is the moment to
        // re-ask: a subscription that lapsed overnight, a refund Apple granted,
        // a plan bought on an iPad. Without this the entitlement was worked out
        // at launch and then believed until the next launch.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await Entitlements.shared.refreshFromServer() }
            case .background:
                // A flight that ended while the app was in somebody's pocket is
                // still a flight. Written on the way out rather than lost.
                LogbookRecorder.shared.flush()
            default:
                break
            }
        }
        // ...and if it did end, a replay started while it was live stops. The
        // gate on `FlightReplay.start` covers beginning one; this covers the
        // one already running.
        .onChange(of: entitlements.isPro) { _, _ in
            replay.stopIfUnentitled()
        }
        // Everything derived from a packet, worked out once as it lands rather
        // than every time something asks for it. All four walk the whole
        // server, and the body runs far more often than the feed changes.
        //
        // Keyed on `lastUpdate` rather than on the array itself: `flights` is
        // rebuilt every packet, and comparing thousands of aircraft to decide
        // whether to look at them is the wrong way round.
        .onChange(of: feed.lastUpdate) { _, _ in
            LogbookRecorder.shared.note(flights: feed.flights, server: feed.server)
            refreshMyFlights()
            refreshMapAirports()
            refreshFriendsAloft()
        }
        // The other half of what those three depend on: who is on frequency
        // ranks the fields, the watchlist decides the badge, and the switch
        // decides whether there are any markers at all.
        .onChange(of: feed.stationsUpdate) { _, _ in refreshMapAirports() }
        .onChange(of: filters.showsAirports) { _, _ in refreshMapAirports() }
        .onChange(of: friends.friends) { _, _ in refreshFriendsAloft() }
        .task {
            // Both are launch work rather than panel work: the App Store
            // entitlement decides whether a Pro tile is locked on the first
            // flight window that opens, and the session has to be rebuilt
            // before anything asks who is signed in. Neither blocks the map.
            ProStore.shared.start()
            await AccountStore.shared.restore()
        }
    }

    // MARK: - Panels

    /// Whatever the one sheet is currently showing.
    ///
    /// Its own method rather than a closure inside `body`, and each branch its
    /// own method under that: a `switch` returning three quite different view
    /// trees, written inline, is one more large sub-expression in a body that
    /// the compiler already struggles to type-check as a whole.
    @ViewBuilder
    private func sheetContent(for which: WindowSheet) -> some View {
        switch which {
        case .flight:
            flightWindow
        case .panel(let kind):
            panel(kind)
        case .airport(let icao):
            airportSheet(icao)
        }
    }

    private var flightWindow: some View {
        Group {
            if let selected = selection {
                FlightDetailView(
                    flightId: selected.id,
                    peakHeight: $peakHeight,
                    onReplay: { track in startReplay(of: selected.id, track: track) },
                    onSelectAirport: { field in openAirport(field, from: selected) }
                )
                    // Resets the window's own state per aircraft without taking
                    // the sheet down with it.
                    .id(selected.id)
                    .environmentObject(feed)
            }
        }
        .presentationDetents([peakDetent, .large], selection: $detent)
        // The window draws its own handle over the top of itself, so the
        // system's indicator would be a second pill in the same place.
        .presentationDragIndicator(.hidden)
        .overlay(alignment: .top) { flightWindowHandle }
        .flightInfoSheetInteraction(upThrough: peakDetent)
        // Belt and braces: however the sheet came to be on screen, it starts in
        // the peak state.
        .onAppear { detent = peakDetent }
    }

    /// The flight window's handle.
    ///
    /// The window keeps its two stops — the peak it opens in, and the full
    /// window above that — and the sheet's own drag still moves between them,
    /// one to one, from anywhere on the window that is not a list. What that
    /// drag could not do was close: from full height a pull down landed on the
    /// peak, so shutting the window took two separate gestures, and the second
    /// only worked if you had not scrolled. This pill is the way through both.
    /// Pull it and the window collapses as you go and closes when you let go;
    /// push it and the whole window opens.
    ///
    /// Only as wide as the pill it draws. The rest of the top of the window is
    /// left to the sheet's own gesture, which is better at following a finger
    /// than anything that can be written on top of it.
    private var flightWindowHandle: some View {
        WindowGrabber(theme: theme, isHeld: isWindowHeld)
            .frame(width: 132)
            .frame(maxWidth: .infinity)
            .gesture(flightWindowPull)
            .accessibilityElement()
            .accessibilityLabel("Close the flight window")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { sheet = nil }
            .accessibilityAction(named: "Open the full window") { detent = .large }
    }

    /// Global, like every other pull in the app: the sheet resizes underneath
    /// the finger while this is running, and a translation measured against
    /// something that is itself moving is a translation that fights itself.
    private var flightWindowPull: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($isWindowHeld) { _, state, _ in state = true }
            .onChanged { value in
                // Collapses on the way down, so the pull has something to show
                // for itself before it commits to closing.
                guard detent == .large, value.translation.height > 44 else { return }
                detent = peakDetent
            }
            .onEnded { value in
                let landing = value.predictedEndTranslation.height

                if landing > Self.windowCloseTravel {
                    sheet = nil
                } else if landing < -Self.windowOpenTravel {
                    detent = .large
                }
            }
    }

    /// A field. Resolved here rather than carried in the sheet's case: the
    /// sheet can outlive the search result it was opened from, and an ICAO the
    /// dataset doesn't have is nothing to present.
    @ViewBuilder
    private func airportSheet(_ icao: String) -> some View {
        if let airport = AirportStore.shared.airport(icao) {
            AirportPanel(
                airport: airport,
                onShowOnMap: { field in
                    // Same order as the other panels: close first, then move,
                    // so the field isn't framed underneath the sheet it was
                    // picked in.
                    sheet = nil
                    focus(on: field.coordinate, spanMeters: 90_000)
                },
                onSelectFlight: { flight in
                    sheet = nil
                    selection = SelectedFlight(id: flight.id)
                    focus(on: flight.coordinate, spanMeters: 240_000)
                },
                origin: airportReturn
            )
            .environmentObject(feed)
        }
    }

    @ViewBuilder
    private func panel(_ kind: MapPanelKind) -> some View {
        switch kind {
        case .friends:
            FriendsPanel { flight in
                // Close first, then move: the map's edge padding is sized for
                // the toolbar rather than for a half-height sheet, so the
                // aircraft would otherwise be framed underneath the panel it
                // was picked in.
                sheet = nil
                selection = SelectedFlight(id: flight.id)
                focus(on: flight.coordinate, spanMeters: 240_000)
            }
            .environmentObject(feed)

        // Both of these hand off to the field's own panel rather than closing
        // and moving the map, which the field's first row does anyway. The
        // sheet's identity changes, so this dismisses and re-presents — fine
        // between panels, which carry no detent to lose, and the reason the
        // flight case deliberately keeps one id for every aircraft.
        case .atc:
            AtcPanel { airport in
                openAirport(airport)
            }
            .environmentObject(feed)

        case .airports:
            AirportsPanel { airport in
                openAirport(airport)
            }
            .environmentObject(feed)

        case .stats:
            PulsePanel { airport in
                // Same order as everywhere else that hands off to a field:
                // close first, then move, so the field is not framed under the
                // panel it was picked in.
                sheet = nil
                openAirport(airport)
            }
            .environmentObject(feed)

        case .filters:
            FiltersPanel()
                .environmentObject(feed)

        case .weather:
            WeatherSettingsPanel(model: weather)

        case .settings:
            SettingsPanel()
                .environmentObject(feed)
        }
    }

    // MARK: - Fields

    /// Open a field, remembering the flight it was opened from.
    ///
    /// The sheet's identity changes, which dismisses the flight window and —
    /// through the selection watcher below — lets go of the aircraft. That is
    /// the behaviour every other panel wants; here it is the thing `origin`
    /// exists to undo.
    private func openAirport(_ airport: Airport, from flight: SelectedFlight?) {
        airportOrigin = flight
        sheet = .airport(airport.icao)
    }

    /// Open a field from somewhere with nothing to come back to.
    private func openAirport(_ airport: Airport) {
        openAirport(airport, from: nil)
    }

    /// The back row for the field panel, when there is a flight behind it.
    ///
    /// Named from the packet rather than from whatever the callsign was when
    /// the field was opened, so a flight that has since stopped reporting is
    /// still offered — going back to it lands on the window's own "this flight
    /// has ended" state, which is a better answer than the row quietly
    /// vanishing.
    private var airportReturn: AirportPanel.Origin? {
        guard let origin = airportOrigin else { return nil }

        let label = feed.flights.first { $0.id == origin.id }?.displayName ?? "the flight"

        return AirportPanel.Origin(label: label) {
            // One assignment does it: the selection watcher puts the flight
            // window back up, resets the detent and re-reads the weather, the
            // same as it would for any other way of opening an aircraft.
            selection = origin
        }
    }

    // MARK: - Deep links

    /// Acting on a widget tap.
    private func open(_ link: InflightLink) {
        switch link {
        case .flight(let id):
            // Already in the packet: straight there. Otherwise held for the
            // next few packets — see `pendingFlightId`.
            if feed.flights.contains(where: { $0.id == id }) {
                openFlight(id)
            } else {
                pendingFlightId = id
                pendingSince = Date()
            }

        case .airport(let icao):
            // Resolves against the offline table, so this works on a cold
            // launch with no feed at all.
            guard let airport = AirportStore.shared.airport(icao) else { return }
            selection = nil
            openAirport(airport)

        case .panel(let name):
            guard let kind = MapPanelKind(rawValue: name) else { return }
            selection = nil
            sheet = .panel(kind)
        }
    }

    /// Finds this pilot's own aeroplanes in the packet that has just arrived.
    ///
    /// Bails before the scan when there is no name to match, which is the
    /// ordinary state for anybody who has not filled one in — and the whole
    /// cost of the feature for them.
    private func refreshMyFlights() {
        let identity = PilotIdentity.shared
        guard identity.isSet else {
            if !myFlights.isEmpty { myFlights = [] }
            return
        }

        let mine = feed.flights
            .filter { identity.isMe($0.username) }
            .sorted {
                if $0.altitudeFeet != $1.altitudeFeet { return $0.altitudeFeet > $1.altitudeFeet }
                return $0.id < $1.id
            }

        // Assigning an identical array would still publish a change and rebuild
        // the map's chrome on every packet.
        if mine.map(\.id) != myFlights.map(\.id) { myFlights = mine }
    }

    private func openFlight(_ id: String) {
        sheet = nil
        selection = SelectedFlight(id: id)
        if let flight = feed.flights.first(where: { $0.id == id }) {
            focus(on: flight.coordinate, spanMeters: 240_000)
        }
    }

    // MARK: - Search

    /// Acting on a search result: each kind opens its own window.
    ///
    /// An aircraft is brought into view straight away, since what was picked is
    /// quite possibly not on screen at all. A field isn't: its panel is what
    /// was actually asked for — who is controlling, what is inbound, what is on
    /// the apron — and moving the map under a half-height sheet would frame the
    /// airport somewhere behind it. The panel's own first row does the move,
    /// once the sheet is out of the way.
    private func open(_ result: MapSearchResult) {
        switch result {
        case .flight(let flight):
            selection = SelectedFlight(id: flight.id)
            focus(on: flight.coordinate, spanMeters: 240_000)

        case .airport(let airport):
            // Searching is live over an open flight window, so this can be a
            // swap rather than a fresh presentation. Changing the sheet's
            // identity dismisses and re-presents, which is exactly what the
            // flight case avoids — but what it is avoiding is losing the peak
            // detent, and a panel has no detent state to lose.
            //
            // No origin: a field typed into the search field was not arrived at
            // from anywhere, even if a flight window happened to be open behind
            // it. Offering to go "back" to an aircraft nobody navigated from
            // would be inventing a history.
            selection = nil
            openAirport(airport)
        }
    }

    /// Open the aircraft a notification was about.
    ///
    /// The pilot may well not be in the packet: the push arrives within
    /// seconds of the event, and the app may have been launched by the tap and
    /// still be connecting. Nothing happens in that case rather than something
    /// misleading — the friends panel is where they can be looked up once the
    /// feed has caught up.
    private func openPilot(_ username: String) {
        let wanted = username.lowercased()
        guard let flight = feed.flights.first(where: { $0.username?.lowercased() == wanted }) else { return }
        sheet = nil
        selection = SelectedFlight(id: flight.id)
        focus(on: flight.coordinate, spanMeters: 240_000)
    }

    // MARK: - Replay

    /// Starts playback and gets out of its way: the window drops back to its
    /// peak so the map — which is the thing being watched — is most of the
    /// screen, and the camera is put on the start of the track.
    private func startReplay(of flightId: String, track: [TrackPoint]) {
        guard track.count >= FlightReplay.minimumPoints else { return }

        let title = feed.flights.first { $0.id == flightId }?.displayName ?? "Flight"

        // The store is what refuses a replay this account may not have, so the
        // answer is read rather than the check repeated. Without this the
        // window would still collapse and the camera still move, which looks
        // like a replay that started and then did nothing.
        guard replay.start(flightId: flightId, title: title, points: track) else { return }

        detent = peakDetent

        if let first = track.first {
            focus(on: first.coordinate, spanMeters: 320_000)
        }
    }

    @ViewBuilder
    private var replayBar: some View {
        if replay.isActive {
            ReplayBar(replay: replay, theme: theme)
                .padding(.horizontal, 14)
                // Clears the info window when one is open, and the bottom of
                // the screen when the replay has outlived it.
                .padding(.bottom, selection == nil ? 6 : peakHeight + 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func focus(on coordinate: CLLocationCoordinate2D, spanMeters: Double) {
        mapCommand = MapCommand(
            kind: .focus(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                spanMeters: spanMeters
            )
        )
    }

    /// Weather follows the open aircraft: the field it is passing, and both
    /// ends of its route.
    private func updateWeather(force: Bool = false) {
        guard let selected = selection,
              let flight = feed.flights.first(where: { $0.id == selected.id }) else { return }

        weather.updateNearby(to: flight.coordinate, force: force)
        weather.updateRoute(departure: flight.departureIcao, arrival: flight.arrivalIcao)
    }

    // MARK: - Bottom chrome

    /// The dock, along the bottom while the map is the whole screen. With an
    /// aircraft open the info window is sitting over this, so it gives way to
    /// the window's own controls rather than hiding behind it.
    @ViewBuilder
    private var mapToolbar: some View {
        if selection == nil {
            VStack(spacing: 8) {
                // Above the bar rather than over the map proper: it is an
                // aside about the chrome it is sitting on, and anywhere else
                // it would be something laid over the traffic. The map's
                // reserved inset is not grown to match — hints retire, and
                // permanently shrinking where the map can frame things for
                // something that goes away would be the wrong trade.
                HintStrip(placement: .map, isFloating: true)

                // One card, with the handle on it and the bar inside it. What
                // the handle pulls up opens within the same card rather than
                // as a second one floating above — so there is one shape on
                // the bottom of the screen and it grows when you pull it.
                //
                // The map's reserved inset is not grown to match, for the same
                // reason the hint above is not: the stats are up for as long as
                // they are being read and then gone, and the corners lift out
                // of their way while they are.
                MapDock(
                    theme: theme,
                    atcCount: feed.atcCount,
                    activeFilters: filters.activeCount,
                    friendsAloft: friendsAloft,
                    isStatsUp: $isStatsUp,
                    onPanel: { kind in sheet = .panel(kind) },
                    onOpenStats: {
                        isStatsUp = false
                        sheet = .panel(.stats)
                    }
                )
                .environmentObject(feed)
            }
            // Ten, not fourteen. With the card's own inset and the bar's
            // inside that, fourteen put twenty-six points of nothing between
            // the screen edge and the first tool.
            .padding(.horizontal, 10)
            .padding(.bottom, MapDock.liftOffSafeArea)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // The keyboard is the search field's business. Without this the bar
            // rides up on top of it while a query is being typed.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// The way in to your profile: an avatar beside the search field.
    ///
    /// Top right, where an account lives in almost every app, and on the one
    /// screen you always come back to — Settings still has the same row, but
    /// nobody should have to go three taps deep to find out whether they are
    /// signed in.
    ///
    /// It shows the pilot's actual profile picture once they have claimed a
    /// handle and uploaded one. It used to draw initials whatever was set,
    /// which meant the one place the avatar is always on screen was the one
    /// place it was never their avatar. `PilotAvatar` is the same component the
    /// profile screens use, so the picture here is loaded through the same
    /// cache and falls back to the same initials-on-accent when there is none.
    ///
    /// The state reading survives: a picture or initials means signed in, a
    /// glyph means not, and a dot marks Pro.
    /// The avatar, top right, on every screen the map ever shows.
    ///
    /// A tap goes where somebody tapping their own face expects to go: to their
    /// profile, as other pilots see it. It used to open the account panel, from
    /// which the profile was two more taps and a decision about which of the
    /// rows meant "me" — which is a long way round to your own page.
    ///
    /// Everything that *is* account machinery — signing in, Pro, editing —
    /// hangs off a long press instead, and is still one tap away under
    /// Settings. Signed out there is no profile to show, so the tap falls back
    /// to the panel, which is where signing in happens anyway.
    private var profileButton: some View {
        Button {
            if let handle = profiles.profile?.handle, !handle.isEmpty {
                viewingProfile = .handle(handle)
            } else {
                isShowingAccount = true
            }
        } label: {
            Group {
                if let account = accounts.account, profiles.profile?.avatarURL != nil {
                    PilotAvatar(
                        url: profiles.profile?.avatarURL,
                        // The profile's initials when there is one, because
                        // that is the name other pilots see; the account's
                        // otherwise. Only ever seen for the moment the picture
                        // takes to load, since this branch has one.
                        initials: profiles.profile?.initials ?? account.initials,
                        side: 38
                    )
                } else {
                    // The app's own mark, in the corner it has always kept for
                    // an account. It stands in for the system person glyph
                    // signed out, and for the initials-on-accent circle signed
                    // in without a picture — a pilot who has uploaded one still
                    // gets their own face above.
                    inflightMark
                }
            }
            // Small, and outside the circle, so it reads as a state marker on
            // the avatar rather than as a badge with a number missing.
            .overlay(alignment: .bottomTrailing) {
                if entitlements.isPro {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().strokeBorder(theme.windowFill, lineWidth: 1.5) }
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(Circle())
        // Interactive: one control, so the glass can bend towards the finger
        // the way the system's own does. The stacks below deliberately do not
        // — a pane that lights up as a whole for one button in it is a pane
        // saying the wrong thing about what was pressed.
        .flightInfoChrome(theme, in: Circle(), interactive: true)
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityLabel(profileLabel)
        .accessibilityHint(profiles.profile == nil ? "Opens your account" : "Opens your profile")
        .contextMenu {
            if let handle = profiles.profile?.handle, !handle.isEmpty {
                Button {
                    viewingProfile = .handle(handle)
                } label: {
                    Label("Your profile", systemImage: "person.crop.circle")
                }
            }

            Button {
                isShowingAccount = true
            } label: {
                Label(accounts.isSignedIn ? "Account" : "Sign in", systemImage: "gearshape")
            }

            if !entitlements.isPro {
                Button {
                    isShowingProPaywall = true
                } label: {
                    Label("Inflight Pro", systemImage: "sparkles")
                }
            }
        }
    }

    /// The Inflight pin, sized to sit in the same 38-point circle an avatar
    /// does. Trimmed to its own ink in the asset catalogue rather than padded,
    /// so it fills the button the way a picture would.
    private var inflightMark: some View {
        Image("InflightLogo")
            .resizable()
            .scaledToFit()
            .padding(6)
            .frame(width: 38, height: 38)
    }

    private var profileLabel: String {
        guard let account = accounts.account else { return "Sign in" }
        return entitlements.isPro ? "\(account.handle), Pro account" : account.handle
    }

    /// How far the chrome in the bottom corners moves while the stats card is
    /// up, so it sits above the card rather than behind it.
    private var statsLift: CGFloat {
        isStatsUp && selection == nil && !replay.isActive ? MapDock.statsLift : 0
    }

    /// Weather, on the map's left shoulder.
    ///
    /// The mirror of the style and the ruler on the right: the same chrome, the
    /// same height, the opposite corner. It used to be a seventh of the toolbar
    /// — a whole destination for what is mostly one decision, which layer is
    /// drawn — and putting it here makes that decision one tap from the map
    /// instead of a tap, a panel and a scroll.
    ///
    /// The glyph is the cloud, always, and the cell takes a wash of the accent
    /// while anything is drawn — the same face the ruler and the map style wear
    /// on the opposite shoulder, from the same method. The panel behind it
    /// still exists for the units, the sample and the rest; it is the last item
    /// in the menu.
    @ViewBuilder
    private var weatherControl: some View {
        if selection == nil, !replay.isActive {
            Menu {
                Section("Layer") {
                    // Buttons rather than a `Picker`, for the same reason the
                    // style menu uses them: each one is a decision, and a
                    // checkmark beside the current answer is how the rest of
                    // the app's menus read.
                    //
                    // Only the layers the tile service is actually serving.
                    // RainViewer has been withdrawing its free tier in stages,
                    // and offering a switch that draws nothing is worse than
                    // not offering it.
                    ForEach(availableWeatherLayers) { layer in
                        Button {
                            weatherPreferences.mapLayer = layer
                        } label: {
                            Label(
                                layer.label,
                                systemImage: weatherPreferences.mapLayer == layer ? "checkmark" : layer.symbol
                            )
                        }
                    }
                }

                Section {
                    Button {
                        weatherPreferences.showsWinds.toggle()
                    } label: {
                        Label(
                            "Winds at \(weatherPreferences.windLevel.longLabel)",
                            systemImage: weatherPreferences.showsWinds ? "checkmark" : "wind"
                        )
                    }

                    Button {
                        sheet = .panel(.weather)
                    } label: {
                        Label("Weather settings", systemImage: "slider.horizontal.3")
                    }
                }
            } label: {
                mapControlFace(weatherSymbol, isOn: isWeatherOnMap)
            }
            .accessibilityLabel(weatherLabel)
            .accessibilityAddTraits(isWeatherOnMap ? .isSelected : [])
            .frame(width: 44)
            // Glass draws behind its content rather than clipping it, so
            // without this the accent squares off the chip's corners when a
            // layer is on.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .flightInfoChrome(
                theme,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                interactive: true
            )
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.leading, 16)
            .padding(.bottom, cornerInset + 8 + statsLift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
        }
    }

    /// The tile layers there is any point offering. A withdrawn one stays in
    /// the list only while it is the one selected, so the menu still shows what
    /// the map is set to.
    private var availableWeatherLayers: [MapWeatherLayer] {
        // `tiles` is observed rather than asked: the router reads it, and this
        // needs re-running when what it says changes.
        _ = tiles.state
        return MapWeatherLayer.allCases.filter {
            MapWeatherSource.isAvailable($0) || $0 == weatherPreferences.mapLayer
        }
    }

    /// Anything of the weather actually drawn on the map — tiles under the
    /// traffic, or barbs over it.
    private var isWeatherOnMap: Bool {
        weatherPreferences.mapLayer != .off || weatherPreferences.showsWinds
    }

    /// Always the cloud.
    ///
    /// It used to be whichever layer was drawn — rain, then wind, then a sun
    /// behind a cloud when neither was on — so the control changed shape under
    /// you and never settled into being one thing. The two beside it on the
    /// right do not do that: the ruler is a ruler whether it is down or not.
    /// This is the weather button; what it is showing is the menu's business,
    /// and the wash behind the glyph already says that something is on.
    private let weatherSymbol = "cloud.fill"

    private var weatherLabel: String {
        switch (weatherPreferences.mapLayer, weatherPreferences.showsWinds) {
        case (.off, false): return "Weather"
        case (.off, true): return "Weather, winds at \(weatherPreferences.windLevel.longLabel)"
        case (let layer, false): return "Weather, \(layer.label.lowercased())"
        case (let layer, true):
            return "Weather, \(layer.label.lowercased()) and winds at \(weatherPreferences.windLevel.longLabel)"
        }
    }

    /// Switching the map, or being told why you cannot.
    ///
    /// The choice is still stored when it is refused, which is the point: the
    /// paywall is opened *from* picking the globe, and buying Pro there leaves
    /// you on the globe rather than back where you started having to pick it
    /// again.
    private func select(_ projection: MapProjection) {
        appearance.mapProjection = projection
        if projection.isPro, !entitlements.isPro { isShowingStylePaywall = true }
    }

    private func select(_ palette: MapPalette) {
        appearance.mapPalette = palette
        if palette.isPro, !entitlements.isPro { isShowingStylePaywall = true }
    }

    /// Whether a Pro choice is one this account cannot have yet. Shown rather
    /// than hidden — you cannot want something you have never seen.
    private func locked(_ isPro: Bool) -> Bool { isPro && !entitlements.isPro }

    /// The glyph on the corner button: the shape of the map when it is the
    /// planet, since that is the bigger fact about it, and otherwise whatever
    /// it is drawn in.
    private var mapStyleSymbol: String {
        let style = appearance.resolvedMapStyle
        return style.projection == .globe ? style.projection.symbol : style.palette.symbol
    }

    private var mapStyleLabel: String {
        let style = appearance.resolvedMapStyle
        return "Map style, \(style.projection.label.lowercased()), \(style.palette.label.lowercased())"
    }

    /// How the map is drawn, in the corner that holds the map's controls.
    ///
    /// The same corner as the follow/centre/route hub, and shown on exactly the
    /// opposite condition — so that corner always has the map's own controls in
    /// it, and which ones depends on whether you are watching an aircraft or
    /// looking around. With a window open the hub is the more useful of the two
    /// and this gets out of its way; the style is still under Settings, where it
    /// is stored.
    ///
    /// A menu rather than a cycle button, and now two lists in one menu: the
    /// shape of the world, and what it is drawn in. They were one list of four
    /// styles, which meant the planet only ever came in satellite imagery and
    /// the flat map could never be black.
    @ViewBuilder
    private var mapStyleControl: some View {
        if selection == nil, !replay.isActive {
            // Three controls sharing one piece of chrome, the way the flight
            // window's hub does — so this corner reads as the map's own
            // furniture rather than as loose buttons that happen to be near
            // each other.
            VStack(spacing: 0) {
                // Top of the stack, because it is the one that leaves the map
                // rather than changing it.
                mapButton("camera.viewfinder", "Point the camera at the sky") {
                    isShowingSky = true
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                Menu {
                    // Buttons rather than a `Picker` bound to the setting: some
                    // of these are Pro, and a binding would have already
                    // changed the map by the time anything could check. Each
                    // one decides for itself whether it is switching the map or
                    // opening the paywall.
                    Section("Shape") {
                        ForEach(MapProjection.allCases) { projection in
                            Button {
                                select(projection)
                            } label: {
                                Label(
                                    locked(projection.isPro) ? "\(projection.label) (Pro)" : projection.label,
                                    systemImage: appearance.mapProjection == projection
                                        ? "checkmark"
                                        : projection.symbol
                                )
                            }
                        }
                    }

                    Section("Map") {
                        ForEach(MapPalette.allCases) { palette in
                            Button {
                                select(palette)
                            } label: {
                                Label(
                                    locked(palette.isPro) ? "\(palette.label) (Pro)" : palette.label,
                                    systemImage: appearance.mapPalette == palette ? "checkmark" : palette.symbol
                                )
                            }
                        }
                    }

                    Section {
                        // Nothing to turn up on imagery: it has no roads, no
                        // terrain shading and no emphasis to set.
                        Button {
                            appearance.isMapDetailed.toggle()
                        } label: {
                            Label(
                                "Full detail",
                                systemImage: appearance.isMapDetailed ? "checkmark" : "map.fill"
                            )
                        }
                        .disabled(appearance.resolvedMapStyle.palette.usesImagery)
                    }
                } label: {
                    mapControlFace(mapStyleSymbol, isOn: false)
                }
                .accessibilityLabel(mapStyleLabel)

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                // The ruler lives beside the style rather than in the flight
                // window's hub: measuring is about the map, and it is most
                // wanted when no aircraft is open and you are looking at the
                // shape of somewhere.
                mapButton(
                    "ruler",
                    measurement.isOn ? "Put the ruler away" : "Measure a distance",
                    isOn: measurement.isOn
                ) {
                    measurement.isOn.toggle()
                }
            }
            .frame(width: 44)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.trailing, 16)
            // Clears the toolbar, and the stats card while it is up.
            .padding(.bottom, cornerInset + 8 + statsLift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    /// Straight to the aeroplane you are flying, and its window open on it.
    ///
    /// The map is a map of everybody, and the one aircraft its owner most often
    /// wants is the hardest to find on it: somewhere over an ocean, at a zoom
    /// level where it is a pixel, in a packet of several thousand. `pilotColours`
    /// solves the half of that where the aeroplane is already on screen. This is
    /// the other half.
    ///
    /// Only there when there is somewhere to go — a name on the profile and at
    /// least one aeroplane in the air under it — because a control that does
    /// nothing when tapped is worse than one that is absent. Pro is checked on
    /// the tap rather than by hiding it: somebody who does not have Pro should
    /// be able to see that this exists.
    @ViewBuilder
    private var findMeControl: some View {
        if selection == nil, !replay.isActive, !myFlights.isEmpty {
            Group {
                if myFlights.count == 1 {
                    Button { goToMyAircraft(myFlights[0]) } label: { findMeLabel }
                        .accessibilityLabel("Go to my aircraft")
                } else {
                    // More than one, so the tap has to ask which. Callsigns are
                    // the only thing that tells two of your own flights apart.
                    Menu {
                        ForEach(myFlights) { flight in
                            Button {
                                goToMyAircraft(flight)
                            } label: {
                                Label(
                                    flight.callsign ?? flight.id,
                                    systemImage: "airplane"
                                )
                            }
                        }
                    } label: {
                        findMeLabel
                    }
                    .accessibilityLabel("Go to one of my aircraft")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .flightInfoChrome(
                theme,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                interactive: true
            )
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.trailing, 16)
            // Above the map's own control stack, which sits in the same corner.
            .padding(.bottom, cornerInset + 8 + Self.mapControlsHeight + 8 + statsLift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    private var findMeLabel: some View {
        Image(systemName: entitlements.has(.findMyAircraft) ? "location.magnifyingglass" : "lock")
            // The same fourteen every other glyph over the map is set at. Its
            // cell is a point taller because it is a card on its own rather
            // than a row in the stack, but the glyph in it is not.
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// The whole feature: put the map on it, and open its window.
    private func goToMyAircraft(_ flight: Flight) {
        guard entitlements.has(.findMyAircraft) else {
            isShowingFindMePaywall = true
            return
        }
        openFlight(flight.id)
    }

    /// Sits above the peak state while an aircraft is open. At the full window
    /// the sheet covers this corner anyway, so there is nothing to hide.
    ///
    /// A running replay takes the corner: it is driving the camera itself, and
    /// its bar wants the room these buttons would be sitting in.
    @ViewBuilder
    private var mapControls: some View {
        if selection != nil, !replay.isActive {
            // One grouped control rather than free-floating circles: it reads
            // as part of the window's chrome instead of two loose buttons.
            VStack(spacing: 0) {
                mapButton(
                    "viewfinder",
                    isFollowing ? "Stop following this aircraft" : "Follow this aircraft",
                    isOn: isFollowing
                ) {
                    isFollowing.toggle()
                    // Turning it on takes the map to the aircraft straight
                    // away. Follow itself only acts once the aircraft has
                    // drifted out of the middle of the view, which from a map
                    // pointed somewhere else entirely would leave the mode
                    // looking like it had done nothing.
                    if isFollowing { mapCommand = MapCommand(kind: .centerOnFlight) }
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                mapButton("location.fill", "Centre on aircraft") {
                    mapCommand = MapCommand(kind: .centerOnFlight)
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                mapButton("arrow.down.left.and.arrow.up.right", "Show whole route") {
                    // Framing the whole route and staying with the aircraft are
                    // different intents, and following would pull the camera
                    // back off the route within a packet or two of getting
                    // there.
                    isFollowing = false
                    mapCommand = MapCommand(kind: .fitRoute)
                }
            }
            .frame(width: 44)
            // The follow button fills itself when it is on, and it is the top
            // of the stack. Glass draws behind its content rather than
            // clipping it, so without this the accent squares off the hub's
            // rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, theme.colorScheme)
            .padding(.trailing, 16)
            .padding(.bottom, peakHeight + 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    /// `isOn` is for the one control in the hub that is a mode rather than a
    /// move. It reads as on the way every other switched-on thing in the app
    /// does — filled with the accent, glyph knocked out of it — so the state is
    /// legible without colour carrying the meaning.
    private func mapButton(
        _ symbol: String,
        _ label: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            mapControlFace(symbol, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The face of a map control: one glyph, and the way it says it is on.
    ///
    /// Written once and used by both corners. The weather control on the left
    /// and the stack on the right are the same control in two places, and the
    /// only reason they ever looked like different things is that they were
    /// written out twice and drifted — a point of type size apart, and one of
    /// them lit up far more often than the other.
    private func mapControlFace(_ symbol: String, isOn: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 44, height: 42)
            .background {
                // On is a wash of the accent, not a block of it.
                //
                // The accent is white on the dark themes and near-black on the
                // light ones, so filling the cell with it turned a piece of
                // glass into a solid white or solid black tile and flipped the
                // glyph to match. On the weather control that was almost its
                // permanent state — it counts as on whenever any layer is
                // drawn — so the map's left shoulder was a white square sitting
                // next to three pieces of glass.
                //
                // A wash is how a selected control reads on glass: the pane
                // tints, the glyph stays where it was, and the thing still
                // looks like it is made of the same material as its neighbours.
                if isOn { Rectangle().fill(theme.accent.opacity(0.22)) }
            }
            .contentShape(Rectangle())
    }

}
