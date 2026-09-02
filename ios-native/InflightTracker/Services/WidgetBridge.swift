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

    /// The VA the user chose to keep on their home screen, as a listing id.
    ///
    /// The id and nothing else. The tile needs the VA's name, callsign and
    /// hubs too, but those are rebuilt from the directory on every packet
    /// rather than copied here — a copy is a second place for a VA's own
    /// details to go stale, and the directory is already in memory.
    @Published private(set) var pinnedVaId: String?

    private static let pinnedKey = "widget.pinnedFlightId"
    private static let pinnedAirportKey = "widget.pinnedAirportIcao"
    private static let pinnedVaKey = "widget.pinnedVaId"

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
        pinnedVaId = defaults.string(forKey: Self.pinnedVaKey)
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

    /// Pins a VA, and fetches its logo into the shared cache while doing it.
    ///
    /// The logo is fetched HERE rather than in the snapshot pass. The snapshot
    /// is rebuilt several times a minute and the logo changes about never, so
    /// putting the download on the pin means one request for as long as the
    /// tile is on the home screen — and it means the picture is already in the
    /// cache by the time the first tile renders, rather than the widget's first
    /// impression being a monogram.
    func pinVa(_ ad: VaAd?) {
        pinnedVaId = ad?.id
        if let ad = ad {
            defaults.set(ad.id, forKey: Self.pinnedVaKey)
            // The snapshot is built from the warm directory, so a VA pinned
            // before the directory has landed would sit blank until something
            // else asked for it.
            VaAdsService.shared.warmDirectory()
            cacheLogo(for: ad)
        } else {
            defaults.removeObject(forKey: Self.pinnedVaKey)
        }
        lastReload = .distantPast
    }

    func isVaPinned(_ ad: VaAd) -> Bool { pinnedVaId == ad.id }

    /// Puts a VA's logo where the widget process can read it.
    ///
    /// Skipped when it is already there — a re-pin of the same VA, or a second
    /// launch — so this costs one request per VA ever, not one per pin.
    private func cacheLogo(for ad: VaAd) {
        let key = PhotoKey.make(type: "va", livery: ad.id)
        guard let url = ad.logo, !SharedStore.hasPhoto(for: key) else { return }

        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data = data, !data.isEmpty, data.count <= 4_000_000 else { return }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) { return }
            guard SharedStore.storePhoto(data, for: key) else { return }

            // The tile it was fetched for is on screen already, drawing a
            // monogram. Worth a reload of its own.
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }.resume()
    }

    // MARK: - Snapshot

    /// Rebuild the widget snapshot from the current packet.
    ///
    /// Called on every feed update. Everything expensive — route geometry, the
    /// airport lookups behind it — happens here, in the app, where there is
    /// time for it; the widget process only ever reads finished numbers.
    func update(flights: [Flight], atcStations: [AtcStation] = []) {
        let friendUsernames = Set(FriendsStore.shared.friends)
        let identity = PilotIdentity.shared

        var pinned: WidgetFlight?
        var friends: [WidgetFlight] = []
        var mine: [WidgetFlight] = []

        for flight in flights {
            let isPinned = flight.id == pinnedFlightId
            let isFriend = flight.username.map { friendUsernames.contains($0.lowercased()) } ?? false
            // Carried so a widget can be pointed at "whatever I am flying"
            // without anybody having to pin anything — see the configuration
            // intent in the widget extension. The name check is the same one
            // the map's find-me button makes, and costs nothing at all for the
            // many people who have not filled a name in.
            let isMine = identity.isSet && identity.isMe(flight.username)
            guard isPinned || isFriend || isMine else { continue }

            let converted = widgetFlight(from: flight)
            if isPinned { pinned = converted }
            if isFriend { friends.append(converted) }
            if isMine { mine.append(converted) }
        }

        // Highest first, which for somebody flying two aeroplanes at once is
        // the one they are actually in.
        mine.sort { $0.altitudeFt > $1.altitudeFt }

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
            mine: mine,
            friendCount: FriendsStore.shared.count,
            airport: pinnedAirport(in: flights, atcStations: atcStations),
            va: pinnedVa(in: flights),
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

    /// The pinned VA's fleet, worked out on the packet the app already has.
    ///
    /// `VaAdsService.fleet(of:in:)` is the same matcher the VA's own panel
    /// uses, so the tile and the panel cannot disagree about whose aeroplane is
    /// whose. Nil while the directory is still loading, which leaves the tile
    /// showing its last good render rather than blanking it.
    private func pinnedVa(in flights: [Flight]) -> WidgetVa? {
        guard let id = pinnedVaId,
              let ad = VaAdsService.shared.warmListing(id: id) else { return nil }

        let fleet = VaAdsService.shared.fleet(of: ad, in: flights)

        // Airborne first, then highest — the aeroplane at cruise is the one
        // worth the top row, and one on a stand is the one worth the last.
        let sorted = fleet.sorted { lhs, rhs in
            let lhsUp = lhs.altitudeFeet >= 1_000 || lhs.groundSpeedKnots >= 40
            let rhsUp = rhs.altitudeFeet >= 1_000 || rhs.groundSpeedKnots >= 40
            if lhsUp != rhsUp { return lhsUp }
            return lhs.altitudeFeet > rhs.altitudeFeet
        }

        let airborne = sorted.filter { $0.altitudeFeet >= 1_000 || $0.groundSpeedKnots >= 40 }

        return WidgetVa(
            id: ad.id,
            name: ad.name,
            callsign: ad.callsign,
            hubs: Array(ad.hubs.prefix(4)),
            totalCount: sorted.count,
            airborneCount: airborne.count,
            // Six, like the airport tile's arrivals: more than the largest
            // family draws, so one snapshot serves them all.
            fleet: sorted.prefix(6).map { flight in
                WidgetMovement(
                    id: flight.id,
                    callsign: flight.displayName,
                    aircraftType: flight.aircraftName,
                    detail: "\(endpoint(flight.departureIcao)) → \(endpoint(flight.arrivalIcao))"
                )
            },
            hasLogo: SharedStore.hasPhoto(for: PhotoKey.make(type: "va", livery: ad.id)),
            capturedAt: Date()
        )
    }

    /// An endpoint, or the mark that stands in for one that was never filed —
    /// the same one `VaDetailSheet` prints, so the tile reads like the panel.
    private func endpoint(_ icao: String?) -> String {
        let value = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "———" : value
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
        // My own aeroplane is a thing a widget can be pointed at directly, so
        // its photograph has to be in the cache whether or not it is pinned.
        wanted.append(contentsOf: snapshot.myFlights.prefix(1))
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
            // In the signature for the same reason the friends are: a widget
            // can be pointed at my own aircraft, so my own take-off is news.
            snapshot.myFlights.map { "\($0.id):\($0.phaseLabel)" }.joined(separator: ","),
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
