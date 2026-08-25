import SwiftUI

/// The VA-Ads surfaces, in the two windows that have somewhere to put them: a
/// line under the flight window's identity block, and a section in the airport
/// window listing the VAs hubbed at that field.
///
/// Both show one thing about a partner — its NAME, as text. The directory also
/// carries logos, banner artwork and taglines, and none of it is drawn here:
/// that material belongs to the VAs who uploaded it, and this app has no licence
/// to reproduce it. `VaAd` doesn't even parse those fields, so there is nothing
/// for a later change to accidentally start showing.

// MARK: - Flight window

/// The partner line, sitting in the gap between the identity block and the route
/// card — the strip of window that had nothing in it.
///
/// The line is only ever as strong a claim as the lookup supports. A callsign
/// that resolves to a partner says the flight is flying with them; a VA that
/// merely hubs at an end of the route is labelled as what it is, so an
/// advertisement can never be misread as a fact about the aircraft.
struct VaPartnerLine: View {

    /// Resolved by the window that owns the flight, not here: this line is drawn
    /// in three places at once (both peak styles and the full window) and each
    /// of them starting its own lookup would be three requests for one answer.
    let partner: VaPartner?

    let theme: FlightInfoTheme

    var body: some View {
        if let partner = partner {
            HStack(spacing: 6) {
                Text(kicker(for: partner.basis))
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(theme.textDim)
                    .fixedSize()

                Text(partner.ad.name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: partner))
        }
    }

    private func kicker(for basis: VaPartner.Basis) -> String {
        switch basis {
        case .flying:
            return "FLYING WITH"
        case .hubbed(let icao):
            return "PARTNER AT \(icao)"
        }
    }

    private func accessibilityLabel(for partner: VaPartner) -> String {
        switch partner.basis {
        case .flying:
            return "Flying with \(partner.ad.name)."
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

                    Text(ad.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }

                PanelDivider()

                Text("Partner virtual airlines that call \(icao) a hub.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }
}
