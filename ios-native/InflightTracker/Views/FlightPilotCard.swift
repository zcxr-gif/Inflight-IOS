import SwiftUI

/// Who is flying it.
///
/// ## What this replaced
///
/// The window used to say the pilot's name twice and mean something different
/// each time, in two places neither of which was about the person: a small
/// avatar and handle wedged into the identity block beside the callsign, and a
/// "Profile" chip four controls along a row of chips. A pilot was a footnote on
/// an aeroplane.
///
/// This is the same information given the shape the window already uses for the
/// other thing worth knowing about a flight — `PlaceCard`, the block that says
/// PARKED AT and then the field. Same skeleton: a round glyph, a kicker, the
/// identifier in heavy type, a quieter line under it. A person gets the same
/// weight as an airport because on a live traffic map they are the same kind of
/// fact.
///
/// ## The three sources behind it, and why they stay apart
///
/// - The **name** comes off the aeroplane. It is what the feed says and it is
///   the only part that is certainly about this flight.
/// - The **picture and the banner** come from Inflight's own profiles, resolved
///   through `PilotDirectory`. Most pilots have never claimed one, and that is
///   drawn as an ordinary state rather than as an advert for signing up.
/// - The **grade and the virtual airline** come from Infinite Flight, through
///   `PilotStatsService`. Nobody types those, which is exactly why they are the
///   half worth colouring.
///
/// The third is the only one that is verified, so it is the only one drawn as a
/// flat statement. The middle one is a claim — anybody may put any Infinite
/// Flight name on their profile — and the card never says otherwise; the
/// profile it opens is where that is spelled out.
struct FlightPilotCard: View {

    let flight: Flight
    let theme: FlightInfoTheme

    /// A made-up block for the settings preview, which draws this card for an
    /// aeroplane that does not exist.
    ///
    /// When it is set nothing is looked up at all — neither the grade nor the
    /// profile. Asking the Live API about an invented pilot is a request that
    /// can only ever 404, and asking it every time somebody opens the flight
    /// window settings is a 404 a week per person for a picture of a card.
    var stub: IFPilotStats? = nil

    /// The banner the settings preview wears, for the same reason.
    ///
    /// The preview has to show what "Their banner" does or the setting under it
    /// is a word with nothing behind it — and the invented pilot has no profile
    /// to take a real one from.
    var stubBanner: BannerPreset? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// The Inflight profile behind the name, if this pilot has claimed one.
    @State private var profile: PilotProfile?

    /// What Infinite Flight has them at.
    @State private var stats: IFPilotStats?

    @State private var opened: ProfileLink?

    @StateObject private var banner = RemoteImageLoader()

    /// The name written on the aeroplane. Nil is rare and real — the feed does
    /// send aircraft with no pilot attached — and the card draws nothing at all
    /// for one rather than a block about nobody.
    private var pilot: String? {
        guard let username = flight.username, !username.isEmpty else { return nil }
        return username
    }

