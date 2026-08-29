import SwiftUI

/// Who the platform is watching, on a card you pull open.
///
/// The stats panel is otherwise a count of the packet the map is drawn from —
/// aeroplanes, altitudes, fields. This is the one section about people, and it
/// is the only thing in the panel that costs a request, so it is shut until it
/// is asked for: closed it is one line naming the most followed pilot, and a
/// pull on the grabber turns it into the board behind that line.
///
/// It is a card rather than a `PanelSection` for exactly that reason. A section
/// is a titled group of rows that is always open; this has two states, a
/// gesture, and a picker of its own, and dressing it as a section would have
/// meant a section header sitting above a second header doing the real work.
///
/// ## What "watched" counts
///
/// Followers of an Inflight profile, counted on the server. Deliberately *not*
/// the watchlist in the friends panel: that list is a dozen Infinite Flight
/// names held on one phone under an APNs token, it is nobody's business but
/// that phone's, and aggregating it into a public ranking would be a promise
/// broken. The footer says so, because the two are easy to confuse when the
/// word on both is "watching".
struct MostWatchedCard: View {

    /// Opening a pilot from a row. The sheet belongs to the panel — a profile
    /// needs the live feed to offer "show me this aeroplane", and this card
    /// has no business holding one.
    let onOpen: (ProfileLink) -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var isOpen = false
    @State private var scope: MostWatchedPilot.Scope = .all
    @State private var pilots: [MostWatchedPilot] = []
    @State private var isLoading = true

    /// How far the grabber has been pulled, while a finger is on it. A gesture
    /// state rather than plain state so it returns to nought by itself if the
    /// gesture is cancelled — a grabber left hanging half-pulled by a phone
    /// call is worse than one that never moved.
    @GestureState private var pull: CGFloat = 0

    @Namespace private var chipSpace

    private var theme: FlightInfoTheme { appearance.theme }

    /// How far a drag has to travel before it counts as a pull. Short, because
    /// a tap anywhere on the grabber does the same thing — this only has to
    /// separate a pull from a jitter.
    private static let pullThreshold: CGFloat = 14

    private static let boardLimit = 10

    /// The window the rising board is ranked on. Named here as well as
    /// defaulted on the server, because the copy on the tab says "this week"
    /// and the two have to agree.
    private static let windowDays = 7

    var body: some View {
        VStack(spacing: 0) {
            grabber

            if isOpen {
                opened
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                closed
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 28 rather than `radiusLarge`. Every other surface in the panel is a
        // card sitting on the window; this one is meant to read as a sheet
        // somebody has pulled up, and the corner is most of what says so.
        .flightInfoSurface(theme, radius: 28)
        // The board is asked for once when the panel opens and again whenever
        // the tab changes, and never on a redraw. Closed, the same answer is
        // what names the pilot on the one visible line, so there is nothing to
        // defer by waiting for the pull.
        .task(id: scope) { await load() }
    }

    // MARK: - The grabber

    /// The whole affordance. Pull it down to open the board, up to shut it,
    /// or tap it for either.
    ///
    /// Down opens because the board appears *below* this line: a grabber that
    /// opened upwards would be pulling the content away from the direction it
    /// arrives from. That is the opposite of the sheet handle it looks like,
    /// and it is the right way round for a card that grows down a page.
    private var grabber: some View {
        Capsule()
            .fill(theme.textDim)
            .frame(width: 52, height: 5)
            .opacity(isOpen ? 0.6 : 0.95)
            .offset(y: pull)
            .frame(maxWidth: .infinity)
            .padding(.top, 13)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .onTapGesture { setOpen(!isOpen) }
            .gesture(pullGesture)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isOpen ? "Hide the most watched board" : "Show the most watched board")
            .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($pull) { value, state, _ in
                // Damped, and only in the direction that would do something. A
                // grabber that follows a finger pulling the useless way is
                // telling that finger something is about to happen.
                let travelled = value.translation.height
                let useful = isOpen ? min(travelled, 0) : max(travelled, 0)
                state = useful / 3.5
            }
            .onEnded { value in
                let travelled = value.translation.height
                if travelled > Self.pullThreshold { setOpen(true) }
                if travelled < -Self.pullThreshold { setOpen(false) }
            }
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isOpen = open }
    }

