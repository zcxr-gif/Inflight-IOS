import SwiftUI

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

    /// Both open over this panel rather than replacing it: they are somewhere
    /// you go and come back from, and losing the settings sheet to get to them
    /// would make coming back a matter of finding it again.
    @State private var isShowingAccount = false
    @State private var isShowingPaywall = false
    @State private var isShowingConnect = false
    @State private var isShowingAcknowledgements = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Settings", subtitle: feedSummary) {
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

            // Its own section rather than a row in Appearance: four styles
            // with a sentence each is a list, and two of them are Pro, which a
            // segmented control has nowhere to say.
            PanelSection(title: "MAP") {
                ForEach(MapStyleMode.allCases) { style in
                    if style != MapStyleMode.allCases.first { PanelDivider() }
                    mapStyleRow(style)
                }
            }

            PanelSection(title: "FEED") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
                }
            }

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
            }

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
        }
        .sheet(isPresented: $isShowingAccount) { AccountPanel() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
        .sheet(isPresented: $isShowingConnect) { ConnectPanel() }
        .sheet(isPresented: $isShowingAcknowledgements) { AcknowledgementsPanel() }
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

    /// One map style. Locked styles are shown, not hidden — you cannot want
    /// something you have never seen — and tapping one opens the paywall
    /// rather than silently doing nothing.
    private func mapStyleRow(_ style: MapStyleMode) -> some View {
        let locked = style.isPro && !entitlements.isPro
        let selected = appearance.mapStyle == style

        return Button {
            appearance.mapStyle = style
            if locked { isShowingPaywall = true }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: style.label, symbol: style.symbol)

                    Text(style.detail)
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
                } else if selected {
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
