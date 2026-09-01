import Foundation
import SwiftUI

/// Everything about this install that belongs to the person rather than to the
/// phone, in one value.
///
/// The tracker was built to work signed out and still does, so every
/// preference in it lives in `UserDefaults`. That was right for an app with no
/// accounts and stopped being right the moment there were some: it meant a new
/// phone was a new start, and `FriendsStore`'s own header said so in as many
/// words. This is the shape that travels — captured from the stores, written
/// to `public.pilot_settings`, and read back on the next device.
///
/// ## Why every field is optional
///
/// Because a blob is written by one build and read by another, in both
/// directions. An older app reading a newer blob drops the keys it has never
/// heard of, which `Codable` does for free. A *newer* app reading an older
/// blob is the case that needs the optionals: a key that was not written must
/// read as "the account has nothing to say about this" and leave the device's
/// own value alone, rather than decoding as `false` and switching something
/// off that nobody touched. Nothing here has a default, on purpose — the
/// defaults live in the stores, which is the only place they can be right.
///
/// ## What is deliberately not in here
///
/// Anything about the device rather than the person. The APNs token is what a
/// push is addressed to; the widget's pinned flight and airport are a choice
/// about one home screen, and syncing them would have a phone quietly repoint
/// an iPad's widget; the terms acceptance is a legal record with its own
/// write, `record_terms_acceptance`. The Infinite Flight handle is absent for
/// a different reason — it is *already* carried, on the account's own
/// `pilotName`, and a second copy here would be a second source of truth for
/// one string. See `PilotIdentity.adoptFromAccount`.
struct SyncedSettings: Codable, Equatable {

    // MARK: - Who you watch

    var watchlist: [String]?
    var notifications: FriendsStore.NotificationPreferences?

    // MARK: - Picking your traffic out

    var highlightEnabled: Bool?

    /// Colours as their three components, the same way they are written to
    /// disk — see `PilotHighlightPreferences.components(of:)`.
    var ownColour: [Double]?
    var friendColour: [Double]?
    var friendColours: [String: [Double]]?

    // MARK: - What the app looks like

    var appearanceMode: String?
    var appPalette: String?
    var glass: Bool?
    var peakStyle: String?
    var windowStyle: String?
    var windowPlacement: String?
    var airlineAccent: Bool?
    var smoothTraffic: Bool?

    // MARK: - What the map looks like, and what is on it

    var mapProjection: String?
    var mapPalette: String?
    var mapDetailed: Bool?
    var mapTerrain: Bool?

    /// The drawn planet's own three. Nothing reads across from the flat map's
    /// palette — they are different pictures — so an account that has never
    /// been on the planet syncs three nulls and lands on the defaults.
    var globeSkin: String?
    var globeBackdrop: String?
    var globePlanes: Bool?

    var filterPhases: [String]?
    var filterBands: [Int]?
    var filterCategories: [String]?
    var filedRouteOnly: Bool?
    var showsAirports: Bool?
    var showsGroundLayout: Bool?
    var routeLine: String?
    var showsPlanFixNames: Bool?
    var showsAtcBoundaries: Bool?
    var showsFlownPath: Bool?
    var showsNatTracks: Bool?
    var showsTerminator: Bool?

    // MARK: - Weather

    var temperatureUnit: String?
    var windUnit: String?
    var weatherChipVisible: Bool?
    var weatherRouteEnds: Bool?
    var weatherLayer: String?
    var animatesRadar: Bool?
    var showsWinds: Bool?
    var windLevel: String?
    var showsFieldConditions: Bool?

    // MARK: - Instruments

    var instrumentsEnabled: Bool?
    var instrumentDisplay: String?
    var navigationMode: String?
    var instrumentRangeNM: Double?
    var instrumentsShowTraffic: Bool?

    // MARK: - Hints

    var hintsEnabled: Bool?
    var hintsShown: [String: Int]?

    // MARK: - Reading the device

