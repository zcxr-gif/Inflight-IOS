import CoreLocation
import SwiftUI

/// The instruments for one aircraft, gathered and drawn.
///
/// Everything either display needs is resolved here — the reading itself, the
/// filed plan, the fields at either end of the route, and the traffic around it
/// — so `PrimaryFlightDisplay` and `NavigationDisplay` stay what they should be:
/// two functions from numbers to pixels, with no idea where the numbers came
/// from.
///
/// The redraw is a `TimelineView` rather than the feed. A packet arrives every
/// few seconds and an artificial horizon fed at that rate does not fly, so the
/// display runs on its own clock and `InstrumentAnimator` walks the drawn values
/// towards the reported ones between packets. That clock only ticks while this
/// view is on screen, which is what keeps it from being a battery cost the rest
/// of the app pays.
struct InstrumentDeck: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var preferences = InstrumentPreferences.shared

    let flightId: String

    /// What the pilot's own simulator says, when they are broadcasting it.
    /// Passed down rather than fetched again: the flight window already asks
    /// once a minute, and two pollers for one row is one too many.
    var sim: PilotLiveStatus?

    /// Bank, worked out from the heading history. Owned by the caller because
    /// it has to survive this view being rebuilt — which happens on every
    /// packet — and an estimator that forgets is an estimator that reports
    /// wings level forever.
    let estimator: InstrumentTurnEstimator

    let animator: InstrumentAnimator

    /// The filed plan, for the navigation display. Resolved by the caller for
    /// the same reason as the sim status.
    var waypoints: [PlanWaypoint] = []

    /// Other aircraft near this one, already narrowed to something worth
    /// drawing.
    var traffic: [NavigationDisplay.Target] = []

    /// Whether the clock below is allowed to run.
    ///
    /// The flight window keeps its full contents in the tree at zero opacity
    /// while the sheet sits at its peek, and a full-screen cover leaves what it
    /// covers mounted. Neither is on screen, and a thirty-a-second redraw of
    /// something nobody can see is battery spent on nothing. Paused, the
    /// display simply holds its last frame.
    var isRunning = true

    /// How often the displays are redrawn. Thirty a second is smooth for an
    /// instrument and half the work of sixty; nothing on either display moves
    /// fast enough to want more.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        Group {
            if let flight = flight {
                // Resolved out here, once per packet. Everything inside the
                // timeline runs thirty times a second, and a dataset lookup at
                // that rate would be thirty times the cost for an answer that
                // changes when the aircraft does.
                let markers = Self.markers(for: flight)

                TimelineView(
                    .animation(minimumInterval: Self.frameInterval, paused: !isRunning)
                ) { context in
                    display(
                        for: shownReading(for: flight, at: context.date),
                        markers: markers
                    )
                }
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder
    private func display(
        for reading: InstrumentReading,
        markers: [NavigationDisplay.Marker]
    ) -> some View {
        switch preferences.display {
        case .pfd:
            PrimaryFlightDisplay(reading: reading)

        case .navigation:
            NavigationDisplay(
                reading: reading,
                mode: preferences.navigationMode,
                rangeNM: preferences.rangeNM,
                waypoints: waypoints,
                markers: markers,
                traffic: preferences.showsTraffic ? traffic : []
            )
        }
    }

    /// What to draw this frame: the feed's reading, walked forward by the
    /// animator so the instrument moves continuously between packets.
    private func shownReading(for flight: Flight, at date: Date) -> InstrumentReading {
        let onGround = FlightPhase.from(flight) == .ground

        let target = InstrumentReading.make(
            flight: flight,
            sim: sim,
            derivedBankDegrees: estimator.bankDegrees(
                groundSpeedKnots: flight.groundSpeedKnots,
                isOnGround: onGround
            )
        )

        return animator.reading(at: date, target: target, flightId: flight.id)
    }

    /// Either end of the filed route, when the dataset knows them.
    private static func markers(for flight: Flight) -> [NavigationDisplay.Marker] {
        var found: [NavigationDisplay.Marker] = []
        if let departure = AirportStore.shared.airport(flight.departureIcao) {
            found.append(
                NavigationDisplay.Marker(
                    name: departure.icao,
                    coordinate: departure.coordinate,
                    kind: .departure
                )
            )
        }
        if let arrival = AirportStore.shared.airport(flight.arrivalIcao) {
            found.append(
                NavigationDisplay.Marker(
                    name: arrival.icao,
                    coordinate: arrival.coordinate,
                    kind: .arrival
                )
            )
        }
        return found
    }

    private var unavailable: some View {
        ZStack {
            InstrumentPalette.screen
            Text("NO DATA")
                .font(InstrumentPalette.digits(12))
                .foregroundStyle(InstrumentPalette.scaleDim)
        }
        .aspectRatio(
            PrimaryFlightDisplay.designSize.width / PrimaryFlightDisplay.designSize.height,
            contentMode: .fit
        )
    }
}

