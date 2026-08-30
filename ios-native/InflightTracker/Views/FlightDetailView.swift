import SwiftUI
import UIKit

/// The flight info window.
///
/// Two phases, stacked and cross-faded: the peak state (`FlightInfoPeak`) the
/// sheet opens in, and the full window below.
///
/// The swap rides the sheet's measured height rather than its detent. A detent
/// binding only changes once a drag commits, so the phases used to swap on
/// their own animation curve while UIKit resized the sheet on another — which
/// is why collapsing left the big photo sitting there until the drag landed
/// and then cut. Reading the height instead makes the cross-fade track the
/// finger, and behave the same in both directions.
///
/// The flight is re-read from the feed by id on every update, so everything
/// here keeps ticking while the sheet is open.
struct FlightDetailView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var instruments = InstrumentPreferences.shared
    @StateObject private var photoLoader = AircraftPhotoLoader()
    @StateObject private var imageLoader = RemoteImageLoader()

    /// Set when the window has settled back into the peak state, which is when
    /// the full window's scroll position is rewound.
    @State private var isCollapsed = true

    /// The path this flight has flown — the backend's history once it lands,
    /// extended by live samples. Held here so the profile redraws when it
    /// arrives.
    @State private var track: [TrackPoint] = []

    /// The plan this flight filed, when it filed one. Held here rather than in
    /// the card that draws it so the card is only ever in the tree when there
    /// is a route to put in it — an empty card still costs the stack a gap the
    /// width of its spacing.
    @State private var plan: [PlanWaypoint] = []

    /// What the pilot's own simulator says about this flight, when they are
    /// broadcasting it. Absent for almost every aircraft on the map, which is
    /// why the block that draws it is absent rather than empty.
    @State private var sim: PilotLiveStatus?

    /// The virtual airline named under the route card: the VA whose callsign
    /// this flight is flying, or — failing that — one hubbed at an end of its
    /// route. Resolved once here and handed to both phases, so the peak state
    /// and the full window can't disagree about it or ask for it twice.
    @State private var vaPartner: VaPartner?

    /// The peak state's last measured content height.
    ///
    /// Kept rather than only reacted to: it is what the window rests at, and
    /// every layout pass has to know that to work out how far a drag has
    /// carried the sheet off it. A preference only reports when it changes, and
    /// most passes are passes where it has not.
    @State private var peakContentHeight: CGFloat = 0

    /// The partner whose own panel is open over this window, when one is.
    @State private var viewingPartner: VaAd?

    let flightId: String

    /// Reported upward so the sheet's peak detent is exactly as tall as the
    /// peak state's content, instead of leaving a band of empty sheet below it.
    ///
    /// Meaningless in a pane, which has no detent to be as tall as. The pane
    /// hands in a constant and the writes below go nowhere, which is the right
    /// outcome rather than a tolerated one: there is nothing on the other end
    /// of the binding that wants to know.
    @Binding var peakHeight: CGFloat

    /// How this window is on screen.
    ///
    /// A sheet on a phone, a pane on anything wide enough to choose where to
    /// put it. Everything either way is the same view — the difference is the
    /// three things a sheet has that a pane does not: a detent to travel
    /// between, a ground the system hangs behind it, and a bottom safe area it
    /// draws through.
    var presentation: FlightWindowPresentation = .sheet

    /// Asked for from the window, carried out by the map: the replay needs the
    /// sheet out of the way and the map free, neither of which is this view's
    /// to arrange.
    var onReplay: ([TrackPoint]) -> Void = { _ in }

    /// Opening one end of the route, or the field this aircraft is sitting at.
    /// Swapping one sheet for another is the presenter's business, and so is
    /// remembering the way back here.
    var onSelectAirport: (Airport) -> Void = { _ in }

    /// The window's palette, wearing the airline's colour on its edges when
    /// there is one and the setting is on.
    ///
    /// Resolved here and here only: every part of this window — the peak state,
    /// the cards, the sheet's own chrome — is handed `theme` rather than
    /// reaching for `appearance.theme` itself, so one line puts the airline's
    /// colour on all of them and the two phases can never disagree about what
    /// colour they are.
    private var theme: FlightInfoTheme {
        appearance.theme.accented(by: airlineAccent)
    }

    /// The airline's colours for the aircraft that is open, or nil — no livery,
    /// none we hold a colour for, or the switch turned off. All three are the
    /// same outcome: the app's own accent, exactly as it was.
    private var airlineAccent: AirlineAccent.Colours? {
        guard appearance.showsAirlineAccent, let flight = flight else { return nil }
        return AirlineAccent.colours(
            forLivery: flight.liveryName,
            isLight: appearance.theme.isLight
        )
    }

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    /// What the partner lookup actually depends on. The flight itself changes
    /// several times a minute — a new position is not a new answer.
    private var partnerKey: String {
        guard let flight = flight else { return flightId }
        return [flightId, flight.callsign ?? "", flight.departureIcao ?? "", flight.arrivalIcao ?? ""]
            .joined(separator: "|")
    }

    /// Fields with somebody on frequency, for the route card's marker. Centres
    /// are excluded: their identifier is an FIR rather than an ICAO, so one
    /// could never match an endpoint anyway, and leaving them in would only
    /// invite a coincidence to.
    private var controlledFields: Set<String> {
        Set(feed.atcStations.filter { !$0.isCenter }.map(\.identifier))
    }

    var body: some View {
        GeometryReader { geometry in
            let expansion = sheetExpansion(for: geometry)
            // While the sheet is sitting at its peak detent the peak state is
            // the only thing on screen — the full window is not faintly behind
            // it. Both phases are snapped at the foot of the travel rather
            // than left to the ramps, so no residual fraction of a point can
            // put a ghost of the hero photo behind the peak.
            let settled = expansion < 0.02
            let peakOpacity = settled ? 1 : 1 - ramp(expansion, from: 0.02, to: 0.46)
            let fullOpacity = settled ? 0 : ramp(expansion, from: 0.16, to: 0.68)

            ZStack(alignment: .top) {
                if let flight = flight {
                    FlightInfoPeak(
                        flight: flight,
                        image: imageLoader.image,
                        contributor: photoLoader.photo?.contributor,
                        registration: registration(for: flight),
                        theme: theme,
                        style: appearance.peakStyle,
                        width: geometry.size.width,
                        // The peak pages the whole set now, the same as the
                        // window above it. See `FlightInfoPeak.photos`.
                        photos: photoLoader.photos,
                        // Both halves are mounted the whole time; only the one
                        // actually on screen turns its photographs over.
                        isAutoplaying: settled,
                        heroCeiling: heroCeiling,
                        partner: vaPartner
                    )
                        // The peak lays out to the height it *wants*, not to
                        // the height the sheet currently is — and that is the
                        // whole of why the measurement below can be believed.
                        //
                        // Without it the peak is offered the window's own
                        // height, so what it reports back can never be more
                        // than the window already is: a peak that does not fit
                        // measures itself as fitting, the sheet is told it is
                        // the right size, and the route card stays underneath
                        // the bottom of the screen for ever. A measurement that
                        // is allowed to come back larger than the thing being
                        // measured is the only kind worth taking.
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { peak in
                                Color.clear.preference(
                                    key: PeakContentHeightKey.self,
                                    value: peak.size.height
                                )
                            }
                        }
                        // Both phases travel the same way as the sheet grows —
                        // one receding as the other arrives, rather than
                        // crossing past each other.
                        .offset(y: CGFloat(-14 * expansion))
                        .scaleEffect(CGFloat(0.985 + 0.015 * peakOpacity), anchor: .top)
                        .opacity(peakOpacity)
                        // Laid out at its own height, at the top of the window,
                        // and that is the whole arrangement.
                        //
                        // Nothing stretches it to the sheet and nothing pins it
                        // to the foot. Both of those are ways of deciding where
                        // to put slack, and slack is what the sheet is sized
                        // not to have: the peak measures itself, bottom gap
                        // included, and the detent is that measurement. Pinning
                        // to the foot was the previous answer, and when the
                        // sizing went wrong it turned a band under the text
                        // into a hole under the handle — the same bug, moved to
                        // where it shows most.
                        .allowsHitTesting(expansion < 0.3)

                    expanded(for: flight, width: geometry.size.width)
                        .offset(y: CGFloat(14 * (1 - fullOpacity)))
                        .scaleEffect(CGFloat(0.985 + 0.015 * fullOpacity), anchor: .top)
                        .opacity(fullOpacity)
                        .allowsHitTesting(expansion > 0.5)
                } else {
                    ended
                }
            }
            // Pins the window to the sheet's width. Feed strings are arbitrary
            // length, and without a hard width one long airport name or livery
            // widens the whole column and pushes it off both edges.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
            // Derived in the layout pass rather than read back off the proxy
            // afterwards, which is not something a GeometryProxy promises.
            .onChange(of: settled) { _, newValue in isCollapsed = newValue }
            .onPreferenceChange(PeakContentHeightKey.self) { measured in
                // Zero means the peak state isn't in the tree at all — the
                // aircraft stopped reporting — which is not a reason to
                // collapse the sheet around the message that replaced it.
                guard measured > 80 else { return }
                peakContentHeight = measured
                // Whatever the window is doing. This used to be taken only
                // while the sheet was at rest, because it was measured against
                // the container and the container is the whole sheet once the
                // window is open. It is the peak's own content now — the same
                // number at any height — so a photograph that lands while the
                // full window is up is simply the new peak height, with no
                // waiting for a collapse to notice it.
                fitPeak(to: measured)
            }
        }
        .flightInfoLegible(theme)
        // Handed the feed explicitly, like every other sheet this app presents:
        // the partner panel counts that VA's aircraft out of the live packet.
        .sheet(item: $viewingPartner) { ad in
            VaDetailSheet(ad: ad, basis: vaPartner?.basis)
                .environmentObject(feed)
        }
        .modifier(
            FlightInfoWindowChrome(
                theme: theme,
                presentation: presentation,
                accent: airlineAccent
            )
        )
        .environment(\.colorScheme, theme.colorScheme)
        .onAppear {
            load(flight)
            loadTrack()
            loadSim()
            loadPlan()
        }
        // The sim writes its row every 15 to 45 seconds, so re-asking on the
        // sheet's own expansion or on every packet would be waste. A minute is
        // slower than the source changes and faster than anybody notices.
        .task(id: flightId) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                loadSim()
            }
        }
        // Re-asked when the flight's identity or its plan changes, which is
        // what the answer depends on — not on every packet, which is what a
        // plain feed observer would have made of it.
        .task(id: partnerKey) {
            guard let flight = flight else { return }
            let resolved = await VaAdsService.shared.partner(for: flight)
            guard !Task.isCancelled else { return }
            vaPartner = resolved
        }
        .onChange(of: flight?.liveryName) { _, _ in load(flight) }
        .onChange(of: photoLoader.photo?.url) { _, url in imageLoader.load(url) }
        // Live samples extend the path between packets, and the filed plan —
        // which is fetched on first ask and cached — lands a moment after the
        // window opens rather than with it.
        .onChange(of: feed.lastUpdate) { _, _ in
            let latest = FlightTrailStore.shared.points(for: flightId)
            if latest.count != track.count { track = latest }
            loadPlan()
        }
    }

    // MARK: - Phase

    /// How far the sheet is between the peak state and the full window, 0...1.
    ///
    /// Both sides of the sum are the window's own layout space, and neither is
    /// adjusted for an inset. That is not an omission — it is what makes the
    /// comparison sound. `size.height` is the room the window has to lay out
    /// in, and `restingHeight` is what the peak measured *in that same room*,
    /// so whatever the sheet is or is not reserving at its edges is already in
    /// both numbers. Adding an inset back to one of them, which is what this
    /// used to do, is counting it once — and a phantom of a few points reads as
    /// the sheet being a fraction open the moment it appears: the peak opens
    /// washed out, with the full window's photo showing faintly behind it.
    private func sheetExpansion(for geometry: GeometryProxy) -> Double {
        // A pane is the full window and nothing else. There is no peak to
        // collapse to and no drag to ride, so the cross-fade is finished before
        // it starts — and measuring it would be worse than pointless, because a
        // pane is whatever height the layout gave it and that height means
        // nothing about how far open anything is.
        guard presentation == .sheet else { return 1 }

        let travelled = (geometry.size.height - restingHeight - FlightInfoLayout.phaseDeadZone)
            / FlightInfoLayout.phaseTravel
        return Double(min(max(travelled, 0), 1))
    }

    /// The height the window rests at when it is closed — which is the peak's
    /// own measurement, not the detent asked for on its behalf.
    ///
    /// The two are the same once the sheet has caught up, and they are not
    /// while it is catching up: the window opens on a guess, the peak measures
    /// itself, and for a frame or two the sheet is a different height from the
    /// number `peakHeight` now holds. Measured against that number, the
    /// difference reads as somebody having dragged the window open — the peak
    /// washes out and the full window's photograph ghosts in behind it, with
    /// nothing touching the screen. Measured against what the peak actually
    /// needs, a sheet that is still settling is simply a sheet at rest, which
    /// is what it is.
    ///
    /// Through the same clamp the detent is asked for, not the raw
    /// measurement: on the rare peak tall enough to be capped, the two are
    /// different numbers, and the one the sheet is actually resting at is this
    /// one. Comparing against the uncapped measurement would leave a window at
    /// its ceiling permanently reading as "not yet open", which is the drag
    /// never starting.
    private var restingHeight: CGFloat {
        peakContentHeight > 80
            ? clampedPeakHeight(for: peakContentHeight)
            : FlightInfoLayout.openingHeight(for: appearance.peakStyle)
    }

    /// The tallest the peak's photograph may be drawn here.
    ///
    /// Answered against the display: on a large phone this is the flat ceiling
    /// it has always been, and on a small one the photograph gives its room to
    /// the route card underneath it rather than pushing it off the sheet.
    private var heroCeiling: CGFloat {
        presentation == .sheet
            ? FlightInfoLayout.peakHeroCeiling(inScreenHeight: FlightInfoLayout.screenHeight)
            : FlightInfoLayout.peakHeroCap
    }

    /// What the sheet may actually be asked for, given what the peak measured.
    private func clampedPeakHeight(for measured: CGFloat) -> CGFloat {
        let ceiling = FlightInfoLayout.peakCeiling(inScreenHeight: FlightInfoLayout.screenHeight)
        return min(max(measured, FlightInfoLayout.minimumPeakHeight), ceiling)
    }

    /// Report the height the peak needs, which is the height the sheet becomes.
    ///
    /// One assignment, no correction and no second pass — and the reason it can
    /// be that simple is upstream of here. The peak lays out its own bottom gap
    /// rather than trusting the window to leave one, and it lays out at its own
    /// ideal height rather than at the sheet's, so `measured` is the whole
    /// thing it wants and is free to be larger than the window it is currently
    /// in. The sheet takes the number because the stop it is bound to is built
    /// from that number in the same pass — see `ContentView.windowDetent`.
    ///
    /// What was here before was arithmetic against the *container*: work out
    /// what is empty under the peak, and move the detent by the difference. It
    /// is correct arithmetic, and it was a feedback loop — each answer was the
    /// input to the next one. When the sheet declined a resize, which is what a
    /// changing detent set makes it do, the loop had no fixed point to find and
    /// walked itself down to the floor: a window three hundred points tall
    /// asking for a hundred and eighty, with the difference sitting on screen
    /// as a hole. The measurement was never the problem; the loop was.
    private func fitPeak(to measured: CGFloat) {
        guard measured > 80 else { return }

        let wanted = clampedPeakHeight(for: measured)
        if abs(wanted - peakHeight) > 0.5 { peakHeight = wanted }
    }

    /// Smoothstep across a slice of the drag. The two slices overlap, so the
    /// phases dissolve through each other instead of one snapping off as the
    /// other snaps on.
    private func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func load(_ flight: Flight?) {
        guard let flight = flight else { return }
        photoLoader.load(type: flight.aircraftName, livery: flight.liveryName)
        imageLoader.load(photoLoader.photo?.url)
    }

    /// Pulls the flown path the backend already has for this flight, which
    /// covers it from departure rather than from whenever the app happened to
    /// start watching.
    /// Asks whether anybody is broadcasting this flight from their sim.
    ///
    /// Cheap and usually empty: one round trip per window opened, answered by a
    /// single indexed lookup, and for all but a handful of aircraft the answer
    /// is nothing. Refreshed on the same clock as the rest of the window rather
    /// than polled — the sim's own row is written every 15 to 45 seconds, so
    /// there is nothing to gain by asking faster than somebody looks.
    private func loadSim() {
        let wanted = flightId
        Task {
            let status = await PilotDirectory.shared.liveFlight(id: wanted)
            guard wanted == flightId else { return }
            sim = status
        }
    }

    /// The filed plan, from the same store the map draws from.
    ///
    /// Asking is what starts the fetch, and the answer is empty until it lands
    /// — and empty forever for the many pilots who file nothing, which the
    /// store remembers so this stops costing a request.
    private func loadPlan() {
        let latest = FlightPlanStore.shared.waypoints(for: flightId)
        if latest != plan { plan = latest }
    }

    private func loadTrack() {
        track = FlightTrailStore.shared.points(for: flightId)

        // The map asks for this too, and asks first — it gets a layout pass the
        // moment the aeroplane is tapped, where this runs once the sheet has
        // appeared. So by the time the window is up the history is often
        // already in the store, and re-fetching it would be a second identical
        // request for a path that is on screen behind the sheet.
        guard !FlightTrailStore.shared.hasHistory(for: flightId) else { return }

        FlightHistoryService.shared.load(flightId: flightId) { history in
            FlightTrailStore.shared.seed(history, for: flightId)
            track = FlightTrailStore.shared.points(for: flightId)
        }
    }

    private var ended: some View {
        VStack(spacing: 6) {
            Text("Flight ended")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("This aircraft is no longer reporting.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    // MARK: - Expanded window

    private func expanded(for flight: Flight, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            scrollBody(for: flight, width: width)
                // Rewound while the full window is invisible, so coming back up
                // always starts at the photo instead of wherever the last look
                // was left scrolled to.
                .onChange(of: isCollapsed) { _, collapsed in
                    guard collapsed else { return }
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
        }
    }

    private static let topAnchor = "flightInfoTop"

    private func scrollBody(for flight: Flight, width: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // Full bleed, flush with the top of the sheet: the photo is the
                // window's header, not a card inside it.
                FlightHero(
                    image: imageLoader.image,
                    spriteKey: flight.spriteKey,
                    contributor: photoLoader.photo?.contributor,
                    theme: theme,
                    width: width,
                    photos: photoLoader.photos,
                    // Only while the full window is the half being looked at.
                    isAutoplaying: !isCollapsed
                )
                .id(Self.topAnchor)

                VStack(spacing: 12) {
                    header(for: flight)

                    FlightActionRow(
                        flight: flight,
                        theme: theme,
                        track: track,
                        onReplay: { onReplay(track) }
                    )

                    FlightWatchRow(flight: flight, theme: theme)

                    // Grouped, not two children of the stack: the partner
                    // line sits under the bottom edge of the route card, and
                    // the window's outer stack is already at the builder's
                    // ten-view ceiling.
                    VStack(spacing: 12) {
                        // The board has already said where this flight is going
                        // and how far is left, in bigger type and in one place.
                        // Drawing the route card under it would be the same
                        // three facts twice.
                        if !usesBoard(for: flight) {
                            situationCard(for: flight)
                        }

                        // Tappable here and only here. The peak state above
                        // is a drag target from edge to edge, and a control in
                        // it that could take a drag for a tap is how a window
                        // becomes hard to open.
                        VaPartnerLine(
                            partner: vaPartner,
                            theme: theme,
                            onOpen: { ad in viewingPartner = ad }
                        )
                    }

                    telemetry(for: flight)

                    if instruments.isEnabled {
                        InstrumentsCard(
                            flightId: flight.id,
                            theme: theme,
                            // The full window stays mounted behind the peek at
                            // zero opacity, and an instrument redrawing thirty
                            // times a second behind it is work for nobody.
                            isRunning: !isCollapsed
                        )
                            .environmentObject(feed)
                    }

                    if !plan.isEmpty {
                        FiledRouteCard(flight: flight, waypoints: plan, theme: theme)
                    }

                    // Above the sim readout because it is the same source and
                    // the more perishable half of it: which controller you are
                    // working changes on the way in, and the fuel does not.
                    // Draws nothing at all unless this is the aeroplane the
                    // pilot is flying and Connect is attached to it.
                    ConnectFrequencyCard(flightId: flight.id, theme: theme)

                    if let sim = sim {
                        SimReadoutCard(status: sim, theme: theme)
                    }

                    if track.count >= 4 {
                        AltitudeProfileCard(points: track, theme: theme)
                    }

                    HintStrip(placement: .flight)
                }
                .padding(.horizontal, 14)
                // Negative, so the identity block rides the seam where the
                // photo dissolves into the window instead of sitting inside
                // one or the other.
                .padding(.top, -FlightInfoLayout.heroSeamLift)
                // Clears the home indicator, which the window now draws under.
                .padding(.bottom, 40)
                // iPad and landscape keep a phone-width column rather than
                // stretching the cards across the sheet.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            // Same guard the toolbar panels carry: a vertical scroll view still
            // rubber-bands sideways if anything inside it measures wider than
            // the sheet, and the window is full of feed strings that could.
            .frame(width: width)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The head of the open window: the app's own identity block, or the
    /// board.
    ///
    /// The board needs both ends of a route to be a board at all — it is four
    /// rows about a journey — so an aircraft with nothing filed gets the
    /// identity block whichever style is chosen, rather than a board of dashes.
    /// The setting is a preference about how to draw a route, not a promise to
    /// draw one that does not exist.
    @ViewBuilder
    private func header(for flight: Flight) -> some View {
        if let progress = boardProgress(for: flight) {
            FlightInfoBoard(
                flight: flight,
                registration: registration(for: flight),
                theme: theme,
                progress: progress,
                // The backend's history reaches back to the push-back for most
                // flights, so this is usually when it actually left rather than
                // when this app first looked.
                began: FlightTrailStore.shared.firstSeen(for: flight.id),
                onSelectAirport: onSelectAirport
            )
        } else {
            FlightIdentityBlock(
                flight: flight,
                registration: registration(for: flight),
                theme: theme
            )
        }
    }

    /// The route the board would draw, when the board is what is wanted and
    /// there is a route to draw.
    private func boardProgress(for flight: Flight) -> FlightProgress? {
        guard appearance.windowStyle == .board else { return nil }
        return FlightProgress(flight: flight)
    }

    private func usesBoard(for flight: Flight) -> Bool {
        boardProgress(for: flight) != nil
    }

    private func registration(for flight: Flight) -> String {
        let fromFeed = flight.registration ?? ""
        if !fromFeed.isEmpty { return fromFeed }
        return photoLoader.photo?.tailNumber ?? ""
    }

    // MARK: - Route / where it is

    /// A filed destination gets the route strip. Without one, the card says
    /// where the aircraft actually is instead of drawing a route to nowhere.
    @ViewBuilder
    private func situationCard(for flight: Flight) -> some View {
        switch FlightSituation.from(flight) {
        case .enroute(let progress):
            RouteCard(
                flight: flight,
                progress: progress,
                theme: theme,
                onSelectAirport: onSelectAirport,
                controlledFields: controlledFields
            )

        case .grounded(let airport, let isTaxiing):
            PlaceCard(
                kicker: isTaxiing ? "TAXIING AT" : "PARKED AT",
                symbol: isTaxiing ? "airplane" : "parkingsign",
                airport: airport,
                theme: theme,
                icaoSize: 24,
                onSelectAirport: onSelectAirport,
                controlledFields: controlledFields
            )
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)

        case .unplanned(let departure, let nearest):
            VStack(spacing: 12) {
                PlaceCard(
                    kicker: nearest == nil ? "IN THE AIR" : "PASSING",
                    symbol: "airplane",
                    airport: nearest,
                    theme: theme,
                    icaoSize: 24,
                    onSelectAirport: onSelectAirport,
                    controlledFields: controlledFields
                )

                if departure != nil {
                    hairline

                    HStack(spacing: 8) {
                        MiniStat(label: "DEPARTED", value: departure?.icao ?? "—", theme: theme)
                        MiniStat(
                            label: "DESTINATION",
                            value: "NOT FILED",
                            theme: theme,
                            alignment: .trailing
                        )
                    }
                }
            }
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }

    // MARK: - Telemetry

    private func telemetry(for flight: Flight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TELEMETRY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
                .padding(.leading, 2)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                metric(
                    "ALTITUDE", "cloud",
                    Format.number(flight.altitudeFeet), "ft",
                    figure: flight.altitudeFeet
                )
                metric(
                    "GND SPEED", "speedometer",
                    Format.number(flight.groundSpeedKnots), "kts",
                    figure: flight.groundSpeedKnots
                )
                metric(
                    "VERTICAL", "arrow.up.arrow.down",
                    Format.signed(flight.verticalSpeedFPM), "fpm",
                    figure: flight.verticalSpeedFPM
                )
                metric(
                    "HEADING", "safari",
                    Format.heading(flight.heading), "°",
                    figure: flight.heading
                )
            }
        }
        .padding(.top, 2)
    }

    private func metric(
        _ title: String,
        _ symbol: String,
        _ value: String,
        _ unit: String,
        figure: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.8)

                Spacer(minLength: 2)

                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
                    .motionFigure(figure)

                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }
}

