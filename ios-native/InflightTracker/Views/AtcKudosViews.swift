import SwiftUI

/// Kudos and RateMyATC on screen: the bar under each controller, the sheets it
/// opens, the controller's own page, the board, and what a controller has been
/// given. The rules are the server's — see `AtcKudosStore`.

/// Where a pilot with a violation to appeal is sent instead. Kudos and ratings
/// are for thanks and feedback, not for disputes, and saying so where the
/// buttons are is what keeps them that way.
let atcAppealURL = URL(string: "https://community.infiniteflight.com/t/procedures-for-appealing-violations-and-providing-atc-feedback/795506")!

// MARK: - The bar under a controller

/// 👍 · ☀️ · ★ under one controller on frequency. One tap sends kudos; the
/// same tap again takes it back. ★ opens the rating sheet.
struct AtcKudosBar: View {

    let facility: AtcFacility

    /// Off on the controller's own page, which this would otherwise open again.
    var showsProfileButton = true

    @ObservedObject private var store = AtcKudosStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @EnvironmentObject private var feed: LiveFeed

    @State private var sending: AtcKudosStore.Kind?
    @State private var problem: String?
    @State private var isRating = false
    @State private var isViewing = false
    @State private var isAddingNote = false
    @State private var isShowingAccount = false

    private var theme: FlightInfoTheme { appearance.theme }

    private var stats: AtcKudosStore.Stats? {
        facility.controllerId.flatMap { store.stats[$0] }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AtcKudosStore.Kind.allCases) { kind in
                kudosButton(kind)
            }
            rateButton

            if store.myKind(for: facility) != nil {
                chip(symbol: "square.and.pencil", text: "Note", isOn: false) { isAddingNote = true }
                    .accessibilityLabel(L("Add a note to your kudos"))
            }

            Spacer(minLength: 0)

            if showsProfileButton {
                Button { isViewing = true } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Lf("%@'s kudos and ratings", facility.controller))
            }
        }
        .padding(.leading, 47)
        .task(id: facility.controllerId) {
            if let id = facility.controllerId { store.request(id) }
        }
        .alert(L("Kudos"), isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L(problem ?? ""))
        }
        .sheet(isPresented: $isRating) {
            AtcRateSheet(facility: facility, current: store.myStars(for: facility) ?? 0)
        }
        .sheet(isPresented: $isAddingNote) {
            AtcNoteSheet(facility: facility, kind: store.myKind(for: facility) ?? .thumbsUp)
        }
        .sheet(isPresented: $isViewing) {
            // Erased: the page has a bar of its own, and an opaque type
            // cannot be defined in terms of itself.
            if let id = facility.controllerId {
                AnyView(
                    AtcControllerView(controllerId: id, username: facility.controller, live: facility)
                        .environmentObject(feed)
                )
            }
        }
        .sheet(isPresented: $isShowingAccount) {
            AccountPanel().environmentObject(feed)
        }
    }

    private func kudosButton(_ kind: AtcKudosStore.Kind) -> some View {
        let count = kind == .thumbsUp ? (stats?.thumbsUp ?? 0) : (stats?.goodDay ?? 0)
        let isOn = store.myKind(for: facility) == kind
        return chip(emoji: kind.emoji, text: count > 0 ? String(count) : nil, isOn: isOn) {
            guard accounts.isSignedIn else { isShowingAccount = true; return }
            guard sending == nil else { return }
            sending = kind
            Task {
                defer { sending = nil }
                do {
                    try await store.toggle(kind, for: facility)
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
        .opacity(sending == kind ? 0.5 : 1)
        .accessibilityLabel(isOn
            ? Lf("Take back your %@ kudos", L(kind.label))
            : Lf("Send %@ kudos to %@", L(kind.label), facility.controller))
    }

    private var rateButton: some View {
        let mine = store.myStars(for: facility)
        let text: String
        if let mine = mine {
            text = Lf("You %@", String(mine))
        } else if let avg = stats?.ratingAvg, (stats?.ratingCount ?? 0) > 0 {
            text = String(format: "%.1f", avg)
        } else {
            text = L("Rate")
        }
        return chip(symbol: "star.fill", text: text, isOn: mine != nil) {
            guard accounts.isSignedIn else { isShowingAccount = true; return }
            isRating = true
        }
        .accessibilityLabel(Lf("Rate %@", facility.controller))
    }

    private func chip(
        emoji: String? = nil,
        symbol: String? = nil,
        text: String?,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let emoji = emoji { Text(emoji).font(.system(size: 11)) }
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isOn ? theme.onAccent : Color.yellow)
                }
                if let text = text {
                    Text(L(text))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isOn ? theme.onAccent : theme.textSecondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background { Capsule().fill(isOn ? theme.accent : theme.elevatedFill) }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }
}

/// A facility line with its kudos bar under it, when the controller can be
/// thanked at all.
struct AtcFacilityKudosLine: View {

    let facility: AtcFacility
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PanelFacilityLine(facility: facility, now: now)
            if facility.canReceiveKudos && facility.kind != .atis {
                AtcKudosBar(facility: facility)
            }
        }
    }
}

