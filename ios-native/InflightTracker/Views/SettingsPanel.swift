import SwiftUI
import UIKit

/// Settings, from the toolbar's settings button.
///
/// The app's own preferences: which server the feed is joined to, and how the
/// flight window looks. What the *map* is showing lives under filters, and how
/// weather reads lives under weather — this panel is everything else.
struct SettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var hints = HintsStore.shared
    @ObservedObject private var instruments = InstrumentPreferences.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    // Observed for the price alone: it arrives from the App Store a moment
    // after launch, and the row that quotes it has to redraw when it does.
    @ObservedObject private var store = ProStore.shared
    // Observed so the row underneath says what the link is actually doing
    // rather than only what it is for.
    @ObservedObject private var connect = ConnectSession.shared
    // Both for the notifications row: whether iOS will draw a banner at all,
    // and how much has been asked for behind it.
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var friends = FriendsStore.shared

    /// Both open over this panel rather than replacing it: they are somewhere
    /// you go and come back from, and losing the settings sheet to get to them
    /// would make coming back a matter of finding it again.
    @State private var isShowingAccount = false
    @State private var isShowingPaywall = false
    @State private var isShowingConnect = false
    @State private var isShowingNotifications = false
    @State private var isShowingAcknowledgements = false

    private var theme: FlightInfoTheme { appearance.theme }

    /// Whether this is a tablet, for the one setting that only exists on one.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        MapPanel(title: "Settings", subtitle: feedSummary) {
            // Each section is dealt in a beat after the one above it. See Motion:
            // the stagger is small enough to be felt rather than watched.
            PanelSection(title: "ACCOUNT") {
                PanelActionRow(
                    title: accounts.account?.handle ?? "Sign in",
                    symbol: accounts.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle",
                    detail: accountDetail
                ) {
                    isShowingAccount = true
                }

                PanelDivider()

                PanelActionRow(
                    title: entitlements.isPro ? "Inflight Pro" : "Get Inflight Pro",
                    symbol: entitlements.isPro ? "checkmark.seal.fill" : "sparkles",
                    detail: proDetail
                ) {
                    isShowingPaywall = true
                }
            }
            .panelEntrance(0)

            // High up, and above everything about how the map is drawn,
            // because it is the only section here about something that happens
            // when the app is closed. Everything below this is a preference
            // about a screen you are already looking at.
            PanelSection(title: "NOTIFICATIONS") {
                PanelActionRow(
                    title: "Notifications",
                    symbol: "bell.badge",
                    detail: notificationsDetail
                ) {
                    isShowingNotifications = true
                }
            }
            .panelEntrance(1)

            // Its own section rather than a row in Appearance: each of these
            // wants a sentence, and some of them are Pro, which a segmented
            // control has nowhere to say.
            //
            // Two lists rather than one, because they are two questions. The
            // shape of the world and what it is drawn in used to be a single
            // list of four styles, which is why the planet only ever came in
            // satellite imagery.
            PanelSection(title: "MAP SHAPE") {
                ForEach(MapProjection.allCases) { projection in
                    if projection != MapProjection.allCases.first { PanelDivider() }

                    mapChoiceRow(
                        title: projection.label,
                        symbol: projection.symbol,
                        detail: projection.detail,
                        isPro: projection.isPro,
                        isSelected: appearance.mapProjection == projection
                    ) {
                        appearance.mapProjection = projection
                    }
                }
            }
            .panelEntrance(2)

            PanelSection(title: "MAP STYLE") {
                ForEach(MapPalette.allCases) { palette in
                    if palette != MapPalette.allCases.first { PanelDivider() }

                    mapChoiceRow(
                        title: palette.label,
                        symbol: palette.symbol,
                        detail: palette.detail,
                        isPro: palette.isPro,
                        isSelected: appearance.mapPalette == palette
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
            .panelEntrance(3)

            PanelSection(title: "FEED") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
                }
            }
            .panelEntrance(4)

            // Its own section because it is a different kind of thing from the
            // feed: the feed is everybody's flights from the cloud, this is
            // your own aircraft from the sim on the next device along.
            PanelSection(title: "THE SIM") {
                PanelActionRow(
                    title: "Infinite Flight Connect",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: connectDetail
                ) {
                    isShowingConnect = true
                }
            }
            .panelEntrance(5)

            // Its own section, above appearance, because it is a feature
            // rather than a finish: this decides whether a whole panel is in
            // the flight window, not what colour it is.
            PanelSection(title: "INSTRUMENTS") {
                PanelToggleRow(
                    title: "Flight instruments",
                    symbol: "gauge.open.with.lines.needle.33percent",
                    detail: "Puts a primary flight display and a navigation display in every flight window — attitude, speed and height on one, the filed route and the traffic around it on the other.",
                    isOn: $instruments.isEnabled
                )

                if instruments.isEnabled {
                    // Fades rather than sliding: these rows are inside a card
                    // that is itself changing height, and two movements in the
                    // same place at the same time read as one thing wobbling.
                    PanelDivider()

                    PanelPickerRow(
                        title: "Opens on",
                        symbol: "rectangle.on.rectangle",
                        options: InstrumentDisplay.allCases,
                        label: { $0.label },
                        detail: instrumentsDetail,
                        selection: $instruments.display
                    )

                    PanelDivider()

                    PanelPickerRow(
                        title: "Navigation display",
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
            }
            // The section grows and shrinks as the switch above is flipped, so
            // the rows below it move rather than jump.
            .motion(Motion.row, value: instruments.isEnabled)
            .panelEntrance(6)

            PanelSection(title: "APPEARANCE") {
                // Light is a whole-app setting rather than a flight-window one,
                // so it leads the section the window's own switches sit in.
                PanelPickerRow(
                    title: "Theme",
                    symbol: "circle.lefthalf.filled",
                    options: AppAppearanceMode.allCases,
                    label: { $0.label },
                    detail: appearance.mode.detail,
                    selection: $appearance.mode
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Glass flight info",
                    symbol: "square.on.square.dashed",
                    detail: "Frosts the window and its chrome. Off, everything draws flat.",
                    isOn: $appearance.isGlassEnabled
                )

                PanelDivider()

                // The peak measures itself, so switching this resizes the sheet
                // even while it is on screen.
                PanelPickerRow(
                    title: "Peek",
                    symbol: "rectangle.portrait.bottomhalf.filled",
                    options: FlightInfoPeakStyle.allCases,
                    label: { $0.label },
                    detail: appearance.peakStyle.detail,
                    selection: $appearance.peakStyle
                )

                // Only where it means anything. A phone has one place to put
                // the flight window and no choice to offer about it, and a row
                // whose two options look identical is worse than no row.
                //
                // The idiom rather than the size class, which is the one place
                // in the app that is the right way round: this panel is itself
                // in a sheet, and a sheet on an iPad can be handed a compact
                // width — so asking how wide *this* is would hide the setting
                // on exactly the device it is for.
                if isPad {
                    PanelDivider()

                    PanelPickerRow(
                        title: "Window",
                        symbol: "sidebar.right",
                        options: FlightWindowPlacement.allCases,
                        label: { $0.label },
                        detail: appearance.flightWindowPlacement.detail,
                        selection: $appearance.flightWindowPlacement
                    )
                }
            }
            .panelEntrance(7)

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
            .panelEntrance(8)

            PanelSection(title: "ABOUT") {
                aboutRow("Version", value: version)
                PanelDivider()
                // Surfaces a packaging problem that otherwise just looks like an
                // empty map, which is hard to diagnose from a TestFlight build.
                aboutRow("Aircraft icons", value: PlaneSprites.shared.isReady ? "Vector" : "Missing")
                PanelDivider()
                aboutRow("Traffic", value: "\(feed.flights.count) aircraft")
                PanelDivider()
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
            .panelEntrance(9)
        }
        .sheet(isPresented: $isShowingAccount) { AccountPanel() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
        .sheet(isPresented: $isShowingConnect) { ConnectPanel() }
        .sheet(isPresented: $isShowingNotifications) {
            // Handed the feed explicitly, like every other sheet that needs it:
            // the panel draws the aeroplane it is about, which is one of the
            // ones on the map.
            NotificationsPanel().environmentObject(feed)
        }
        .sheet(isPresented: $isShowingAcknowledgements) { AcknowledgementsPanel() }
    }

    /// What the notifications row says without being opened.
    ///
    /// The state worth surfacing here is the one that makes every switch inside
    /// meaningless — iOS not being allowed to draw a banner at all. Saying "5 of
    /// 9 on" to somebody in that position would be true and useless.
    private var notificationsDetail: String {
        guard push.canNotify else {
            return "Not allowed yet — nothing about your flight or the pilots you watch can reach you."
        }
        let preferences = friends.preferences
        if preferences.enabledCount == 0 { return "Everything is switched off." }
        return "Your own flight, and the pilots you watch. \(preferences.enabledCount) of \(FriendsStore.NotificationPreferences.totalCount) switched on."
    }

    /// One line under the Connect row saying where the link stands, so the
    /// panel is worth opening only when there is something to do in it.
    private var connectDetail: String {
        switch connect.status {
        case .off:
            return connect.isEnabled
                ? "Waiting for Infinite Flight."
                : "Read your landing rate and your own aircraft straight from the sim."
        case .searching:            return "Looking for Infinite Flight on this network…"
        case .connecting:           return "Connecting…"
        case .syncing:              return "Reading what this aircraft publishes…"
        case let .live(host):       return "Connected to \(host)."
        case let .waiting(reason):  return "Waiting — \(reason)"
        }
    }

    /// What the chosen display actually shows, and — for the PFD — the one
    /// thing about it worth knowing before it is read.
    private var instrumentsDetail: String {
        switch instruments.display {
        case .pfd:
            return "Attitude, speed, height and heading. Pitch and bank are read from the simulator when the pilot is broadcasting through Connect, and worked out from the flight path and the rate of turn when they are not — the display says which."
        case .navigation:
            return "The filed route, both ends of it, and the traffic around the aircraft, heading up."
        }
    }

    private var feedSummary: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.flights.count) aircraft · \(feed.server)"
    }

    private var accountDetail: String {
        guard let account = accounts.account else {
            return "Carries your Pro between devices. The app works without one."
        }
        return account.email
    }

    private var proDetail: String {
        if entitlements.isPro {
            switch entitlements.source {
            case .appStore: return "Active — through the App Store."
            case .subscription: return "Active — from your inflight.info subscription."
            case .legacy: return "Active on your account."
            case .free: return "Active."
            }
        }

        guard let price = store.displayPrice else {
            return "Flight replay, the whole watchlist, and the globe."
        }
        return "From \(price) a year. Flight replay, the whole watchlist, and the globe."
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
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

    /// One choice about how the map is drawn — its shape, or its palette.
    ///
    /// Locked choices are shown, not hidden — you cannot want something you
    /// have never seen — and tapping one opens the paywall rather than silently
    /// doing nothing. The choice is still stored either way, so buying Pro from
    /// there leaves you on the thing you picked.
    private func mapChoiceRow(
        title: String,
        symbol: String,
        detail: String,
        isPro: Bool,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        let locked = isPro && !entitlements.isPro

        return Button {
            select()
            if locked { isShowingPaywall = true }
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

    private func aboutRow(_ title: String, value: String) -> some View {
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
}
