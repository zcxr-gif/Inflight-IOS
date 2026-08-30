import SwiftUI

/// The screens the settings panel is now a table of contents for.
///
/// ## Why they exist
///
/// Settings was one list. Twelve sections of it, in a single scroll: your
/// account, then notifications, then the shape of the world, then the map's
/// palette, then which server the feed is joined to, then the simulator link,
/// then the instruments, then the whole of appearance, then hints, then two
/// paragraphs about virtual airlines, then the build number, then the legal
/// documents. Everything was equally prominent, which is the same as nothing
/// being prominent: the switch you came in for was somewhere in a column of
/// forty rows, and finding it a second time meant reading past everything
/// again.
///
/// So the panel is a short list of destinations, and each destination is the
/// group of settings that actually belong together. The hub says what each one
/// is currently set to, so the common case — checking rather than changing —
/// is answered without opening anything.
///
/// Each of these is presented as its own sheet over the panel rather than
/// replacing it, the same way the account and the paywall always have been:
/// somewhere you go and come back from, with the way back a pull on the handle
/// rather than a hunt for the settings button.

// MARK: - The map

/// The shape of the world, and what it is drawn in.
struct MapStyleSettingsPanel: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var isShowingPaywall = false

    var body: some View {
        MapPanel(title: "Map", subtitle: "How the world underneath the traffic is drawn") {
            // Two lists rather than one, because they are two questions. The
            // shape of the world and what it is drawn in used to be a single
            // list of four styles, which is why the planet only ever came in
            // satellite imagery.
            PanelSection(title: "SHAPE") {
                ForEach(MapProjection.allCases) { projection in
                    if projection != MapProjection.allCases.first { PanelDivider() }

                    SettingsChoiceRow(
                        title: projection.label,
                        symbol: projection.symbol,
                        detail: projection.detail,
                        isPro: projection.isPro,
                        isSelected: appearance.mapProjection == projection,
                        onLocked: { isShowingPaywall = true }
                    ) {
                        appearance.mapProjection = projection
                    }
                }
            }
            .panelEntrance(0)

            PanelSection(title: "STYLE") {
                ForEach(MapPalette.allCases) { palette in
                    if palette != MapPalette.allCases.first { PanelDivider() }

                    SettingsChoiceRow(
                        title: palette.label,
                        symbol: palette.symbol,
                        detail: palette.detail,
                        isPro: palette.isPro,
                        isSelected: appearance.mapPalette == palette,
                        onLocked: { isShowingPaywall = true }
                    ) {
                        appearance.mapPalette = palette
                    }
                }

                PanelDivider()

                PanelToggleRow(
                    title: "Full detail",
                    symbol: "map.fill",
                    detail: "Roads, terrain shading and place names at full strength, rather than the muted cartography the map recedes into behind the traffic. Imagery has none of it to turn up.",
                    isOn: $appearance.isMapDetailed
                )
                .disabled(appearance.mapPalette.usesImagery)
                .opacity(appearance.mapPalette.usesImagery ? 0.45 : 1)
            }
            .panelEntrance(1)
        }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
    }
}

// MARK: - Instruments

/// Whether the flight window carries a flight deck, and which one it opens on.
struct InstrumentsSettingsPanel: View {

    @ObservedObject private var instruments = InstrumentPreferences.shared

