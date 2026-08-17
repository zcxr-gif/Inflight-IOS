import Combine
import Foundation
import WidgetKit

/// Keeps the home-screen widgets fed from the live socket.
///
/// The socket delivers the whole server several times a minute; widgets are
/// allowed a few dozen refreshes a *day*. Almost all of the work here is
/// therefore about not spending that budget: the snapshot on disk is rewritten
/// often and cheaply, but `WidgetCenter` is only asked to reload when
/// something a person would notice has changed — the pinned aircraft, or which
/// friends are in the air — and never more than once every few minutes
/// regardless. A widget that burns its budget by lunchtime spends the
/// afternoon showing a stale tile, which is worse than one that updates on a
/// slower cadence all day.
final class WidgetBridge: ObservableObject {

    static let shared = WidgetBridge()

    /// The flight the user chose to keep on their home screen.
    @Published private(set) var pinnedFlightId: String?

    /// The field the user chose to keep on their home screen.
    @Published private(set) var pinnedAirportIcao: String?

    private static let pinnedKey = "widget.pinnedFlightId"
    private static let pinnedAirportKey = "widget.pinnedAirportIcao"

    /// How many watched pilots the snapshot carries.
    ///
    /// Was eight, which was the bug: the largest tile draws more than that on
    /// an iPad, and "+3 more" under a list that had already been silently
    /// truncated upstream was counting friends it had thrown away. This is the
    /// data ceiling — each family still draws as many rows as it has room for,
    /// and the number it reports is now the real one.
    private static let friendCapacity = 24

    private let defaults: UserDefaults

    /// Floor on how often the system is asked to re-render.
    private static let reloadInterval: TimeInterval = 5 * 60
    private var lastReload = Date.distantPast