    /// The virtual airline, preferring what the stats block says over what the
    /// packet said.
    ///
    /// They are the same field from the same source and they disagree only by
    /// age: the packet's copy is whatever was true when the aircraft last
    /// reported, and the stats block is fetched now. Neither is ours and
    /// neither is a claim made here.
    private var organisation: String? {
        let candidate = stats?.virtualOrganization ?? flight.virtualOrganization
        guard let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private var grade: IFGrade? { stats?.gradeBadge }

    /// Whether the pilot's own banner goes behind the card.
    ///
    /// Both halves have to be true: the reader has asked for pictures, and this
    /// pilot has a profile to take one from. A pilot with no profile gets the
    /// plain card whatever the setting says — there is nothing of theirs to
    /// draw, and inventing a gradient for somebody who never picked one would
    /// be the window making something up about a person.
    private var wearsBanner: Bool {
        guard appearance.pilotCardBackdrop == .picture else { return false }
        return profile != nil || stubBanner != nil
    }

    var body: some View {
        Group {
            if pilot != nil {
                content
            }
        }
        .task(id: flight.username) { await resolveProfile() }
        .task(id: statsKey) { await resolveStats() }
        .sheet(item: $opened) { link in PublicProfileView(link: link) }
    }

    /// What a stats lookup is about. The id when the feed sent one, the name
    /// otherwise — the same order `PilotStatsService` resolves in, so the task
    /// restarts exactly when the answer would change.
    private var statsKey: String {
        flight.userId ?? flight.username ?? ""
    }

    // MARK: - The card

    @ViewBuilder
    private var content: some View {
        if let handle = profile?.handle {
            Button {
                opened = .handle(handle)
            } label: { card }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens their Inflight profile")
        } else {
            card
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text("FLOWN BY")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(wearsBanner ? overlayDim : theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)

                Text(name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(wearsBanner ? overlayInk : theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
                    // The window is the same window when another aeroplane is
                    // opened in it, so the name crosses rather than cuts.
                    .motionWords(name)

                secondLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            side
        }
        .padding(14)
        .background { backdrop }
        .flightInfoSurface(theme, radius: theme.radiusMedium, interactive: profile != nil)
        .contentShape(Rectangle())
        .motion(Motion.content, value: wearsBanner)
    }

    private var avatar: some View {
        Group {
            if let profile {
                PilotAvatar(
                    url: profile.avatarURL,
                    initials: profile.initials,
                    side: 42,
                    isPro: profile.isPro,
                    tint: profile.accentColor
                )
            } else {
                // The same circle at the same size, so a pilot with no profile
                // is a person we know nothing about rather than a hole in the
                // layout.
                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(theme.accent))
            }
        }
    }

    /// The state chip, and the profile's own name where there is one.
    ///
    /// ACTIVE and AP+ used to sit up beside the callsign. They belong here:
    /// what they say is whether a *person* is at the controls, which is a fact
    /// about the pilot and not about the aeroplane — the phase chip beside the
    /// callsign is the one about the aeroplane.
    private var secondLine: some View {
        HStack(spacing: 6) {
            PilotStateChip(state: flight.pilotState, theme: theme, elevated: wearsBanner)

            if let display = profileName {
                Text(display)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(wearsBanner ? overlayDim : theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }

            Spacer(minLength: 0)
        }
    }

    /// The grade, and the virtual airline under it.
    ///
    /// Together because they answer one question — what this pilot is, on the
    /// server — and apart from everything on the left, which is who they are.
    @ViewBuilder
    private var side: some View {
        if grade != nil || organisation != nil {
            VStack(alignment: .trailing, spacing: 5) {
                if let grade {
                    gradeBadge(grade)
                }

                if let organisation {
                    Text(organisation.uppercased())
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(wearsBanner ? overlayDim : theme.textDim)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        // A VA name is long and the pilot's name is longer, so
                        // this is the piece that is allowed a ceiling: past it
                        // the card is a paragraph rather than a card.
                        .frame(maxWidth: 92, alignment: .trailing)
                        .accessibilityLabel("Flies with \(organisation)")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity)
        }
    }

    /// The one coloured thing in the window, and the reason for the colour is
    /// in `IFGrade`.
    private func gradeBadge(_ grade: IFGrade) -> some View {
        let tint = grade.colour(isLight: theme.isLight)

        return VStack(spacing: 0) {
            Text("GRADE")
                .font(.system(size: 7, weight: .black))
                .tracking(0.8)
                .foregroundStyle(tint.opacity(0.85))

            Text("\(grade.rawValue)")
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .motionWords(grade.rawValue)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(theme.isLight ? 0.12 : 0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.42), lineWidth: 1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(grade.label). \(grade.detail)")
    }

    // MARK: - What is behind it

    /// The pilot's banner, under a veil that makes the type on it readable.
    ///
    /// The veil is not decoration. A banner is a photograph somebody chose for
    /// its own sake, at a contrast nobody picked with white text in mind, and
    /// the name on this card has to be legible over every one of them — a
    /// snowfield included. So the picture is dimmed to a backdrop rather than
    /// shown as a picture; the place to look at somebody's banner properly is
    /// their profile, which is one tap away from here.
    @ViewBuilder
    private var backdrop: some View {
        if wearsBanner {
            ZStack {
                // The painting first and always. It is what a free profile's
                // banner IS, and it is also what a Pro one's photograph loads
                // over — so there is never a grey rectangle where the backdrop
                // goes while a picture is on its way.
                paintedBanner.gradient

                if let image = banner.image {
                    // Laid into a shape that has already agreed to the card's
                    // size, rather than sized directly.
                    //
                    // `scaledToFill` does not merely draw outside its frame, it
                    // *reports* the bigger size — that is what filling means —
                    // and a background is not clipped to the view it is behind.
                    // So the ZStack grew to whatever the photograph wanted, the
                    // rounded rect went round that, and the banner stood a
                    // couple of hundred points proud of the card on every side,
                    // out over the tiles underneath. `Color.clear` takes the
                    // size it is offered and nothing else; the picture fills
                    // that and `clipped()` throws away the overflow, so what
                    // the ZStack reports is the card's own size again.
                    Color.clear
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .transition(.opacity)
                }

                Rectangle().fill(.black.opacity(0.42))
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .motion(Motion.content, value: banner.image != nil)
            .onAppear { banner.load(profile?.bannerURL) }
            .onChange(of: profile?.bannerURL) { _, new in banner.load(new) }
            .allowsHitTesting(false)
        }
    }

    /// The gradient under whatever photograph there is. The pilot's own choice
    /// where there is a profile; the preview's where there is not.
    private var paintedBanner: BannerPreset {
        if let profile { return BannerPreset.resolved(profile.bannerPreset) }
        return stubBanner ?? .dusk
    }

    /// Ink for the version of this card that is drawn over a photograph.
    ///
    /// Fixed white rather than the theme's, in both light and dark. The veil
    /// above is always dark, so the ground under this type is always dark —
    /// following the app's light palette here would put grey text on a dark
    /// photograph, which is the one combination that does not read.
    private var overlayInk: Color { .white }
    private var overlayDim: Color { .white.opacity(0.72) }

    // MARK: - Words

    /// The name on the aeroplane, always. Not the profile's display name.
    ///
    /// This is the identifier — the thing you would search for, the thing
    /// written on the aircraft, the thing every other pilot on the server sees
    /// — and it plays the part the ICAO code plays on the place card. The
    /// display name somebody chose is the quieter line under it.
    private var name: String { pilot ?? "Unknown pilot" }

    /// The profile's own display name, when there is one and it says something
    /// the line above did not.
    private var profileName: String? {
        guard let profile else { return nil }
        let display = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty, display.lowercased() != name.lowercased() else { return nil }
        return display
    }

    // MARK: - Work

    private func resolveProfile() async {
        guard stub == nil else { return }
        profile = nil
        guard let pilot else { return }
        profile = await PilotDirectory.shared.card(ifUsername: pilot)
    }

    private func resolveStats() async {
        if let stub {
            stats = stub
            return
        }
        stats = nil
        guard pilot != nil else { return }
        stats = await PilotStatsService.shared.stats(for: flight)
    }
}