    var body: some View {
        MapPanel(title: "Instruments", subtitle: "A flight deck inside the flight window") {
            PanelSection(title: "INSTRUMENTS") {
                PanelToggleRow(
                    title: "Flight instruments",
                    symbol: "gauge.open.with.lines.needle.33percent",
                    detail: "Puts a primary flight display and a navigation display in every flight window — attitude, speed and height on one, the filed route and the traffic around it on the other.",
                    isOn: $instruments.isEnabled
                )
            }
            .panelEntrance(0)

            // The rest of the screen is about a thing that may be switched off,
            // so it is not drawn at all until it is on — rather than sitting
            // there greyed, which is a screen of controls that do nothing.
            if instruments.isEnabled {
                PanelSection(title: "WHAT IT OPENS ON") {
                    PanelPickerRow(
                        title: "Opens on",
                        symbol: "rectangle.on.rectangle",
                        options: InstrumentDisplay.allCases,
                        label: { $0.label },
                        detail: displayDetail,
                        selection: $instruments.display
                    )
                }
                .panelEntrance(1)

                PanelSection(title: "NAVIGATION DISPLAY") {
                    PanelPickerRow(
                        title: "Layout",
                        symbol: "location.north.line",
                        options: NavigationDisplayMode.allCases,
                        label: { $0.label },
                        detail: instruments.navigationMode == .arc
                            ? "The fan in front of the aircraft, which is what you would fly with."
                            : "The full compass, which shows what is behind you as well.",
                        selection: $instruments.navigationMode
                    )

                    PanelDivider()

                    PanelToggleRow(
                        title: "Traffic on the ND",
                        symbol: "airplane.circle",
                        detail: "Draws the nearest aircraft from the feed, with how far above or below they are in hundreds of feet. Anything within two thousand feet is picked out.",
                        isOn: $instruments.showsTraffic
                    )
                }
                .panelEntrance(2)
            }
        }
        // The panel grows and shrinks as the switch at the top is thrown, so
        // the sections below it move rather than appear.
        .motion(Motion.row, value: instruments.isEnabled)
    }

    /// What the chosen display actually shows, and — for the PFD — the one
    /// thing about it worth knowing before it is read.
    private var displayDetail: String {
        switch instruments.display {
        case .pfd:
            return "Attitude, speed, height and heading. Pitch and bank are read from the simulator when the pilot is broadcasting through Connect, and worked out from the flight path and the rate of turn when they are not — the display says which."
        case .navigation:
            return "The filed route, both ends of it, and the traffic around the aircraft, heading up."
        }
    }
}

// MARK: - Appearance

/// How the app itself is drawn, and whether it explains itself as you go.
struct AppearanceSettingsPanel: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var hints = HintsStore.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Appearance", subtitle: "How the app is drawn") {
            PanelSection(title: "THEME") {
                // Light is a whole-app setting rather than a flight-window one,
                // so it leads.
                PanelPickerRow(
                    title: "Theme",
                    symbol: "circle.lefthalf.filled",
                    options: AppAppearanceMode.allCases,
                    label: { $0.label },
                    detail: appearance.mode.detail,
                    selection: $appearance.mode
                )

                PanelDivider()

                // Under the light switch, because it is the same kind of
                // question one step in: that one says which end of the scale
                // the app sits at, and this says what the scale is made of.
                PanelPickerRow(
                    title: "Colours",
                    symbol: "paintpalette",
                    options: AppPalette.allCases,
                    label: { $0.label },
                    detail: appearance.palette.detail,
                    selection: $appearance.palette
                )
            }
            .panelEntrance(0)

            PanelSection(title: "MATERIAL") {
                PanelToggleRow(
                    title: "Glass flight info",
                    symbol: "square.on.square.dashed",
                    detail: "Frosts the window and its chrome. Off, everything draws flat.",
                    isOn: $appearance.isGlassEnabled
                )
            }
            .panelEntrance(1)

            PanelSection(title: "MOVEMENT") {
                PanelToggleRow(
                    title: "Fly the traffic",
                    symbol: "airplane.departure",
                    detail: "Airborne aircraft keep flying between the server's updates, at the heading and speed they last reported, instead of jumping each time one lands. Off, every aeroplane sits exactly where it was last reported. Aircraft on the ground never move on their own either way.",
                    isOn: $appearance.smoothsTraffic
                )
            }
            .panelEntrance(2)

            PanelSection(title: "HINTS") {
                PanelToggleRow(
                    title: "Show hints",
                    symbol: "lightbulb",
                    detail: "A line of guidance at the foot of a screen, about that screen. Each one retires after you have seen it a few times.",
                    isOn: $hints.isEnabled
                )

                // Only offered once there is something to bring back, so the
                // section is a switch and nothing else until it has earned the
                // second row.
                if hints.retiredCount > 0 {
                    PanelDivider()

                    Button {
                        hints.restoreAll()
                    } label: {
                        HStack(spacing: 10) {
                            PanelRowLabel(title: "Show them all again", symbol: "arrow.counterclockwise")

                            Spacer(minLength: 8)

                            Text("\(hints.retiredCount) read")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.textDim)
                                .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!hints.isEnabled)
                    .opacity(hints.isEnabled ? 1 : 0.45)
                }
            }
            .motion(Motion.row, value: hints.retiredCount > 0)
            .motion(Motion.control, value: hints.isEnabled)
            .panelEntrance(3)
        }
    }
}