    /// What this device currently holds, as one value.
    @MainActor
    static func capture() -> SyncedSettings {
        let friends = FriendsStore.shared
        let highlight = PilotHighlightPreferences.shared
        let appearance = FlightInfoAppearance.shared
        let filters = MapFilters.shared
        let weather = WeatherPreferences.shared
        let instruments = InstrumentPreferences.shared
        let hints = HintsStore.shared

        var settings = SyncedSettings()

        settings.watchlist = friends.friends
        settings.notifications = friends.preferences

        settings.highlightEnabled = highlight.isEnabled
        settings.ownColour = PilotHighlightPreferences.components(of: highlight.ownColor)
        settings.friendColour = PilotHighlightPreferences.components(of: highlight.friendColor)
        settings.friendColours = highlight.friendColors.reduce(into: [:]) { out, pair in
            out[pair.key] = PilotHighlightPreferences.components(of: pair.value)
        }

        settings.appearanceMode = appearance.mode.rawValue
        settings.appPalette = appearance.palette.rawValue
        settings.glass = appearance.isGlassEnabled
        settings.peakStyle = appearance.peakStyle.rawValue
        settings.windowStyle = appearance.windowStyle.rawValue
        settings.windowPlacement = appearance.flightWindowPlacement.rawValue
        settings.airlineAccent = appearance.showsAirlineAccent
        settings.smoothTraffic = appearance.smoothsTraffic

        settings.mapProjection = appearance.mapProjection.rawValue
        settings.mapPalette = appearance.mapPalette.rawValue
        settings.mapDetailed = appearance.isMapDetailed
        settings.mapTerrain = appearance.isMapTerrain
        settings.globeSkin = appearance.globeSkin.rawValue
        settings.globeBackdrop = appearance.globeBackdrop.rawValue
        settings.globePlanes = appearance.globeShowsPlanes

        settings.filterPhases = filters.phases.map(\.rawValue).sorted()
        settings.filterBands = filters.bands.sorted()
        settings.filterCategories = filters.categories.map(\.rawValue).sorted()
        settings.filedRouteOnly = filters.filedRouteOnly
        settings.showsAirports = filters.showsAirports
        settings.showsGroundLayout = filters.showsGroundLayout
        settings.routeLine = filters.routeLine.rawValue
        settings.showsPlanFixNames = filters.showsPlanFixNames
        // What was *asked* for, not what is drawn — an account that pays on one
        // device and not another should carry the choice to both.
        settings.showsAtcBoundaries = filters.wantsAtcBoundaries
        settings.showsFlownPath = filters.showsFlownPath
        settings.showsNatTracks = filters.showsNatTracks
        settings.showsTerminator = filters.showsTerminator

        settings.temperatureUnit = weather.temperatureUnit.rawValue
        settings.windUnit = weather.windUnit.rawValue
        settings.weatherChipVisible = weather.isChipVisible
        settings.weatherRouteEnds = weather.showsRouteEnds
        settings.weatherLayer = weather.mapLayer.rawValue
        settings.animatesRadar = weather.animatesRadar
        settings.showsWinds = weather.showsWinds
        settings.windLevel = weather.windLevel.rawValue
        settings.showsFieldConditions = weather.showsFieldConditions

        settings.instrumentsEnabled = instruments.isEnabled
        settings.instrumentDisplay = instruments.display.rawValue
        settings.navigationMode = instruments.navigationMode.rawValue
        settings.instrumentRangeNM = instruments.rangeNM
        settings.instrumentsShowTraffic = instruments.showsTraffic

        settings.hintsEnabled = hints.isEnabled
        settings.hintsShown = hints.shownCounts

        return settings
    }

    // MARK: - Writing the device

