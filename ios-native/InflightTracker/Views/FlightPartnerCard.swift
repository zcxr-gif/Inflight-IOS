import SwiftUI

/// The partner virtual airline a flight is flying for, in the flight window.
///
/// This is the surface the VA-Ads service exists for, and it is also the one
/// the web tracker leans on hardest: there it is a logo chip beside the
/// callsign and a banner under it. Here it is a sentence. A callsign on the map
/// reading "Air Canada 001VA" is already the advert — what it is missing is who
/// that is, and whether this pilot actually flies for them, which is what the
/// two lines below say.
///
/// Draws nothing at all unless the callsign resolves to a partner, which is
/// most flights on most servers. The directory is warmed by whoever asked
/// first; a cold lookup answers "no partner" and the card appears a moment
/// later when the load lands, rather than holding a placeholder open for one
/// that is probably not coming.
struct FlightPartnerCard: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// Open the VA in the partner directory.
    let onSelect: (VirtualAirline) -> Void

    /// Observed rather than read once: the first flight opened in a session is
    /// usually the one that triggers the directory load, and without this the
    /// card would stay absent until something else redrew the window.
    @ObservedObject private var ads = VaAdsService.shared

    private var partner: VirtualAirline? {
        guard let callsign = flight.callsign, !callsign.isEmpty else { return nil }
        return ads.partner(forCallsign: callsign)
    }

    var body: some View {
        if let ad = partner {
            let isMember = ads.isMember(callsign: flight.callsign ?? "", of: ad)

            Button {
                ads.track(.open, for: ad.id)
                onSelect(ad)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(ad.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .flightInfoLine(minimumScale: 0.8)

                            PartnerChip(text: "PARTNER VA", theme: theme)
                        }

                        // Said plainly rather than implied. Flying an airline's
                        // callsign is not the same as being on its roster, and
                        // the web tracker has always drawn the distinction —
                        // "Air Canada 001VA" carries the VA's tag, "Air Canada
                        // 500" is the same airline flown by somebody who is not
                        // signed up.
                        HStack(spacing: 5) {
                            if isMember {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.accent)
                            }

                            Text(isMember
                                 ? "Registered \(ad.name) member"
                                 : "Not a registered \(ad.name) member")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .flightInfoLine(minimumScale: 0.75)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.985))
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            .onAppear { ads.track(.impression, for: ad.id) }
            .accessibilityLabel(
                "\(ad.name), partner virtual airline. "
                + (isMember ? "This pilot is a registered member." : "This pilot is not a registered member.")
            )
        }
    }
}