// MARK: - Where the aircraft come from

/// The two sources of traffic: everybody's flights from the cloud, and your
/// own aircraft from the simulator on the next device along.
struct FeedSettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var connect = ConnectSession.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var isShowingConnect = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Feed", subtitle: summary) {
            PanelSection(title: "SERVER") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
                }
            }
            .panelEntrance(0)

            // Its own section because it is a different kind of thing from the
            // feed: the feed is everybody's flights from the cloud, this is
            // your own aircraft from the sim on the next device along.
            PanelSection(title: "THE SIM") {
                PanelActionRow(
                    title: "Infinite Flight Connect",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: SettingsSummary.connect(connect)
                ) {
                    isShowingConnect = true
                }
            }
            .panelEntrance(1)
        }
        .sheet(isPresented: $isShowingConnect) { ConnectPanel() }
    }

    private var summary: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.flights.count) aircraft · \(feed.server)"
    }

    private func serverRow(_ server: String) -> some View {
        Button {
            feed.select(server: server)
        } label: {
            HStack(spacing: 10) {
                PanelRowLabel(
                    title: server.replacingOccurrences(of: " Server", with: ""),
                    symbol: "dot.radiowaves.left.and.right"
                )

                Spacer(minLength: 8)

                if feed.server == server {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About

/// What this build is, whose work is in it, and the documents.
struct AboutSettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var isShowingAcknowledgements = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "About", subtitle: "Inflight \(SettingsSummary.version)") {
            PanelSection(title: "THIS BUILD") {
                row("Version", value: SettingsSummary.version)
                PanelDivider()
                // Surfaces a packaging problem that otherwise just looks like
                // an empty map, which is hard to diagnose from a TestFlight
                // build.
                row("Aircraft icons", value: PlaneSprites.shared.isReady ? "Vector" : "Missing")
                PanelDivider()
                row("Traffic", value: "\(feed.flights.count) aircraft")
            }
            .panelEntrance(0)

            PanelSection(title: "CREDITS") {
                // The marks on the map are other people's work, under licences
                // that ask to be carried with the app.
                PanelActionRow(
                    title: "Acknowledgements",
                    symbol: "doc.text",
                    detail: "Where the aircraft marks come from"
                ) {
                    isShowingAcknowledgements = true
                }
            }
            .panelEntrance(1)

            // What a partner VA actually is, said once, in the place somebody
            // goes to find out.
            //
            // The window and the airport panel name virtual airlines beside
            // real aircraft, and a good number of those VAs have chosen names
            // that read like the airline they fly the livery of. Whoever wrote
            // the name meant "we fly this airline's routes in the simulator";
            // somebody who has just opened the app has no reason to read it
            // that way. So it is spelled out rather than left to be inferred,
            // and the disclaimer is the app's rather than the VA's — nothing
            // shown here is endorsed by anyone.
            PanelSection(title: "PARTNER VIRTUAL AIRLINES") {
                note(
                    """
                    A virtual airline is a group of Infinite Flight pilots who \
                    fly together inside the simulator. Everything shown against \
                    one — its name, its callsign, its hubs, its write-up — is \
                    what that group published about itself to the VA-Ads \
                    directory.
                    """
                )

                PanelDivider()

                note(
                    """
                    They are not airlines. Inflight is not affiliated with, \
                    endorsed by, sponsored by or connected to any real-world \
                    airline, and neither is any virtual airline listed in this \
                    app, whichever real one its name or its livery resembles. \
                    Airline names and marks belong to their owners.
                    """
                )
            }
            .panelEntrance(2)

            PanelSection(title: "LEGAL") {
                legalLink("Terms of Service", symbol: "doc.plaintext", url: AppConfig.termsURL)
                PanelDivider()
                legalLink("Privacy Policy", symbol: "hand.raised", url: AppConfig.privacyURL)
            }
            .panelEntrance(3)
        }
        .sheet(isPresented: $isShowingAcknowledgements) { AcknowledgementsPanel() }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A paragraph in a section, for the places where the answer is a sentence
    /// rather than a control.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    /// A row that leaves the app for a document.
    ///
    /// A `Link` rather than a sheet with a web view in it: these are documents
    /// somebody may want to keep, print or read with the text size they use
    /// everywhere else, and Safari does all three better than anything this
    /// panel could put them in.
    private func legalLink(_ title: String, symbol: String, url: URL?) -> some View {
        Link(destination: url ?? AppConfig.siteURL) {
            HStack(spacing: 10) {
                PanelRowLabel(title: title, symbol: symbol)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(title). Opens outside the app.")
    }
}

// MARK: - Shared pieces

/// One choice about how something is drawn — the map's shape, its palette.
///
/// Lifted out of the settings panel when the map's own settings moved to a
/// screen of their own, because it is the only row in the app that has to say
/// "this is a choice, and it is one you have not bought". Locked choices are
/// shown, not hidden — you cannot want something you have never seen — and
/// tapping one opens the paywall rather than silently doing nothing. The choice
/// is still stored either way, so buying Pro from there leaves you on the thing
/// you picked.
struct SettingsChoiceRow: View {

    let title: String
    let symbol: String
    let detail: String
    let isPro: Bool
    let isSelected: Bool
    let onLocked: () -> Void
    let select: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var entitlements = Entitlements.shared

    private var theme: FlightInfoTheme { appearance.theme }
    private var locked: Bool { isPro && !entitlements.isPro }

    var body: some View {
        Button {
            select()
            if locked { onLocked() }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: title, symbol: symbol)

                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if locked {
                    Text("PRO")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(theme.accent) }
                        .fixedSize()
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Dimmed rather than disabled: it is still tappable, because the tap is
        // how you find out what it costs.
        .opacity(locked ? 0.6 : 1)
    }
}

/// The one-line answers the settings hub puts under each of its destinations.
///
/// Written here rather than in the hub because two of them are also the
/// subtitle of the screen they lead to, and a summary that disagreed with the
/// screen it summarises is worse than no summary at all.
enum SettingsSummary {

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// Where the simulator link stands, so the row is worth opening only when
    /// there is something to do behind it.
    ///
    /// Isolated because what it reads is: `ConnectSession` is `@MainActor`, so
    /// its state can only be looked at from the main actor. Every caller is a
    /// view body, which is already there.
    @MainActor
    static func connect(_ session: ConnectSession) -> String {
        switch session.status {
        case .off:
            return session.isEnabled
                ? "Waiting for Infinite Flight."
                : "Read your landing rate and your own aircraft straight from the sim."
        case .searching:            return "Looking for Infinite Flight on this network…"
        case .connecting:           return "Connecting…"
        case .syncing:              return "Reading what this aircraft publishes…"
        case let .live(host):       return "Connected to \(host)."
        case let .waiting(reason):  return "Waiting — \(reason)"
        }
    }
}