    /// What the last reload was for. A change here beats the interval — the
    /// point of the throttle is to suppress repetition, not news.
    private var lastSignature = ""

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        pinnedFlightId = defaults.string(forKey: Self.pinnedKey)
        pinnedAirportIcao = defaults.string(forKey: Self.pinnedAirportKey)
    }

    // MARK: - Pinning

    func pin(_ flightId: String?) {
        pinnedFlightId = flightId
        if let flightId = flightId {
            defaults.set(flightId, forKey: Self.pinnedKey)
        } else {
            defaults.removeObject(forKey: Self.pinnedKey)
        }
        // An explicit user action deserves an immediate tile, budget or not.
        lastReload = .distantPast
    }

    func isPinned(_ flightId: String) -> Bool { pinnedFlightId == flightId }

    func pinAirport(_ icao: String?) {
        let key = icao?.uppercased()
        pinnedAirportIcao = key
        if let key = key {
            defaults.set(key, forKey: Self.pinnedAirportKey)
        } else {
            defaults.removeObject(forKey: Self.pinnedAirportKey)
        }
        lastReload = .distantPast
    }

    func isAirportPinned(_ icao: String) -> Bool {
        pinnedAirportIcao == icao.uppercased()
    }

    // MARK: - Snapshot

    /// Rebuild the widget snapshot from the current packet.
    ///
    /// Called on every feed update. Everything expensive — route geometry, the
    /// airport lookups behind it — happens here, in the app, where there is
    /// time for it; the widget process only ever reads finished numbers.
    func update(flights: [Flight], atcStations: [AtcStation] = []) {
        let friendUsernames = Set(FriendsStore.shared.friends)

        var pinned: WidgetFlight?
        var friends: [WidgetFlight] = []

        for flight in flights {
            let isPinned = flight.id == pinnedFlightId
            let isFriend = flight.username.map { friendUsernames.contains($0.lowercased()) } ?? false
            guard isPinned || isFriend else { continue }

            let converted = widgetFlight(from: flight)
            if isPinned { pinned = converted }
            if isFriend { friends.append(converted) }
        }

        // Airborne first, then whoever is furthest along — the friend about to
        // land is the one worth the top row of a small widget.
        friends.sort { lhs, rhs in
            let lhsAirborne = lhs.altitudeFt >= 1_000 || lhs.groundSpeedKt >= 40
            let rhsAirborne = rhs.altitudeFt >= 1_000 || rhs.groundSpeedKt >= 40
            if lhsAirborne != rhsAirborne { return lhsAirborne }
            return (lhs.progress ?? 0) > (rhs.progress ?? 0)
        }

        let snapshot = WidgetSnapshot(
            pinned: pinned,
            friends: Array(friends.prefix(Self.friendCapacity)),
            friendCount: FriendsStore.shared.count,
            airport: pinnedAirport(in: flights, atcStations: atcStations),
            updatedAt: Date()
        )
        SharedStore.save(snapshot)

        prefetchPhotos(for: snapshot)
        reloadIfWorthwhile(snapshot)
    }

    /// The pinned field, worked out here for the same reason route geometry is:
    /// it is a pass over the whole packet plus an airport-table lookup, and the
    /// widget process has neither the table nor the time.
    private func pinnedAirport(in flights: [Flight], atcStations: [AtcStation]) -> WidgetAirport? {
        guard let icao = pinnedAirportIcao,
              let airport = AirportStore.shared.airport(icao) else { return nil }

        let activity = AirportActivity.at(airport, in: flights)
        let metar = WeatherService.shared.cached(airport.icao)

        return WidgetAirport(
            icao: airport.icao,
            name: airport.name,
            flag: airport.flag,
            inboundCount: activity.inbound.count,
            departedCount: activity.outbound.count,
            onGroundCount: activity.onGround.count,
            atcPositions: atcPositions(at: airport.icao, in: atcStations),
            conditions: metar?.conditionLabel,
            temperature: metar.map { $0.temperatureLabel(in: WeatherPreferences.shared.temperatureUnit) },
            // Six is more than the largest tile draws, so the same snapshot
            // serves every family without the app guessing which is installed.
            arrivals: activity.inbound.prefix(6).map { movement in
                WidgetMovement(
                    id: movement.flight.id,
                    callsign: movement.flight.displayName,
                    aircraftType: movement.flight.aircraftName,
                    detail: movement.etaLabel ?? "\(Int(movement.distanceNM.rounded())) NM"
                )
            },
            hasPhoto: SharedStore.hasPhoto(for: PhotoKey.make(type: "airport", livery: airport.icao)),
            capturedAt: Date()
        )
    }

    private func atcPositions(at icao: String, in stations: [AtcStation]) -> [String] {
        guard let station = stations.first(where: { !$0.isCenter && $0.identifier == icao }) else {
            return []
        }
        return station.facilities.map { $0.kind.code }
    }

    private func widgetFlight(from flight: Flight) -> WidgetFlight {
        let progress = FlightProgress(flight: flight)
        let ete = progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots)

        return WidgetFlight(
            id: flight.id,
            callsign: flight.displayName,
            username: flight.username ?? "",
            aircraftType: flight.aircraftName,
            liveryName: flight.liveryName,
            registration: flight.registration ?? "",
            departureIcao: flight.departureIcao ?? "",
            arrivalIcao: flight.arrivalIcao ?? "",
            altitudeFt: Int(flight.altitudeFeet),
            groundSpeedKt: Int(flight.groundSpeedKnots),
            verticalSpeedFPM: Int(flight.verticalSpeedFPM),
            flownNM: progress?.flownNM ?? 0,
            remainingNM: progress?.remainingNM ?? 0,
            totalNM: progress?.totalNM ?? 0,
            eta: ete.map { Date().addingTimeInterval($0) },
            capturedAt: Date()
        )
    }

    // MARK: - Photos

    /// Make sure the aircraft on screen have their photos in the shared cache.
    ///
    /// This is the only reason the widgets can draw a real aircraft at all: a
    /// widget cannot afford to go to the network for a background, so the app
    /// puts one where it will be found. Cheap in the common case — the photo
    /// service caches in memory and the group cache is checked first, so a
    /// steady state does no work.
    private func prefetchPhotos(for snapshot: WidgetSnapshot) {
        var wanted: [WidgetFlight] = []
        if let pinned = snapshot.pinned { wanted.append(pinned) }
        // Only the friends a widget could actually show. Fetching all eight
        // would fill the cache with backgrounds nothing draws.
        wanted.append(contentsOf: snapshot.friends.prefix(3))

        // The pinned field's own photograph, on the same terms: fetched by the
        // app because a widget cannot go to the network, and only when it is
        // not already sitting in the shared cache.
        if let airport = snapshot.airport, !SharedStore.hasPhoto(for: airport.photoKey) {
            let key = airport.photoKey
            AirportImageService.shared.image(for: airport.icao) { url in
                guard let url = url else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data = data, SharedStore.storePhoto(data, for: key) else { return }
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .resume()
            }
        }

        for flight in wanted where !flight.aircraftType.isEmpty {
            let key = flight.photoKey
            guard !SharedStore.hasPhoto(for: key) else { continue }

            AircraftPhotoService.shared.photo(type: flight.aircraftType, livery: flight.liveryName) { photo in
                guard let photo = photo else { return }
                URLSession.shared.dataTask(with: photo.url) { data, _, _ in
                    guard let data = data else { return }
                    // Downscales and prunes on the way in — see SharedStore.
                    guard SharedStore.storePhoto(data, for: key) else { return }
                    // The tile is drawn on this photo, so it is worth a render
                    // the moment one arrives for the flight being shown.
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .resume()
            }
        }
    }

    // MARK: - Reloads

    private func reloadIfWorthwhile(_ snapshot: WidgetSnapshot) {
        // Identity and phase, not position: an aircraft moving a mile is not
        // worth a render, but one that took off or landed is.
        let signature = [
            snapshot.pinned?.id ?? "-",
            snapshot.pinned?.phaseLabel ?? "-",
            snapshot.friends.map { "\($0.id):\($0.phaseLabel)" }.joined(separator: ","),
            String(snapshot.friendCount),
            snapshot.airport.map { "\($0.icao):\($0.movementCount):\($0.atcPositions.joined())" } ?? "-"
        ].joined(separator: "|")

        let changed = signature != lastSignature
        let due = Date().timeIntervalSince(lastReload) >= Self.reloadInterval
        guard changed || due else { return }

        lastSignature = signature
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