    /// Puts this snapshot onto the stores.
    ///
    /// Every field is `if let`: a key the account never wrote leaves the
    /// device's own value where it is. And every enum goes through its
    /// `rawValue` initialiser without a fallback, so a value this build has
    /// never heard of — a map palette from a newer app, a case that has since
    /// been removed — is skipped rather than resetting the setting to a
    /// default. One unreadable key costs one setting, never the restore.
    @MainActor
    func apply() {
        let friends = FriendsStore.shared
        let highlight = PilotHighlightPreferences.shared
        let appearance = FlightInfoAppearance.shared
        let filters = MapFilters.shared
        let weather = WeatherPreferences.shared
        let instruments = InstrumentPreferences.shared
        let hints = HintsStore.shared

        if let watchlist = watchlist { friends.adopt(watchlist) }
        if let notifications = notifications { friends.preferences = notifications }

        if let highlightEnabled = highlightEnabled { highlight.isEnabled = highlightEnabled }
        if let colour = PilotHighlightPreferences.color(from: ownColour) {
            highlight.ownColor = colour
        }
        if let colour = PilotHighlightPreferences.color(from: friendColour) {
            highlight.friendColor = colour
        }
        if let friendColours = friendColours {
            highlight.friendColors = friendColours.reduce(into: [:]) { out, pair in
                guard let colour = PilotHighlightPreferences.color(from: pair.value) else { return }
                out[pair.key] = colour
            }
        }

        if let value = appearanceMode.flatMap(AppAppearanceMode.init(rawValue:)) {
            appearance.mode = value
        }
        if let value = appPalette.flatMap(AppPalette.init(rawValue:)) {
            appearance.palette = value
        }
        if let glass = glass { appearance.isGlassEnabled = glass }
        if let value = peakStyle.flatMap(FlightInfoPeakStyle.init(rawValue:)) {
            appearance.peakStyle = value
        }
        if let value = windowStyle.flatMap(FlightInfoWindowStyle.init(rawValue:)) {
            appearance.windowStyle = value
        }
        if let value = windowPlacement.flatMap(FlightWindowPlacement.init(rawValue:)) {
            appearance.flightWindowPlacement = value
        }
        if let airlineAccent = airlineAccent { appearance.showsAirlineAccent = airlineAccent }
        if let smoothTraffic = smoothTraffic { appearance.smoothsTraffic = smoothTraffic }

        if let value = mapProjection.flatMap(MapProjection.init(rawValue:)) {
            appearance.mapProjection = value
        }
        // Through `from(stored:)` rather than the raw initialiser, for the same
        // reason the disk is: an account synced by a build that still had the
        // Dark palette is carrying `dark`, and it means Auto now.
        if let value = MapPalette.from(stored: mapPalette) {
            appearance.mapPalette = value
        }
        if let mapDetailed = mapDetailed { appearance.isMapDetailed = mapDetailed }
        if let mapTerrain = mapTerrain { appearance.isMapTerrain = mapTerrain }

        if let value = globeSkin.flatMap(GlobeSkin.init(rawValue:)) {
            appearance.globeSkin = value
        }
        if let value = globeBackdrop.flatMap(GlobeBackdrop.init(rawValue:)) {
            appearance.globeBackdrop = value
        }
        if let globePlanes = globePlanes { appearance.globeShowsPlanes = globePlanes }

        // The three sets that may never be emptied. `MapFilters.toggle` refuses
        // to turn the last one off, so a map that draws nothing is a state the
        // app has decided is not reachable — and a blob that would produce one,
        // whether through corruption or through a case this build no longer
        // has, must not be the way in. An empty result leaves the set alone.
        if let phases = filterPhases {
            let decoded = Set(phases.compactMap(FlightPhase.init(rawValue:)))
            if !decoded.isEmpty { filters.phases = decoded }
        }
        if let bands = filterBands, !bands.isEmpty {
            filters.bands = Set(bands)
        }
        if let categories = filterCategories {
            let decoded = Set(categories.compactMap(AircraftCategory.init(rawValue:)))
            if !decoded.isEmpty { filters.categories = decoded }
        }
        if let filedRouteOnly = filedRouteOnly { filters.filedRouteOnly = filedRouteOnly }
        if let showsAirports = showsAirports { filters.showsAirports = showsAirports }
        if let showsGroundLayout = showsGroundLayout { filters.showsGroundLayout = showsGroundLayout }
        if let value = routeLine.flatMap(RouteLineMode.init(rawValue:)) {
            filters.routeLine = value
        }
        if let showsPlanFixNames = showsPlanFixNames {
            filters.showsPlanFixNames = showsPlanFixNames
        }
        if let showsAtcBoundaries = showsAtcBoundaries {
            filters.wantsAtcBoundaries = showsAtcBoundaries
        }
        if let showsFlownPath = showsFlownPath { filters.showsFlownPath = showsFlownPath }
        if let showsNatTracks = showsNatTracks { filters.showsNatTracks = showsNatTracks }
        if let showsTerminator = showsTerminator { filters.showsTerminator = showsTerminator }

        if let value = temperatureUnit.flatMap(TemperatureUnit.init(rawValue:)) {
            weather.temperatureUnit = value
        }
        if let value = windUnit.flatMap(WindUnit.init(rawValue:)) {
            weather.windUnit = value
        }
        if let weatherChipVisible = weatherChipVisible { weather.isChipVisible = weatherChipVisible }
        if let weatherRouteEnds = weatherRouteEnds { weather.showsRouteEnds = weatherRouteEnds }
        if let value = weatherLayer.flatMap(MapWeatherLayer.init(rawValue:)) {
            weather.mapLayer = value
        }
        if let animatesRadar = animatesRadar { weather.animatesRadar = animatesRadar }
        if let showsWinds = showsWinds { weather.showsWinds = showsWinds }
        if let value = windLevel.flatMap(WindLevel.init(rawValue:)) {
            weather.windLevel = value
        }
        if let showsFieldConditions = showsFieldConditions {
            weather.showsFieldConditions = showsFieldConditions
        }

        if let instrumentsEnabled = instrumentsEnabled { instruments.isEnabled = instrumentsEnabled }
        if let value = instrumentDisplay.flatMap(InstrumentDisplay.init(rawValue:)) {
            instruments.display = value
        }
        if let value = navigationMode.flatMap(NavigationDisplayMode.init(rawValue:)) {
            instruments.navigationMode = value
        }
        if let instrumentRangeNM = instrumentRangeNM { instruments.rangeNM = instrumentRangeNM }
        if let instrumentsShowTraffic = instrumentsShowTraffic {
            instruments.showsTraffic = instrumentsShowTraffic
        }

        if let hintsEnabled = hintsEnabled { hints.isEnabled = hintsEnabled }
        if let hintsShown = hintsShown { hints.adopt(shown: hintsShown) }
    }

    // MARK: - The wire

    /// The blob as PostgREST wants it: a JSON object, ready to go into the
    /// `settings` column.
    func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SupabaseData.Failure(message: "Settings could not be prepared for the server.")
        }
        return object
    }
}
