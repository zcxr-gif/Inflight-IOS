import SwiftUI
import UIKit

/// Settings, from the toolbar's settings button.
///
/// The app's own preferences: your account, what reaches you when the app is
/// closed, where the traffic comes from, and how all of it is drawn. What the
/// *map* is filtering lives under filters, and how weather reads lives under
/// weather — this panel is everything else.
///
/// ## Why this is a list of doors
///
/// It used to be the settings themselves: twelve sections in one scroll,
/// everything at the same level, so the switch you came in for was somewhere in
/// a column of forty rows and finding it again meant reading past all of them.
/// A settings screen that is one long list is a settings screen you search
/// rather than navigate.
///
/// So the panel is short now, and every row is a place. Each carries a line
/// saying what it is currently set to — which is the whole point of grouping
/// them: the common visit is a check rather than a change, and a hub that
/// answers "what is my map set to" without being opened has already done the
/// job. The screens themselves are in `SettingsSubpanels`.
struct SettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var hints = HintsStore.shared
    @ObservedObject private var instruments = InstrumentPreferences.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var entitlements = Entitlements.shared
    // Observed so the row underneath says what the link is actually doing
    // rather than only what it is for.
    @ObservedObject private var connect = ConnectSession.shared
    // Both for the notifications row: whether iOS will draw a banner at all,
    // and how much has been asked for behind it.
    @ObservedObject private var push = PushService.shared
    @ObservedObject private var friends = FriendsStore.shared
    // Observed so the row below says what is on the home screen right now
    // rather than what was there when this panel opened.
    @ObservedObject private var widgets = WidgetBridge.shared
    // Observed so the flight-plans row says what is actually next rather than
    // only what the screen is for.
    @ObservedObject private var plans = FlightPlanBook.shared

    /// Every one of these opens over this panel rather than replacing it: they
    /// are somewhere you go and come back from, and losing the settings sheet
    /// to get to one would make coming back a matter of finding it again.
    @State private var isShowingAccount = false
    @State private var isShowingPlans = false
    @State private var isShowingPaywall = false
    @State private var isShowingConnect = false
    @State private var isShowingNotifications = false
    @State private var isShowingFlightWindow = false
    @State private var isShowingMap = false
    @State private var isShowingInstruments = false
    @State private var isShowingAppearance = false
    @State private var isShowingFeed = false
    @State private var isShowingAbout = false
    @State private var isShowingWidgets = false

    var body: some View {
        MapPanel(title: "Settings", subtitle: feedSummary) {
            // Each section is dealt in a beat after the one above it. See
            // Motion: the stagger is small enough to be felt rather than
            // watched.
            //
            // First, above the account and above everything else — and only
            // for somebody who has not bought it. See `ProPromoCard`: an
            // account that is already Pro is not shown this at all, because the
            // one thing worse than not mentioning a subscription is mentioning
            // it to the person already paying for it.
            if !entitlements.isPro {
                ProPromoCard { isShowingPaywall = true }
                    .panelEntrance(0)
            }

            PanelSection(title: "ACCOUNT") {
                PanelActionRow(
                    title: accounts.account?.handle ?? "Sign in",
                    symbol: accounts.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle",
                    detail: accountDetail
                ) {
                    isShowingAccount = true
                }

                // The status of a subscription somebody holds, which is a fact
                // about their account and belongs here. The *offer* is the card
                // above, and the two are never on screen together: this row is
                // built only when the card is not.
                if entitlements.isPro {
                    PanelDivider()

                    PanelActionRow(
                        title: "Inflight Pro",
                        symbol: "checkmark.seal.fill",
                        detail: proDetail
                    ) {
                        isShowingPaywall = true
                    }
                }
            }
            .panelEntrance(1)

            // Under the account, because that is what a plan belongs to: it is
            // not a preference about this phone, it is something you wrote down
            // that has to be there on the next one.
            PanelSection(title: "FLYING") {
                PanelActionRow(
                    title: "Flight plans",
                    symbol: "calendar",
                    detail: plansDetail
                ) {
                    isShowingPlans = true
                }
            }
            .panelEntrance(2)

            // High up, and above everything about how the app is drawn, because
            // it is the only section here about something that happens when the
            // app is closed. Everything below this is a preference about a
            // screen you are already looking at.
            PanelSection(title: "NOTIFICATIONS") {
                PanelActionRow(
                    title: "Notifications",
                    symbol: "bell.badge",
                    detail: notificationsDetail
                ) {
                    isShowingNotifications = true
                }
            }
            .panelEntrance(3)

            // The three screens about what you are looking at, in the order you
            // meet them: the map underneath everything, the window that opens
            // on top of it, and the instruments inside that window.
            PanelSection(title: "WHAT YOU SEE") {
                PanelActionRow(
                    title: "Map",
                    symbol: appearance.mapProjection.symbol,
                    detail: mapDetail
                ) {
                    isShowingMap = true
                }

                PanelDivider()

                PanelActionRow(
                    title: "Flight window",
                    symbol: "airplane.circle",
                    detail: windowDetail
                ) {
                    isShowingFlightWindow = true
                }

                PanelDivider()

                PanelActionRow(
                    title: "Instruments",
                    symbol: "gauge.open.with.lines.needle.33percent",
                    detail: instrumentsDetail
                ) {
                    isShowingInstruments = true
                }

                PanelDivider()

                PanelActionRow(
                    title: "Appearance",
                    symbol: "circle.lefthalf.filled",
                    detail: appearanceDetail
                ) {
                    isShowingAppearance = true
                }

                PanelDivider()

                // The home screen is a screen you are looking at too, even
                // when the app is closed — and until now the only way to
                // change what was on it was to find the aeroplane it was
                // showing and open it, which is impossible once that flight
                // has landed.
                PanelActionRow(
                    title: "Widgets",
                    symbol: "square.grid.2x2",
                    detail: widgetsDetail
                ) {
                    isShowingWidgets = true
                }
            }
            .panelEntrance(4)

            // Where the aeroplanes come from — the cloud, and the simulator on
            // the next device along. Two rows rather than one screen with both
            // on it, because the sim link is the one people go looking for.
            PanelSection(title: "WHERE THE TRAFFIC COMES FROM") {
                PanelActionRow(
                    title: "Feed",
                    symbol: "dot.radiowaves.left.and.right",
                    detail: feedDetail
                ) {
                    isShowingFeed = true
                }

                PanelDivider()

                PanelActionRow(
                    title: "Infinite Flight Connect",
                    symbol: "antenna.radiowaves.left.and.right",
                    detail: SettingsSummary.connect(connect)
                ) {
                    isShowingConnect = true
                }
            }
            .panelEntrance(5)

            PanelSection(title: "ABOUT") {
                PanelActionRow(
                    title: "About Inflight",
                    symbol: "info.circle",
                    detail: aboutDetail
                ) {
                    isShowingAbout = true
                }
            }
            .panelEntrance(6)
        }
        // Read once so the row above can say what is actually next rather than
        // only what the screen is for. Cheap, capped at 200 small rows, and a
        // no-op on every visit after the first — see `loadIfNeeded`.
        .task { await plans.loadIfNeeded() }
        .sheet(isPresented: $isShowingAccount) { AccountPanel() }
        .sheet(isPresented: $isShowingPlans) { FlightPlansPanel() }
        .sheet(isPresented: $isShowingPaywall) { ProPanel() }
        .sheet(isPresented: $isShowingConnect) { ConnectPanel() }
        .sheet(isPresented: $isShowingNotifications) {
            // Handed the feed explicitly, like every other sheet that needs it:
            // the panel draws the aeroplane it is about, which is one of the
            // ones on the map.
            NotificationsPanel().environmentObject(feed)
        }
        .sheet(isPresented: $isShowingFlightWindow) { FlightWindowPanel() }
        .sheet(isPresented: $isShowingMap) { MapStyleSettingsPanel() }
        .sheet(isPresented: $isShowingInstruments) { InstrumentsSettingsPanel() }
        .sheet(isPresented: $isShowingAppearance) { AppearanceSettingsPanel() }
        .sheet(isPresented: $isShowingFeed) { FeedSettingsPanel().environmentObject(feed) }
        .sheet(isPresented: $isShowingAbout) { AboutSettingsPanel().environmentObject(feed) }
        // Handed the feed because the panel offers what is flying right now,
        // which is a question only the packet can answer.
        .sheet(isPresented: $isShowingWidgets) { WidgetsPanel().environmentObject(feed) }
    }

    // MARK: - What each door says without being opened

    /// The map's row: the shape of the world and what it is drawn in, which is
    /// the whole of what is behind it.
    private var mapDetail: String {
        let shape = appearance.mapProjection.label.lowercased()
        let style = appearance.mapPalette.label.lowercased()
        let detail = appearance.isMapDetailed && !appearance.mapPalette.usesImagery
            ? ", full detail"
            : ""
        return "\(shape), \(style)\(detail)"
    }

    /// The flight window's row, saying what it is currently set to rather than
    /// what it is for — the row is the only place the choices behind it are
    /// visible without opening anything.
    private var windowDetail: String {
        let peek = appearance.peakStyle.label.lowercased()
        let open = appearance.windowStyle.label.lowercased()
        let colour = appearance.showsAirlineAccent ? "airline colours" : "no airline colours"
        return "\(peek) peek, \(open) layout, \(colour)"
    }

    /// Off is the honest answer and the common one, so it is the whole line
    /// rather than a qualifier on a sentence about displays nobody has.
    private var instrumentsDetail: String {
        guard instruments.isEnabled else {
            return "Off — no flight deck in the flight window."
        }
        return "On — opens on the \(instruments.display.longLabel.lowercased())."
    }

    private var appearanceDetail: String {
        let mode = appearance.mode.label.lowercased()
        let palette = appearance.palette.label.lowercased()
        let hint = hints.isEnabled ? "hints on" : "hints off"
        return "\(mode), \(palette), \(hint)"
    }

    private var feedDetail: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.server) · \(feed.flights.count) aircraft"
    }

    /// What the home screen is currently pointed at, without opening the
    /// screen that says so at length.
    private var widgetsDetail: String {
        var parts: [String] = []

        if let id = widgets.pinnedFlightId {
            let pinned = feed.flights.first { $0.id == id }
            parts.append(pinned.map { "showing \($0.displayName)" } ?? "pinned flight has ended")
        }
        if let icao = widgets.pinnedAirportIcao {
            parts.append(icao)
        }

        guard !parts.isEmpty else {
            return "Nothing pinned — the tile follows whoever is flying."
        }
        return parts.joined(separator: " · ")
    }

    private var aboutDetail: String {
        "Version \(SettingsSummary.version), credits and the documents"
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

    private var feedSummary: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.flights.count) aircraft · \(feed.server)"
    }

    /// What the row says under its title.
    ///
    /// The next flight rather than a count, because "EGLL → KJFK, Friday 18:00"
    /// is the thing somebody opened Settings to check, and a hub that answers
    /// the question without being opened has already done its job.
    private var plansDetail: String {
        guard accounts.isSignedIn else { return "Sign in to keep your plans." }

        guard let next = plans.next else {
            return plans.hasAnswered
                ? "Nothing planned. Set your gates and your times."
                : "Your gates and times for the flights ahead."
        }

        guard let out = next.scheduledOut else { return next.routeLabel }
        return "\(next.routeLabel) · \(out.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    private var accountDetail: String {
        guard let account = accounts.account else {
            return "Carries your Pro between devices. The app works without one."
        }
        return account.email
    }

    /// Where a Pro account's Pro came from.
    ///
    /// Only ever read by the row that is built for accounts that have it, so
    /// there is no longer a sales pitch on the other side of this — that moved
    /// to `ProPromoCard`, which is a card rather than a sentence because it had
    /// something to show.
    private var proDetail: String {
        switch entitlements.source {
        case .appStore:     return "Active — through the App Store."
        case .subscription: return "Active — from your inflight.info subscription."
        case .legacy:       return "Active on your account."
        case .free:         return "Active."
        }
    }
}