/// Sheet chrome. The glass has to be the *sheet's* background rather than a
/// layer inside the content — anything that samples what is behind it, drawn
/// inside a sheet whose background was cleared, has nothing to sample and
/// renders as a black slab.
private struct FlightInfoWindowChrome: ViewModifier {

    let theme: FlightInfoTheme
    let presentation: FlightWindowPresentation

    /// Drawn as a hairline round the sheet itself when the open aircraft has an
    /// airline colour. Nil is the ordinary case and draws nothing at all: the
    /// sheet has never had an outline and is not getting one by default.
    ///
    /// The pane needs no equivalent — it draws its own border, from the same
    /// tinted theme, and knows where its edges are.
    var accent: AirlineAccent.Colours? = nil

    /// The radius the sheet is actually rounded to, so the outline traces the
    /// sheet's edge rather than sitting a couple of points off it.
    private var cornerRadius: CGFloat { theme.radiusLarge + 6 }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .sheet:
            content
                // The sheet's own ground already covers the home indicator, and
                // the peak's card should sit close to the bottom edge rather
                // than above a band of empty sheet the width of that inset.
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if let accent = accent {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            // A stroke *border* rather than a stroke: it is laid
                            // inside the shape, so none of it is cut off by the
                            // sheet's own clip.
                            .strokeBorder(accent.tint.opacity(0.55), lineWidth: 1)
                            .ignoresSafeArea(edges: .bottom)
                            // Over the whole window, including its scroll view.
                            // Nothing here is meant to be pressed.
                            .allowsHitTesting(false)
                    }
                }
                .presentationBackground { theme.sheetBackground }
                .presentationCornerRadius(cornerRadius)

        case .pane:
            // None of the above applies, and it is not that they are harmless
            // — the presentation modifiers would be talking to a presentation
            // that isn't there, and the safe area is one the pane's own layout
            // has already inset it from. The pane draws its own ground and
            // clips its own corners, because it knows where its edges are and
            // a modifier hung on a sheet does not.
            content
        }
    }
}

/// Loads the community photographs for one aircraft type + livery.
final class AircraftPhotoLoader: ObservableObject {

    @Published private(set) var photos: [AircraftPhoto] = []

    /// The first one, which is what everything outside the header wants: the
    /// peak's thumbnail, the registration, the image the window loads eagerly.
    var photo: AircraftPhoto? { photos.first }

    private var requestedKey: String?

    func load(type: String, livery: String) {
        let key = "\(type)|\(livery)"
        guard requestedKey != key else { return }
        requestedKey = key

        AircraftPhotoService.shared.photos(type: type, livery: livery) { [weak self] resolved in
            guard let self = self, self.requestedKey == key else { return }
            self.photos = resolved
        }
    }
}

/// Number formatting shared by the info window.
enum Format {

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        return decimal.string(from: NSNumber(value: rounded)) ?? String(Int(rounded))
    }

    static func signed(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = Int(value.rounded())
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(number(value))" : "−\(number(abs(value)))"
    }

    static func heading(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        var degrees = Int(value.rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return String(format: "%03d", degrees)
    }

    /// Hours and minutes, as `04:14`.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let totalMinutes = Int((interval / 60).rounded())
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