    // MARK: - Shut

    /// One line: who is top, and how many people that is. Tappable, because
    /// somebody who has just read it wants the rest.
    private var closed: some View {
        Button { setOpen(true) } label: {
            HStack(spacing: 11) {
                if let leader = pilots.first {
                    PilotAvatar(
                        url: leader.avatarURL,
                        initials: leader.initials,
                        side: 38,
                        isPro: leader.isPro
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        caption("MOST WATCHED")

                        HStack(spacing: 5) {
                            Text(leader.displayName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                                .flightInfoLine(minimumScale: 0.7)

                            if leader.isPro { proSeal }
                            if leader.isFlying { flyingChip }
                        }
                    }

                    Spacer(minLength: 6)

                    count(weight(leader))
                } else {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 38, height: 38)
                        .background { Circle().fill(theme.elevatedFill) }

                    VStack(alignment: .leading, spacing: 3) {
                        caption("MOST WATCHED")

                        Text(isLoading ? "Counting…" : "Nobody has been followed yet")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .flightInfoLine(minimumScale: 0.7)
                    }

                    Spacer(minLength: 6)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the most watched board")
    }

    // MARK: - Pulled out

    private var opened: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tabs

            Text(scope.standfirst)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            board

            Text("Counted from the pilots people follow on Inflight. Not from the "
               + "watchlist on this phone — that list never leaves it.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textSecondary)

            caption("MOST WATCHED")

            Spacer(minLength: 6)

            Button { setOpen(false) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textDim)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide the most watched board")
        }
        .padding(.horizontal, 16)
    }

    /// The three scopes, as one segmented control.
    ///
    /// Written by hand rather than as a `Picker(.segmented)`, which carries no
    /// glyphs and sizes its own type — and glyph over label, at a size you can
    /// actually see, is the whole shape of this control.
    ///
    /// A stadium rather than a rounded rectangle, hairline-outlined, with the
    /// picked segment on a filled capsule inside it. Roomy on purpose: this is
    /// the first thing under the grabber and the thing a thumb goes for, and a
    /// row of 10pt labels is neither.
    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(MostWatchedPilot.Scope.allCases) { option in
                tab(option)
            }
        }
        .padding(5)
        .background { Capsule().strokeBorder(theme.stroke, lineWidth: 1) }
        .padding(.horizontal, 12)
    }

    /// The one colour on this card, and the only one in the app's chrome.
    ///
    /// The window is monochrome by design and stays that way; a segmented
    /// control is the exception that earns it, because "which of these three am
    /// I looking at" is answered by colour instantly and by a slightly lighter
    /// grey only after a hunt. iOS's own system blue, in both its values, so it
    /// sits the way the system's controls do rather than like a colour we
    /// invented.
    private var pick: Color {
        theme.isLight
            ? Color(red: 0.0, green: 0.478, blue: 1.0)
            : Color(red: 0.039, green: 0.518, blue: 1.0)
    }