// MARK: - Gathering what the deck needs

/// The bits of the instrument panel that have to outlive a redraw, and the two
/// lookups that are too expensive to do inside one.
///
/// A view struct is rebuilt on every packet, so the turn estimator and the
/// animator cannot live in it as values — both are memories, and a memory that
/// is reset thirty times a second is not one. The traffic list is here for the
/// other reason: narrowing several thousand aircraft down to the few near this
/// one is a pass over the whole feed, which belongs on the packet rather than
/// on the frame.
final class InstrumentSource: ObservableObject {

    /// Redrawn from, so the displays pick up a plan or a sim row the moment it
    /// lands rather than on the next packet.
    @Published private(set) var waypoints: [PlanWaypoint] = []
    @Published private(set) var sim: PilotLiveStatus?
    @Published private(set) var traffic: [NavigationDisplay.Target] = []

    let estimator = InstrumentTurnEstimator()
    let animator = InstrumentAnimator()

    /// Beyond this many, the display is a wall of diamonds and the frame is
    /// paying for aircraft nobody can pick out. The nearest are kept.
    private static let trafficLimit = 40

    private var flightId: String?

    /// Point this at an aircraft. Safe to call repeatedly with the same id.
    func adopt(flightId: String) {
        guard self.flightId != flightId else { return }
        self.flightId = flightId
        waypoints = []
        sim = nil
        traffic = []
        refreshPlan()
        refreshSim()
    }

    /// Called once per packet with everything on the server.
    func ingest(flights: [Flight], rangeNM: Double) {
        guard let flightId = flightId,
              let flight = flights.first(where: { $0.id == flightId }) else { return }

        estimator.ingest(flight: flight)
        refreshTraffic(around: flight, in: flights, rangeNM: rangeNM)

        // The store answers from cache and fetches in the background, so this
        // is a dictionary read on every packet and a request roughly once per
        // aircraft opened.
        let plan = FlightPlanStore.shared.waypoints(for: flightId)
        if plan != waypoints { waypoints = plan }
    }

    /// Asks whether anybody is broadcasting this flight from their simulator.
    ///
    /// Worth its own call rather than sharing the flight window's: the panel
    /// can be opened, left on screen and watched for a long time, and the
    /// window's poll stops mattering the moment the panel is what is being
    /// looked at.
    func refreshSim() {
        guard let wanted = flightId else { return }
        // Hopped explicitly rather than inherited: everything else here is
        // called from a view callback and is already on the main actor, and
        // this is the one path that comes back off one.
        Task { @MainActor [weak self] in
            let status = await PilotDirectory.shared.liveFlight(id: wanted)
            guard let self = self, self.flightId == wanted else { return }
            self.sim = status
        }
    }

    private func refreshPlan() {
        guard let flightId = flightId else { return }
        waypoints = FlightPlanStore.shared.waypoints(for: flightId)
    }

    private func refreshTraffic(around flight: Flight, in flights: [Flight], rangeNM: Double) {
        // A degree of latitude is sixty miles; longitude shrinks with the
        // cosine, and near the poles that divisor goes to nothing — so it is
        // floored rather than left to produce an infinite box.
        let latitudeSpan = rangeNM / 60 * 1.2
        let cosine = max(cos(flight.latitude * .pi / 180), 0.05)
        let longitudeSpan = latitudeSpan / cosine

        var candidates: [(distance: Double, target: NavigationDisplay.Target)] = []

        for other in flights where other.id != flight.id {
            // The cheap test first: everything past this is trigonometry, and
            // on a busy server this rejects all but a handful.
            guard abs(other.latitude - flight.latitude) <= latitudeSpan else { continue }
            var deltaLongitude = abs(other.longitude - flight.longitude)
            if deltaLongitude > 180 { deltaLongitude = 360 - deltaLongitude }
            guard deltaLongitude <= longitudeSpan else { continue }

            let distance = FlightProgress.distanceNM(
                from: flight.coordinate,
                to: other.coordinate
            )
            guard distance <= rangeNM * 1.1 else { continue }

            candidates.append((
                distance,
                NavigationDisplay.Target(
                    id: other.id,
                    coordinate: other.coordinate,
                    altitudeFeet: other.altitudeFeet,
                    verticalSpeedFPM: other.verticalSpeedFPM
                )
            ))
        }

        candidates.sort { $0.distance < $1.distance }
        let wanted = candidates.prefix(Self.trafficLimit).map(\.target)
        if wanted != traffic { traffic = wanted }
    }
}
