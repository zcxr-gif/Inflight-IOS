import SwiftUI

/// The partner virtual airline behind a callsign, as a line of type.
///
/// Words only, and that is the whole design. The web tracker draws the same
/// data as a banner with a logo in it, which is right for a page you scroll
/// past and wrong for a window you opened to find out about one aeroplane: a
/// picture there stops being information about the flight and starts being an
/// advertisement in the middle of it. So this card says who they are, what
/// they say about themselves, and whether the pilot is flying under the VA's
/// tag — and nothing is loaded over the network to draw it.
///
/// Absent, not empty, when the callsign matches no partner. Which is most of
/// them: the card is only in the tree when there is something to put in it.
struct VirtualAirlineCard: View {

    let callsign: String
    let theme: FlightInfoTheme

    @ObservedObject private var store = VirtualAirlineStore.shared

    /// Re-read whenever the directory lands, which is what `revision` is for —
    /// the fetch usually finishes after the window is already open.
    private var found: (airline: VirtualAirline, match: VirtualAirline.Match)? {
        _ = store.revision
        return store.airline(forCallsign: callsign)
    }

    var body: some View {
        if let found = found {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("PARTNER VA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.textDim)

                    Spacer(minLength: 4)

                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textDim)
                }

                Text(found.airline.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                if !found.airline.tagline.isEmpty {
                    Text(found.airline.tagline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // What the callsign actually establishes, said plainly. A VA
                // whose airline name matches is not the same claim as a pilot
                // flying under the VA's own tag, and running the two together
                // would credit a VA with every flight that shares its airline.
                HStack(spacing: 6) {
                    Image(systemName: found.match == .member ? "checkmark.seal.fill" : "questionmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(found.match == .member ? theme.accent : theme.textDim)

                    Text(membership(for: found))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !found.airline.summary.isEmpty {
                    Text(found.airline.summary.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(theme.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private func membership(for found: (airline: VirtualAirline, match: VirtualAirline.Match)) -> String {
        switch found.match {
        case .member:
            return "Flying under \(found.airline.name)'s callsign tag."
        case .airline, .unrelated:
            return "Flying \(found.airline.name)'s airline callsign without its tag — not necessarily on their roster."
        }
    }
}

/// The partners that call a field home, in the field's own panel.
///
/// Text rows, for the same reason as the card above, and one step plainer
/// still: an airport panel is a list of facts about a field and this is one
/// more of them. Nothing is drawn at all when no partner is hubbed here, which
/// is the case at almost every airport in the world.
struct VirtualAirlineHubSection: View {

    let icao: String

    @ObservedObject private var store = VirtualAirlineStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var airlines: [VirtualAirline] {
        _ = store.revision
        return store.airlines(hubbedAt: icao)
    }

    var body: some View {
        let airlines = self.airlines

        if !airlines.isEmpty {
            PanelSection(title: airlines.count == 1 ? "VIRTUAL AIRLINE" : "VIRTUAL AIRLINES") {
                ForEach(Array(airlines.enumerated()), id: \.element.id) { index, airline in
                    if index > 0 { PanelDivider() }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(airline.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .flightInfoLine(minimumScale: 0.8)

                            Spacer(minLength: 6)

                            // The declared callsign is the useful half for
                            // anybody watching the field: it is what these
                            // aircraft will read as on the map.
                            Text(airline.callsign)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.textDim)
                        }

                        if !airline.tagline.isEmpty {
                            Text(airline.tagline)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if airline.isRecruiting {
                            Text("RECRUITING")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
    }
}
