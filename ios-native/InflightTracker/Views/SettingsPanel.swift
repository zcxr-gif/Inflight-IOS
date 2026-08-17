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
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    // Observed for the price alone: it arrives from the App Store a moment
    // after launch, and the row that quotes it has to redraw when it does.
    @ObservedObject private var store = ProStore.shared

    /// Both open over this panel rather than replacing it: they are somewhere
    /// you go and come back from, and losing the settings sheet to get to them
    /// would make coming back a matter of finding it again.
    @State private var isShowingAccount = false
    @State private var isShowingPaywall = false

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

            PanelSection(title: "FEED") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
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
                aboutRow("Aircraft sprites", value: PlaneSprites.shared.isReady ? "Loaded" : "Missing")
                PanelDivider()
                aboutRow("Traffic", value: "\(feed.flights.count) aircraft")
            }
        }
        .sheet(isPresented: $isShowingAccount) { AccountPanel() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
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
        guard !entitlements.isPro else {
            switch entitlements.source {
            case .appStore: return "Active — bought on the App Store."
            case .subscription: return "Active — from your inflight.info subscription."
            case .legacy: return "Active on your account."
            case .none: return "Active."
            }
        }
        guard let price = store.displayPrice else {
            return "Flight replay and the whole watchlist, bought once."
        }
        return "\(price) once. Flight replay and the whole watchlist."
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
