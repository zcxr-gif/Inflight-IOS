import SwiftUI

/// The VA-Ads surfaces: a line under the flight window's route card, a section
/// in the airport window listing the VAs hubbed at that field, and the panel
/// both of them open.
///
/// A partner is shown as its mark, its own words and its own links. The mark is
/// small everywhere — 16pt on the flight line, 26pt in an airport row, 30pt
/// against the panel title — because it is there to let a VA be recognised at a
/// glance, not to turn a flight window into a billboard. See `VaAd` for why the
/// logo is drawn and the banner still isn't.

// MARK: - The mark

/// A VA's own logo, at whatever size the surface has room for.
///
/// Falls back to a monogram on the theme's accent rather than to an empty
/// square: a VA that never uploaded a logo, and one whose image is still in the
/// air, should both read as an airline rather than as a broken asset. Same
/// bargain `PilotAvatar` makes for a pilot with no picture, and the same loader
/// behind it.
struct VaLogoMark: View {

    let ad: VaAd

    /// Sized by the caller — the same mark is a 16pt glyph on the flight line
    /// and a 30pt one beside a panel title.
    var side: CGFloat = 22

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @StateObject private var loader = RemoteImageLoader()

    private var theme: FlightInfoTheme { appearance.theme }

    private var corner: CGFloat { side * 0.26 }

    /// Two letters at most, taken from the front of the VA's words: "Air
    /// Canada Virtual" is AC, "Skyward" is S.
    private var monogram: String {
        let letters = ad.name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        return String(letters).uppercased()
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    // Fitted, not filled. The uploads are square 512s but a
                    // wordmark sitting inside one is wider than it is tall, and
                    // filling would crop the ends off the VA's own name.
                    .scaledToFit()
                    .padding(side * 0.08)
            } else {
                Text(monogram)
                    .font(.system(size: side * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { theme.accent }
            }
        }
        .frame(width: side, height: side)
        .background(theme.elevatedFill)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(theme.stroke, lineWidth: 0.8)
        }
        .motion(Motion.content, value: loader.image != nil)
        // The VA's name is always the next thing along, so the mark has nothing
        // to add to what VoiceOver already reads.
        .accessibilityHidden(true)
        .onAppear { loader.load(ad.logo) }
        .onChange(of: ad.logo) { _, new in loader.load(new) }
    }
}

// MARK: - Flight window

/// The partner line, sitting under the bottom edge of the route card — the band
/// between it and the foot of the window, which had nothing in it.
///
/// The line only ever claims what the lookup supports. A callsign carrying the
/// VA's tag (or a pilot on its roster) is flying with them; a callsign that is
/// merely the VA's airline is labelled as the partner it is; and a VA that only
/// hubs at an end of the route says so, so an advertisement can never be
/// misread as a fact about the aircraft.
struct VaPartnerLine: View {

    /// Resolved by the window that owns the flight, not here: this line is drawn
    /// in three places at once (both peak styles and the full window) and each
    /// of them starting its own lookup would be three requests for one answer.
    let partner: VaPartner?

    let theme: FlightInfoTheme

    /// Opens the VA's own panel.
    ///
    /// Optional, and deliberately absent in the peak state — the same bargain
    /// the route card's endpoints make. The whole peak is a drag target, and a
    /// control that could swallow a drag as a tap makes the window hard to
    /// open. In the full window there is no drag to lose, so there it is a
    /// button.
    var onOpen: ((VaAd) -> Void)? = nil