// MARK: - Rating

/// RateMyATC for one session. Says, before anything is sent, who will read a
/// comment: everyone for 4–5★, only the controller for 1–3★.
struct AtcRateSheet: View {

    let facility: AtcFacility

    @State private var stars: Int
    @State private var comment = ""
    @State private var isSending = false
    @State private var problem: String?

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.dismiss) private var dismiss

    private static let limit = 280

    init(facility: AtcFacility, current: Int) {
        self.facility = facility
        _stars = State(initialValue: current)
    }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "RateMyATC", subtitle: Lf("%@ · %@ %@", facility.controller, facility.station, facility.kind.code)) {
            PanelSection(title: "YOUR RATING") {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { n in
                            Button { stars = n } label: {
                                Image(systemName: n <= stars ? "star.fill" : "star")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(n <= stars ? Color.yellow : theme.textDim)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(Lf("%@ stars", String(n)))
                        }
                    }
                    Text(L(Self.word(stars)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            PanelSection(title: "COMMENT · OPTIONAL") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("What went well, or what could be better?"), text: $comment, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(3...6)
                        .onChange(of: comment) { _, text in
                            if text.count > Self.limit { comment = String(text.prefix(Self.limit)) }
                        }
                    Text(L("\(comment.count)/\(Self.limit)"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(12)
            }

            AtcNotice(lines: [
                stars > 0 && stars <= 3
                    ? Lf("A comment on a 1–3★ rating goes privately to %@. Nobody else can read it.", facility.controller)
                    : Lf("A comment on a 4–5★ rating is shown on %@'s RateMyATC page.", facility.controller),
                L("Your stars count toward their public rating either way. One rating per session — rating again replaces it.")
            ])

            AtcAppealLink()

            if let problem = problem {
                Text(L(problem))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }

            AtcPrimaryButton(title: isSending ? "Submitting…" : "Submit rating", isEnabled: stars > 0 && !isSending) {
                isSending = true
                problem = nil
                Task {
                    defer { isSending = false }
                    do {
                        try await AtcKudosStore.shared.rate(stars, comment: comment, for: facility)
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }

    static func word(_ stars: Int) -> String {
        switch stars {
        case 1: return "Poor"
        case 2: return "Needs work"
        case 3: return "Okay"
        case 4: return "Good"
        case 5: return "Excellent"
        default: return "Tap a star"
        }
    }
}

/// A short public thank-you on a kudos already sent.
struct AtcNoteSheet: View {

    let facility: AtcFacility
    let kind: AtcKudosStore.Kind

    @State private var note = ""
    @State private var isSending = false
    @State private var problem: String?

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.dismiss) private var dismiss

    private static let limit = 140

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Add a note", subtitle: Lf("%@ %@ for %@", kind.emoji, L(kind.label), facility.controller)) {
            PanelSection(title: "NOTE") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("Thanks for the smooth vectors!"), text: $note, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2...4)
                        .onChange(of: note) { _, text in
                            if text.count > Self.limit { note = String(text.prefix(Self.limit)) }
                        }
                    Text(L("\(note.count)/\(Self.limit)"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(12)
            }

            AtcNotice(lines: [
                L("Notes are public: they show on the controller's page and at the airport."),
                L("Kudos are for thanks. For a complaint, rate the session instead — 1–3★ comments go only to the controller.")
            ])

            AtcAppealLink()

            if let problem = problem {
                Text(L(problem))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }

            AtcPrimaryButton(title: isSending ? "Saving…" : "Save note", isEnabled: !isSending) {
                isSending = true
                problem = nil
                Task {
                    defer { isSending = false }
                    do {
                        try await AtcKudosStore.shared.commend(kind, note: note, for: facility)
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - A controller's page

/// Everything public about one controller: their stars, the 4–5★ comments,
/// and their kudos. Opened from the bar, the board and the inbox.
struct AtcControllerView: View {

    let controllerId: String
    let username: String

    /// Set when they are on frequency now, so they can be thanked from here.
    var live: AtcFacility? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = AtcKudosStore.shared
    @State private var profile: AtcKudosStore.ControllerProfile?
    @State private var isLoading = true

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: username, subtitle: subtitle) {
            if let live = live, live.canReceiveKudos {
                PanelSection(title: "ON FREQUENCY NOW") {
                    VStack(alignment: .leading, spacing: 5) {
                        PanelFacilityLine(facility: live)
                        AtcKudosBar(facility: live, showsProfileButton: false)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            if isLoading && profile == nil {
                PanelSection(title: "RATEMYATC") {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            } else if let profile = profile {
                ratings(profile.ratings)
                comments(profile.ratings?.comments ?? [])
                kudos(profile.kudos)
            } else {
                PanelSection(title: "RATEMYATC") {
                    PanelEmptyState(
                        symbol: "wifi.exclamationmark",
                        title: "Couldn't load this controller",
                        detail: "Check your connection and open the page again."
                    )
                }
            }

            AtcAppealLink()
        }
        .task(id: controllerId) {
            isLoading = true
            profile = await AtcKudosStore.shared.profile(controllerId: controllerId)
            isLoading = false
        }
        // Re-read after a kudos or rating sent from the bar above — keyed on
        // what changed, not on when it was fetched, so a plain refresh of the
        // counts does not reload the page.
        .onChange(of: changeKey) { _, _ in
            Task { profile = await store.profile(controllerId: controllerId) ?? profile }
        }
    }

    private var changeKey: [Int] {
        guard let s = store.stats[controllerId] else { return [] }
        return [s.kudos, s.ratingCount, Int((s.ratingAvg ?? 0) * 100), s.myStars ?? 0, s.myKind == nil ? 0 : 1]
    }

    private var subtitle: String {
        guard let r = profile?.ratings, let avg = r.avg?.value, (r.count ?? 0) > 0 else {
            return L("Infinite Flight controller")
        }
        return Lf("★ %@ · %@ ratings", String(format: "%.1f", avg), String(r.count ?? 0))
    }

    @ViewBuilder
    private func ratings(_ r: AtcKudosStore.RatingProfile?) -> some View {
        PanelSection(title: "RATEMYATC") {
            if let r = r, let avg = r.avg?.value, let count = r.count, count > 0 {
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 2) {
                        Text(String(format: "%.1f", avg))
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                        AtcStars(value: avg, size: 11)
                        Text(L(count == 1 ? "1 rating" : Lf("%@ ratings", String(count))))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textDim)
                    }
                    VStack(spacing: 3) {
                        ForEach(Array((1...5).reversed()), id: \.self) { n in
                            distributionRow(n, count: r.dist?[String(n)] ?? 0, total: count)
                        }
                    }
                }
                .padding(14)
            } else {
                PanelEmptyState(
                    symbol: "star",
                    title: "No ratings yet",
                    detail: "Pilots who fly with this controller can rate the session with ★ under their name."
                )
            }
        }
    }

    private func distributionRow(_ n: Int, count: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            Text(L("\(n)"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textDim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.trackFill)
                    Capsule().fill(Color.yellow)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(count) / CGFloat(total) : 0)
                }
            }
            .frame(height: 6)
            Text(L("\(count)"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .frame(width: 26, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func comments(_ list: [AtcKudosStore.RatingComment]) -> some View {
        if !list.isEmpty {
            PanelSection(title: "WHAT PILOTS SAID") {
                ForEach(Array(list.enumerated()), id: \.offset) { index, c in
                    if index > 0 { PanelDivider() }
                    AtcEntryRow(
                        lead: AnyView(AtcStars(value: Double(c.stars ?? 0), size: 9)),
                        text: c.comment,
                        meta: AtcEntryRow.meta(by: c.by, airport: c.airport_icao, date: c.date)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func kudos(_ k: AtcKudosStore.KudosProfile) -> some View {
        PanelSection(title: "KUDOS") {
            if (k.total ?? 0) > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        stat(String(k.total ?? 0), "kudos")
                        stat("👍 \(k.thumbs_up ?? 0)", "thumbs up")
                        stat("☀️ \(k.good_day ?? 0)", "good day")
                        stat(String(k.sessions ?? 0), "sessions")
                    }
                    let airports = Self.airportLine(k.airports ?? [])
                    if !airports.isEmpty {
                        Text(L(airports))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                    }
                }
                .padding(14)

                ForEach(Array((k.recent ?? []).enumerated()), id: \.offset) { _, e in
                    PanelDivider()
                    AtcEntryRow(
                        lead: AnyView(Text(e.kudosKind?.emoji ?? "👍").font(.system(size: 12))),
                        text: e.note,
                        meta: AtcEntryRow.meta(by: e.by, airport: e.airport_icao, date: e.date)
                    )
                }
            } else {
                PanelEmptyState(
                    symbol: "hand.thumbsup",
                    title: "No kudos yet",
                    detail: "A 👍 or ☀️ under a controller's name thanks them for opening the frequency."
                )
            }
        }
    }

    /// Where they were thanked most: `EGLL 12 · EGKK 4`.
    private static func airportLine(_ list: [AtcKudosStore.KudosProfile.AirportCount]) -> String {
        var parts: [String] = []
        for a in list.prefix(6) {
            guard let icao = a.icao else { continue }
            parts.append("\(icao) \(a.count ?? 0)")
        }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L(value))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text(L(label))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textDim)
        }
    }
}

// MARK: - The board

/// RateMyATC: who pilots rate highest and thank most, and who is on now.
struct RateMyAtcBoard: View {

    enum Tab: String, CaseIterable, Identifiable {
        case top, kudos, live
        var id: String { rawValue }
        var label: String {
            switch self {
            case .top: return "Top rated"
            case .kudos: return "Most kudos"
            case .live: return "Live now"
            }
        }
    }

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var store = AtcKudosStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var tab: Tab = .top
    @State private var allTime = false
    @State private var board: AtcKudosStore.Leaderboard?
    @State private var isLoading = true
    @State private var opened: OpenedController?

    struct OpenedController: Identifiable {
        let id: String
        let username: String
        let live: AtcFacility?
    }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "RateMyATC", subtitle: subtitle) {
            VStack(spacing: 8) {
                Picker(L("Board"), selection: $tab) {
                    ForEach(Tab.allCases) { Text(L($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)

                if tab != .live {
                    Picker(L("Period"), selection: $allTime) {
                        Text(L("30 days")).tag(false)
                        Text(L("All time")).tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            switch tab {
            case .top: boardList(board?.top_rated ?? [], empty: "Controllers need 3 ratings to be ranked.")
            case .kudos: boardList(board?.most_kudos ?? [], empty: "No kudos in this period yet.")
            case .live: liveList
            }

            AtcNotice(lines: [
                L("Top rated uses a weighted average, so one 5★ rating can't outrank forty 4.9★ ones. Controllers need 3 ratings to appear."),
                L("Stars are public. Comments on 1–3★ ratings are private to the controller.")
            ])
        }
        .task(id: allTime) {
            isLoading = true
            board = await store.leaderboard(days: allTime ? 0 : 30)
            isLoading = false
        }
        .task(id: tab) {
            if tab == .live { await store.ensure(liveFacilities.compactMap(\.controllerId)) }
        }
        .sheet(item: $opened) { c in
            AtcControllerView(controllerId: c.id, username: c.username, live: c.live)
                .environmentObject(feed)
        }
    }

    private var subtitle: String {
        guard let b = board else { return L("Rate the controllers you fly with") }
        return Lf("%@ controllers · %@ ratings · %@ kudos",
                  String(b.controllers ?? 0), String(b.ratings ?? 0), String(b.kudos ?? 0))
    }

    /// One row per controller on now — the first position each one is working.
    private var liveFacilities: [AtcFacility] {
        var seen = Set<String>()
        return feed.atcStations.flatMap(\.facilities).filter { f in
            guard f.canReceiveKudos, f.kind != .atis, let id = f.controllerId else { return false }
            return seen.insert(id).inserted
        }
    }

    private func liveFacility(_ id: String) -> AtcFacility? {
        feed.atcStations.lazy.flatMap(\.facilities).first { $0.controllerId == id && $0.canReceiveKudos }
    }

    @ViewBuilder
    private func boardList(_ rows: [AtcKudosStore.BoardRow], empty: String) -> some View {
        PanelSection(title: allTime ? "ALL TIME" : "LAST 30 DAYS") {
            if isLoading && board == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
            } else if rows.isEmpty {
                PanelEmptyState(symbol: "star", title: "Nothing here yet", detail: empty)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { PanelDivider() }
                    let live = liveFacility(row.controller_if_id)
                    boardRow(
                        rank: index + 1,
                        name: row.username ?? "Controller",
                        detail: live.map { "On now · \($0.station) \($0.kind.code)" }
                            ?? row.last_airport.map { "Last seen at \($0)" },
                        isLive: live != nil,
                        avg: row.rating_avg?.value,
                        count: row.rating_count ?? 0,
                        kudos: row.kudos ?? 0
                    ) {
                        opened = OpenedController(id: row.controller_if_id, username: row.username ?? "Controller", live: live)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var liveList: some View {
        let list = liveFacilities.sorted { a, b in
            let sa = a.controllerId.flatMap { store.stats[$0] }
            let sb = b.controllerId.flatMap { store.stats[$0] }
            let ra = sa?.ratingAvg ?? 0, rb = sb?.ratingAvg ?? 0
            if ra != rb { return ra > rb }
            return (sa?.kudos ?? 0) > (sb?.kudos ?? 0)
        }
        PanelSection(title: Lf("ON FREQUENCY · %@", feed.server.uppercased())) {
            if list.isEmpty {
                PanelEmptyState(
                    symbol: "antenna.radiowaves.left.and.right.slash",
                    title: "Nobody is controlling",
                    detail: "Controllers on this server show here with their ratings."
                )
            } else {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, f in
                    if index > 0 { PanelDivider() }
                    let s = f.controllerId.flatMap { store.stats[$0] }
                    boardRow(
                        rank: nil,
                        name: f.controller,
                        detail: "\(f.station) \(f.kind.code)",
                        isLive: true,
                        avg: s?.ratingAvg,
                        count: s?.ratingCount ?? 0,
                        kudos: s?.kudos ?? 0
                    ) {
                        if let id = f.controllerId {
                            opened = OpenedController(id: id, username: f.controller, live: f)
                        }
                    }
                }
            }
        }
    }

    private func boardRow(
        rank: Int?,
        name: String,
        detail: String?,
        isLive: Bool,
        avg: Double?,
        count: Int,
        kudos: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let rank = rank {
                    Text(L("\(rank)"))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(rank <= 3 ? Color.yellow : theme.textDim)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(name))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.7)
                    if let detail = detail {
                        HStack(spacing: 4) {
                            if isLive { Circle().fill(Color.green).frame(width: 6, height: 6) }
                            Text(L(detail))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .flightInfoLine(minimumScale: 0.7)
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    if let avg = avg, count > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.yellow)
                            Text(String(format: "%.1f", avg))
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundStyle(theme.textPrimary)
                            Text(L("(\(count))"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.textDim)
                        }
                    }
                    if kudos > 0 {
                        Text(L("👍 \(kudos)"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
    }
}

// MARK: - What a controller has been given

/// On the account panel: kudos and ratings the signed-in pilot has received as
/// a controller, and the private 1–3★ feedback only they can read.
struct AtcKudosInboxSection: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var inbox: AtcKudosStore.Inbox?
    @State private var newCount = 0
    @State private var isOpening = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        PanelSection(title: "YOUR ATC KUDOS") {
            content
        }
        .task {
            inbox = await AtcKudosStore.shared.inbox()
            newCount = AtcKudosStore.shared.unseen
            if inbox != nil { AtcKudosStore.shared.markInboxSeen() }
        }
        .sheet(isPresented: $isOpening) {
            if let id = inbox?.controller_if_id {
                AtcControllerView(controllerId: id, username: inbox?.username ?? "You")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let inbox = inbox {
            if inbox.linked != true {
                PanelEmptyState(
                    symbol: "person.text.rectangle",
                    title: "Control on Infinite Flight?",
                    detail: "Save your Infinite Flight username under Your Callsign and the kudos and ratings pilots give you show here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        if let avg = inbox.rating_avg?.value, (inbox.rating_count ?? 0) > 0 {
                            summary(String(format: "★ %.1f", avg), Lf("%@ ratings", String(inbox.rating_count ?? 0)))
                        }
                        summary("👍 \(inbox.total ?? 0)", "kudos")
                        Spacer(minLength: 0)
                        if newCount > 0 {
                            Text(L(Lf("%@ new", String(newCount))))
                                .font(.system(size: 10.5, weight: .heavy))
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background { Capsule().fill(theme.accent) }
                        }
                    }
                }
                .padding(14)

                ForEach(Array((inbox.recent ?? []).prefix(5).enumerated()), id: \.offset) { _, e in
                    PanelDivider()
                    AtcEntryRow(
                        lead: AnyView(Text(e.kudosKind?.emoji ?? "👍").font(.system(size: 12))),
                        text: e.note,
                        meta: AtcEntryRow.meta(by: e.by, airport: e.airport_icao, date: e.date)
                    )
                }

                if inbox.owner == true {
                    let feedback = inbox.feedback ?? []
                    if !feedback.isEmpty {
                        PanelDivider()
                        Label(L("Private feedback — only you can see this"), systemImage: "lock.fill")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(theme.textDim)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        ForEach(Array(feedback.prefix(5).enumerated()), id: \.offset) { _, c in
                            AtcEntryRow(
                                lead: AnyView(AtcStars(value: Double(c.stars ?? 0), size: 9)),
                                text: c.comment,
                                meta: AtcEntryRow.meta(by: nil, airport: c.airport_icao, date: c.date, anonymous: true)
                            )
                        }
                    }
                } else {
                    PanelDivider()
                    Text(L("Another account also claims this Infinite Flight name, so private feedback stays hidden until yours is verified."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(14)
                }

                if inbox.controller_if_id != nil {
                    PanelDivider()
                    PanelActionRow(title: "Open my RateMyATC page", symbol: "star.bubble") { isOpening = true }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
        }
    }

    private func summary(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L(value))
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text(L(label))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textDim)
        }
    }
}

// MARK: - Small parts

/// On the map's avatar: kudos or private feedback the signed-in controller
/// has not looked at yet. Checks every few minutes while it is on screen.
struct AtcKudosAvatarBadge: View {

    @ObservedObject private var store = AtcKudosStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        // A ZStack with something always in it, so the check below runs
        // while there is nothing yet to show.
        ZStack {
            Color.clear.frame(width: 1, height: 1)
            if store.unseen > 0 {
                Text(L(store.unseen > 9 ? "9+" : String(store.unseen)))
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background { Capsule().fill(Color.yellow) }
                    .overlay { Capsule().strokeBorder(theme.windowFill, lineWidth: 1.5) }
                    .accessibilityLabel(Lf("%@ new kudos and ratings", String(store.unseen)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .task {
            while !Task.isCancelled {
                _ = await store.inbox()
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            }
        }
    }
}

/// Five stars, filled to the nearest half.
struct AtcStars: View {
    let value: Double
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                let d = value - Double(n - 1)
                Image(systemName: d >= 0.75 ? "star.fill" : d >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color.yellow)
            }
        }
        .accessibilityLabel(Lf("%@ out of 5 stars", String(format: "%.1f", value)))
    }
}

/// A kudos note or a rating comment: what was left, who left it, where, when.
struct AtcEntryRow: View {
    let lead: AnyView
    let text: String?
    let meta: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            lead.frame(minWidth: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let text = text, !text.isEmpty {
                    Text(L(text))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L(meta))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func meta(by: AtcKudosStore.By?, airport: String?, date: Date?, anonymous: Bool = false) -> String {
        var parts: [String] = []
        parts.append(anonymous ? L("Anonymous pilot") : L(by?.label ?? "A pilot"))
        if let airport = airport, !airport.isEmpty { parts.append(airport) }
        if let date = date { parts.append(relative.localizedString(for: date, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}

struct AtcNotice: View {
    let lines: [String]

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(L(line))
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The way out for a dispute, which kudos and ratings are not for.
struct AtcAppealLink: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Link(destination: atcAppealURL) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 11))
                Text(L("Appealing a violation? Use the Infinite Flight Community's procedure."))
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .flightInfoSurface(theme, radius: theme.radiusSmall)
        }
    }
}

struct AtcPrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            Text(L(title))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .fill(theme.accent)
                }
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
