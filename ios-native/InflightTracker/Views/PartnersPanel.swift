import SwiftUI

/// The partner virtual airlines, as a directory you can read.
///
/// The web tracker gives a VA a banner: an uploaded image at the top of the
/// airport window, a logo chip beside a callsign, an animated WebP in a
/// slide-over. None of that is here, on purpose. A VA gets exactly what every
/// other thing in this app gets — a row of type, in the panel's own voice — so
/// the partner directory reads as part of the tracker rather than as an advert
/// inside it. What a VA is actually selling is words anyway: who they are, what
/// they fly, where from, and how to join.
struct PartnersPanel: View {

    /// Open one of the VA's hubs. The field panel replaces this one, the same
    /// as it does from anywhere else that hands off to an airport.
    let onSelectAirport: (Airport) -> Void

    /// The VA to open straight onto, when the panel was reached by tapping one
    /// somewhere else — a partner listed on a field, the airline a flight is
    /// flying under. The ad itself rather than its id: whoever tapped it was
    /// already holding one, and resolving an id would mean waiting on the
    /// directory to land before the panel could draw anything.
    var focus: VirtualAirline? = nil

    @ObservedObject private var ads = VaAdsService.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// The VA being read, when one is. The panel is one window with two states
    /// rather than a stack — the way back is a row at the top, which is the same
    /// bargain the field panel makes when it is opened from a flight.
    @State private var opened: VirtualAirline?