    var body: some View {
        if let partner = partner {
            if let onOpen = onOpen {
                Button {
                    onOpen(partner.ad)
                } label: {
                    line(partner)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: partner))
                .accessibilityHint("Opens this virtual airline.")
            } else {
                line(partner)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: partner))
            }
        }
    }

    private func line(_ partner: VaPartner) -> some View {
        HStack(spacing: 6) {
            Text(kicker(for: partner.basis))
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(theme.textDim)
                .fixedSize()

            // After the kicker rather than in front of it, which is the whole
            // argument of the note below in picture form: a logo is the
            // loudest thing on this line, and a line that opens with an
            // airline's mark says "this is that airline" before it has said
            // "VA". The kicker gets read first; the mark and the name then
            // arrive together as the one thing they describe.
            VaLogoMark(ad: partner.ad, side: 16)

            Text(partner.ad.name)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            // Only where there is somewhere to go. Without a tap behind it a
            // chevron is a promise the line doesn't keep.
            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    /// Every one of these carries "VA", and that is the point of them.
    ///
    /// The name beside it is often the name of a real airline, because a
    /// virtual airline that flies a livery usually calls itself after it. On a
    /// line that read only "FLYING WITH", the aeroplane looked like it belonged
    /// to that airline. Two letters is all the room there is here, and two
    /// letters is enough to say which kind of airline this is.
    private func kicker(for basis: VaPartner.Basis) -> String {
        switch basis {
        case .member:            return "FLYING WITH VA"
        case .callsign:          return "PARTNER VA"
        case .hubbed(let icao):  return "PARTNER VA AT \(icao)"
        }
    }

    private func accessibilityLabel(for partner: VaPartner) -> String {
        switch partner.basis {
        case .member:
            return "Flying with \(partner.ad.name), a partner virtual airline."
        case .callsign:
            return "\(partner.ad.name), the partner virtual airline whose callsign this flight is using."
        case .hubbed(let icao):
            return "\(partner.ad.name), a partner virtual airline hubbed at \(icao)."
        }
    }
}

// MARK: - Airport window

/// The VAs that call this field a hub.
///
/// Absent rather than empty when there are none — which is most fields in the
/// world, and a card saying "no virtual airlines" on every one of them is
/// furniture, not information.
struct AirportPartnersSection: View {

    let icao: String
    let partners: [VaAd]

    /// Opens one of them. Same shape as the flight line's: the panel belongs to
    /// whoever is presenting sheets, not to a row inside a list.
    var onOpen: ((VaAd) -> Void)? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// As many as the panel can carry without becoming a directory. The field
    /// with thirty partners is not a field anybody is reading this section on.
    private static let maximumShown = 6

    private var shown: [VaAd] {
        Array(partners.prefix(Self.maximumShown))
    }

    var body: some View {
        if !shown.isEmpty {
            PanelSection(title: "VIRTUAL AIRLINES") {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, ad in
                    if index > 0 { PanelDivider() }

                    if let onOpen = onOpen {
                        Button { onOpen(ad) } label: { row(ad, isLink: true) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(ad.name). Open this virtual airline.")
                    } else {
                        row(ad, isLink: false)
                    }
                }

                PanelDivider()

                Text("""
                Virtual airlines — groups of Infinite Flight pilots who fly \
                together — that call \(icao) a hub. Not real airlines, and not \
                affiliated with any.
                """)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private func row(_ ad: VaAd, isLink: Bool) -> some View {
        HStack(spacing: 10) {
            // Leading here, unlike the flight line: the section is titled
            // VIRTUAL AIRLINES and carries its own disclaimer underneath, so
            // there is no claim about an aeroplane for a mark to get in front
            // of, and a column of logos is what makes six rows scannable.
            VaLogoMark(ad: ad, side: 26)

            Text(ad.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.75)

            Spacer(minLength: 8)

            if ad.isRecruiting {
                Text("RECRUITING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.accent)
                    .fixedSize()
            }

            if isLink {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - The VA's own panel

/// One partner virtual airline: who they are, what they fly, and every way
/// there is to reach them.
///
/// Their mark, their words and their links. No banner — see the note at the top
/// of this file, and the one in `VaAdsService`.
struct VaDetailSheet: View {

    let ad: VaAd

    /// Why this VA was being shown, when it was reached from a flight. The
    /// panel says so plainly rather than leaving the reader to guess whether
    /// the aircraft they tapped is actually one of this VA's.
    var basis: VaPartner.Basis? = nil

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Filled once the roster has answered, which is what lets the live count
    /// include pilots the VA claims but whose callsigns carry no tag.
    @State private var hasRoster = false

    private var theme: FlightInfoTheme { appearance.theme }

    /// Recomputed per redraw rather than held: it is a filtered pass over the
    /// packet the map already has, and holding it would mean keeping it in step
    /// with a feed that republishes every few seconds.
    private var fleet: [Flight] {
        // `hasRoster` is read so the view redraws when the roster lands; the
        // service is what actually holds it.
        _ = hasRoster
        return VaAdsService.shared.fleet(of: ad, in: feed.flights)
    }

    var body: some View {
        MapPanel(title: ad.name, subtitle: subtitle, accessory: AnyView(brandMark)) {
            identity

            liveFleet

            about

            links
        }
        .task(id: ad.id) {
            _ = await VaAdsService.shared.roster(for: ad.id)
            hasRoster = true
        }
    }

    /// The VA's mark, opposite its name in the panel's title bar.
    ///
    /// The header aligns its row on the title's first baseline, and a view with
    /// no text in it answers that with its own bottom edge — which would hang
    /// the whole square above the title's cap. The guide moves the mark's
    /// alignment point 5pt up from its bottom, dropping it by that much, which
    /// centres a 30pt square on a 26pt title.
    private var brandMark: some View {
        VaLogoMark(ad: ad, side: 30)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
    }

    /// Always says "virtual airline", even when the VA has written its own
    /// tagline — that line is theirs and may say anything, and the one thing
    /// this panel has to establish before anything else is what kind of thing
    /// is being described.
    private var subtitle: String? {
        let parts = ["Virtual airline"] + [ad.tagline, ad.region].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    // MARK: Identity

    private var identity: some View {
        PanelSection(title: "PARTNER") {
            Text("""
            A group of Infinite Flight pilots who fly together in the \
            simulator. Not a real airline, and not affiliated with one — \
            including whichever one it may be named after.
            """)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            PanelDivider()

            if let basis = basis {
                detailRow(title: membershipTitle(basis), detail: membershipDetail(basis))
                PanelDivider()
            }

            if !ad.code.isEmpty {
                detailRow(title: "Callsign", detail: ad.callsign.isEmpty ? ad.code : ad.callsign)
                PanelDivider()
            }

            if !ad.type.isEmpty {
                detailRow(title: "Type", detail: ad.type)
                PanelDivider()
            }

            if !ad.region.isEmpty {
                detailRow(title: "Region", detail: ad.region)
                PanelDivider()
            }

            detailRow(
                title: ad.hubs.count == 1 ? "Hub" : "Hubs",
                detail: ad.hubs.isEmpty ? "None listed" : ad.hubs.prefix(6).joined(separator: " · ")
            )

            if ad.isRecruiting {
                PanelDivider()
                detailRow(title: "Recruiting", detail: "Open to new pilots")
            }
        }
    }

    private func membershipTitle(_ basis: VaPartner.Basis) -> String {
        switch basis {
        case .member:   return "This flight"
        case .callsign: return "This flight"
        case .hubbed:   return "Why you're seeing this"
        }
    }

    private func membershipDetail(_ basis: VaPartner.Basis) -> String {
        switch basis {
        case .member:
            return "Flying as a registered member"
        case .callsign:
            return "Flying this airline's callsign, but not marked as a member"
        case .hubbed(let icao):
            return "Hubbed at \(icao), an end of this route"
        }
    }

    // MARK: In the air

    private var liveFleet: some View {
        PanelSection(title: "IN THE AIR") {
            let fleet = self.fleet

            if fleet.isEmpty {
                Text("No \(ad.name) aircraft in the air right now.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(fleet.prefix(8).enumerated()), id: \.element.id) { index, flight in
                    if index > 0 { PanelDivider() }
                    fleetRow(flight)
                }

                if fleet.count > 8 {
                    PanelDivider()
                    Text("and \(fleet.count - 8) more.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func fleetRow(_ flight: Flight) -> some View {
        HStack(spacing: 10) {
            Text(flight.displayName)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.75)

            Spacer(minLength: 8)

            Text(route(of: flight))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func route(of flight: Flight) -> String {
        "\(code(flight.departureIcao)) → \(code(flight.arrivalIcao))"
    }

    /// An endpoint, or the mark that stands in for one that was never filed.
    private func code(_ icao: String?) -> String {
        let value = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "———" : value
    }

    // MARK: About

    @ViewBuilder
    private var about: some View {
        if !ad.description.isEmpty || !ad.tags.isEmpty {
            PanelSection(title: "ABOUT") {
                if !ad.description.isEmpty {
                    Text(ad.description)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }

                if !ad.tags.isEmpty {
                    if !ad.description.isEmpty { PanelDivider() }

                    Text(ad.tags.prefix(8).joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
            }
        }
    }

    // MARK: Links

    @ViewBuilder
    private var links: some View {
        if ad.links.isEmpty {
            PanelSection(title: "LINKS") {
                Text("\(ad.name) hasn't published anywhere to reach them.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            }
        } else {
            PanelSection(title: "LINKS") {
                ForEach(Array(ad.links.enumerated()), id: \.element.id) { index, link in
                    if index > 0 { PanelDivider() }

                    Link(destination: link.url) {
                        HStack(spacing: 10) {
                            PanelRowLabel(title: link.label, symbol: link.symbol)

                            Spacer(minLength: 8)

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.textDim)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(link.label). Opens outside the app.")
                }
            }
        }
    }

    // MARK: Rows

    private func detailRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()

            Spacer(minLength: 8)

            Text(detail)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