    private func tab(_ option: MostWatchedPilot.Scope) -> some View {
        let isPicked = option == scope

        return Button {
            guard !isPicked else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { scope = option }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    // Fixed, so a tall glyph and a wide one sit on the same
                    // line and the three labels agree on where they start.
                    .frame(height: 24)

                Text(option.label)
                    .font(.system(size: 12.5, weight: .bold))
                    .flightInfoLine(minimumScale: 0.6)
            }
            // Unpicked is full-strength white, not a dimmed grey: these are
            // three live choices, and two of them greyed out reads as two of
            // them disabled.
            .foregroundStyle(isPicked ? pick : theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                // Only the picked tab draws the chip, and it is the same chip
                // moving rather than one fading out while another fades in —
                // which is what makes the control read as one control.
                if isPicked {
                    Capsule()
                        .fill(theme.elevatedFill)
                        .matchedGeometryEffect(id: "mostWatchedTab", in: chipSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    @ViewBuilder
    private var board: some View {
        if isLoading && pilots.isEmpty {
            note("Counting…")
        } else if pilots.isEmpty {
            note(scope.emptyDetail)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(pilots.enumerated()), id: \.element.id) { index, pilot in
                    if index > 0 { PanelDivider() }
                    row(pilot, place: index + 1)
                }
            }
        }
    }

    /// The number this board is ranked on, which is the whole difference
    /// between the tabs. Read here rather than in three places, so the bar
    /// under a row can never measure something other than the order.
    private func weight(_ pilot: MostWatchedPilot) -> Int {
        scope == .rising ? pilot.newFollowers : pilot.followerCount
    }

    private func row(_ pilot: MostWatchedPilot, place: Int) -> some View {
        Button { onOpen(.handle(pilot.handle)) } label: {
            HStack(spacing: 12) {
                Text("\(place)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(place <= 3 ? theme.textPrimary : theme.textDim)
                    .frame(width: 18, alignment: .trailing)

                PilotAvatar(
                    url: pilot.avatarURL,
                    initials: pilot.initials,
                    side: 38,
                    isPro: pilot.isPro
                )

                VStack(alignment: .leading, spacing: 3) {
                    nameLine(pilot)

                    Text(detail(for: pilot))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine(minimumScale: 0.7)
                }

                Spacer(minLength: 6)

                count(weight(pilot))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(place). \(pilot.displayName), \(weight(pilot))"
            + (scope == .rising ? " new followers this week" : " watching")
        )
        .accessibilityHint("Opens their profile")
    }

    /// The name, and every badge that is true of this pilot. Split out of the
    /// row rather than written inline: a `HStack` of four conditional views
    /// inside a `Button` inside a `VStack` is the kind of expression the Swift
    /// type-checker gives up on, and the failure it gives up with names none
    /// of them.
    private func nameLine(_ pilot: MostWatchedPilot) -> some View {
        HStack(spacing: 5) {
            Text(pilot.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)

            if pilot.isPro { proSeal }

            if pilot.isSelf {
                mark("YOU")
            } else if pilot.viewerFollows {
                mark("FOLLOWING")
            }

            if pilot.isFlying { flyingChip }
        }
    }

    /// The line under a name. Everything true about this pilot that is worth a
    /// row of its own, and nothing that is not: an empty string never appears,
    /// because the fallback is the one thing the board is always able to say.
    private func detail(for pilot: MostWatchedPilot) -> String {
        var parts: [String] = []

        if let username = pilot.ifUsername, !username.isEmpty {
            parts.append(username)
        }

        // On the rising board the total is the context; everywhere else the
        // week is. Saying both on both would be the same two numbers twice.
        if scope == .rising {
            parts.append("\(pilot.followerCount) in total")
        } else if pilot.newFollowers > 0 {
            parts.append("+\(pilot.newFollowers) this week")
        }

        return parts.isEmpty ? "On Inflight" : parts.joined(separator: " · ")
    }

    // MARK: - Small parts

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1)
            .foregroundStyle(theme.textDim)
    }

    /// The count on the right of a row, labelled by what the board is counting
    /// so the number under "This week" is never read as a lifetime total.
    private func count(_ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Format.number(Double(value)))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()

            Text(scope == .rising ? "THIS WEEK" : "WATCHING")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .fixedSize()
        }
    }

    private var proSeal: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 11))
            .foregroundStyle(pick)
    }

    private var flyingChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "airplane")
                .font(.system(size: 7, weight: .bold))
            Text("FLYING")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(pick)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(pick.opacity(0.18)))
    }

    private func mark(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(pick)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(pick.opacity(0.18)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }

    // MARK: - Reading

    private func load() async {
        isLoading = true
        // Emptied rather than left in place, because the only thing that starts
        // a second load is a change of tab: the rows on screen are ranked by a
        // number this board is no longer ranked on, and leaving them up for the
        // length of a round trip means showing an order that is wrong.
        pilots = []
        let found = await PilotDirectory.shared.mostWatched(
            scope: scope,
            windowDays: Self.windowDays,
            limit: Self.boardLimit
        )
        // Animated because this lands under an open card as often as not, and
        // a board that appears a row at a time reads as arriving rather than
        // as the panel jumping.
        withAnimation(.easeOut(duration: 0.2)) {
            pilots = found
            isLoading = false
        }
    }
}