    @State private var query = ""
    @FocusState private var isSearching: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    /// Matched on everything a VA is filed under, so "cargo", "EGLL" and
    /// "Oceanic" all find the same airline.
    private var results: [VirtualAirline] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return ads.partners }

        return ads.partners.filter { ad in
            let haystack = [ad.name, ad.callsign, ad.tagline, ad.kind, ad.region]
                + ad.hubs + ad.tags
            return haystack.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        MapPanel(title: opened?.name ?? "Virtual airlines", subtitle: subtitle) {
            if let ad = opened {
                PartnerDetail(ad: ad, onSelectAirport: onSelectAirport) {
                    withAnimation(Motion.content) { opened = nil }
                }
            } else {
                directory
            }
        }
        .onAppear {
            ads.refresh()
            if let focus = focus, opened == nil {
                opened = focus
                ads.track(.open, for: focus.id)
            }
        }
    }

    private var subtitle: String? {
        if let ad = opened {
            let parts = [ad.callsign, ad.region].filter { !$0.isEmpty }
            return parts.isEmpty ? "Partner virtual airline" : parts.joined(separator: " · ")
        }
        guard ads.hasAnswered else { return nil }
        let count = ads.partners.count
        return count == 1 ? "1 partner" : "\(count) partners"
    }

    // MARK: - The list

    @ViewBuilder
    private var directory: some View {
        PanelSection(title: "FIND A VA") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textDim)

                TextField("Name, callsign or hub", text: $query)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearching)

                if !query.isEmpty {
                    Button {
                        query = ""
                        isSearching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        let results = self.results

        PanelSection(title: query.isEmpty ? "PARTNERS" : "MATCHES") {
            if results.isEmpty {
                PanelEmptyState(
                    symbol: ads.hasAnswered ? "magnifyingglass" : "antenna.radiowaves.left.and.right",
                    title: emptyTitle,
                    detail: emptyDetail
                )
            } else {
                ForEach(results) { ad in
                    if ad.id != results.first?.id { PanelDivider() }
                    row(ad)
                }
            }
        }
    }

    private var emptyTitle: String {
        if !ads.hasAnswered { return "Loading partners" }
        return query.isEmpty ? "No partners listed" : "Nothing matches “\(query)”"
    }

    private var emptyDetail: String {
        if !ads.hasAnswered { return "The partner directory is on its way." }
        return query.isEmpty
            ? "Virtual airlines partnered with Inflight appear here."
            : "Try an airline name, a callsign, or a hub's ICAO code."
    }

    private func row(_ ad: VirtualAirline) -> some View {
        Button {
            VaAdsService.shared.track(.open, for: ad.id)
            withAnimation(Motion.content) { opened = ad }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(ad.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.8)

                        if ad.isRecruiting {
                            PartnerChip(text: "HIRING", theme: theme, filled: true)
                        }
                    }

                    Text(secondLine(ad))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.75)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .onAppear { VaAdsService.shared.track(.impression, for: ad.id) }
    }

    /// Callsign first — it is what you will see on the map — then whatever the
    /// VA said about itself, then where it flies from.
    private func secondLine(_ ad: VirtualAirline) -> String {
        var parts: [String] = []
        if !ad.callsign.isEmpty { parts.append(ad.callsign) }
        if !ad.blurb.isEmpty {
            parts.append(ad.blurb)
        } else if !ad.hubLine(limit: 3).isEmpty {
            parts.append(ad.hubLine(limit: 3))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One VA

/// A partner read in full: what they say about themselves, how they operate,
/// what they have coming up, and the ways to reach them.
private struct PartnerDetail: View {

    let ad: VirtualAirline
    let onSelectAirport: (Airport) -> Void
    let onBack: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.openURL) private var openURL

    @State private var events: [VirtualAirlineEvent] = []
    @State private var rosterCount: Int?

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Group {
            PanelSection(title: "VIRTUAL AIRLINE") {
                PanelActionRow(title: "All virtual airlines", symbol: "chevron.backward") {
                    onBack()
                }

                if !ad.blurb.isEmpty {
                    PanelDivider()
                    paragraph(ad.blurb)
                }

                if !ad.summary.isEmpty, ad.summary != ad.blurb {
                    PanelDivider()
                    paragraph(ad.summary)
                }
            }

            PanelSection(title: "OPERATION") {
                VStack(alignment: .leading, spacing: 0) {
                    if !ad.callsign.isEmpty {
                        line("Callsign", ad.callsign, symbol: "waveform")
                    }
                    if !ad.kind.isEmpty {
                        PanelDivider()
                        line("Flies", ad.kind.capitalized, symbol: "airplane")
                    }
                    if !ad.region.isEmpty {
                        PanelDivider()
                        line("Region", ad.region, symbol: "globe")
                    }
                    if let rosterCount = rosterCount {
                        PanelDivider()
                        line("Roster", rosterCount == 1 ? "1 pilot" : "\(rosterCount) pilots",
                             symbol: "person.2")
                    }
                    if ad.isRecruiting {
                        PanelDivider()
                        line("Recruiting", "Open to new pilots", symbol: "checkmark.seal")
                    }
                }
            }

            hubs

            if !ad.tags.isEmpty {
                PanelSection(title: "TAGS") {
                    Text(ad.tags.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            schedule

            links
        }
        .task(id: ad.id) {
            events = await VaAdsService.shared.events(for: ad.id)
            rosterCount = await VaAdsService.shared.rosterCount(for: ad.id)
        }
    }

    /// The VA's hubs, each one a way into that field. Only the codes this app
    /// can actually resolve are offered as rows — an ICAO the offline table has
    /// never heard of is still listed, just not as something to tap.
    @ViewBuilder
    private var hubs: some View {
        if !ad.hubs.isEmpty {
            PanelSection(title: ad.hubs.count == 1 ? "HUB" : "HUBS") {
                ForEach(Array(ad.hubs.enumerated()), id: \.offset) { index, icao in
                    if index > 0 { PanelDivider() }

                    if let airport = AirportStore.shared.airport(icao) {
                        PanelActionRow(
                            title: icao,
                            symbol: "mappin.and.ellipse",
                            detail: airport.name
                        ) {
                            onSelectAirport(airport)
                        }
                    } else {
                        line("Hub", icao, symbol: "mappin.and.ellipse")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var schedule: some View {
        if !events.isEmpty {
            PanelSection(title: "COMING UP") {
                ForEach(events) { event in
                    if event.id != events.first?.id { PanelDivider() }
                    row(event)
                }
            }
        }
    }

    private func row(_ event: VirtualAirlineEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.8)

                if event.isLive {
                    PartnerChip(text: "LIVE", theme: theme, filled: true)
                }
            }

            if let when = event.startsAt {
                Text(when.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }

            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let link = event.link {
                Button("Details") {
                    VaAdsService.shared.track(.click, for: ad.id)
                    openURL(link)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Only the links the VA actually filed, and only after they survived the
    /// http(s) check on the way in. A section of dead rows is worse than no
    /// section.
    @ViewBuilder
    private var links: some View {
        let crew = ad.slug.flatMap { AppConfig.crewCentreURL(slug: $0) }

        if crew != nil || ad.website != nil || ad.discord != nil {
            PanelSection(title: "GET IN TOUCH") {
                VStack(alignment: .leading, spacing: 0) {
                    if let crew = crew {
                        link("Crew centre", detail: "Rosters, schedules and events", symbol: "building.2", url: crew)
                    }
                    if let website = ad.website {
                        if crew != nil { PanelDivider() }
                        link("Website", detail: website.host ?? "", symbol: "safari", url: website)
                    }
                    if let discord = ad.discord {
                        if crew != nil || ad.website != nil { PanelDivider() }
                        link("Discord", detail: "Where the VA talks", symbol: "bubble.left.and.bubble.right", url: discord)
                    }
                }
            }
        }
    }

    private func link(_ title: String, detail: String, symbol: String, url: URL) -> some View {
        PanelActionRow(title: title, symbol: symbol, detail: detail.isEmpty ? nil : detail) {
            VaAdsService.shared.track(.click, for: ad.id)
            openURL(url)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            PanelRowLabel(title: title, symbol: symbol)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A word on a pill — "HIRING", "LIVE", "PARTNER VA". The only decoration a VA
/// gets anywhere in the app, and it is set in the panel's own type rather than
/// in anything the VA supplied.
struct PartnerChip: View {

    let text: String
    let theme: FlightInfoTheme
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(filled ? theme.onAccent : theme.textDim)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background {
                Capsule()
                    .fill(filled ? theme.accent : Color.clear)
                    .overlay { if !filled { Capsule().strokeBorder(theme.stroke, lineWidth: 1) } }
            }
            .fixedSize()
    }
}
