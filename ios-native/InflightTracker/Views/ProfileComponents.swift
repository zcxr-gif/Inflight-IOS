import SwiftUI

/// A pilot, somewhere in the app that is not their own profile.
///
/// Everywhere a person appears — a friends list, a search result, the strip of
/// friends on somebody's profile — they appear like this. One type rather than
/// four near-identical rows, because the day the Pro badge moves or the avatar
/// gains a ring, it should move everywhere at once.
struct ProfileLink: Identifiable, Equatable, Hashable {

    /// How the profile is being asked for.
    ///
    /// Two, because there are two things people arrive with. A handle is the
    /// profile's own name and resolves exactly. An Infinite Flight name is what
    /// is written on an aeroplane, and resolving it is the whole point of the
    /// feature — but it may well find nothing, since most pilots on the server
    /// have never claimed a profile here. Carrying the difference means the
    /// view can say "hasn't set one up" rather than "no such handle".
    enum Kind: Hashable {
        case handle
        case ifUsername
    }

    let value: String
    var kind: Kind = .handle

    var id: String { "\(kind)|\(value.lowercased())" }

    static func handle(_ handle: String) -> ProfileLink {
        ProfileLink(value: handle, kind: .handle)
    }

    /// The name on an aeroplane.
    static func pilot(_ ifUsername: String) -> ProfileLink {
        ProfileLink(value: ifUsername, kind: .ifUsername)
    }
}

/// The picture, or the initials.
///
/// Circular, and sized by the caller, because the same avatar is a 28pt row
/// glyph, a 44pt strip item and a 96pt profile header. The Pro ring is drawn
/// here so it cannot be forgotten at one of the three.
struct PilotAvatar: View {

    let url: URL?
    let initials: String
    var side: CGFloat = 44
    var isPro: Bool = false

    /// The pilot's own colour, when they are Pro and have picked one. Falls
    /// back to the app's accent, so this is safe to pass nil for everybody
    /// else.
    var tint: Color? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @StateObject private var loader = RemoteImageLoader()

    private var theme: FlightInfoTheme { appearance.theme }
    private var accent: Color { tint ?? theme.accent }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Initials on the accent rather than a grey silhouette: a
                // profile with no picture should still look like somebody
                // rather than like a missing asset.
                Text(initials)
                    .font(.system(size: side * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { accent }
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(
                isPro ? accent : theme.stroke,
                lineWidth: isPro ? max(side * 0.045, 1.5) : 1
            )
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, new in loader.load(new) }
    }
}

/// The strip across the top of a profile.
///
/// A photograph for a Pro account, one of the painted gradients for everybody
/// else. Everybody gets a banner — a profile with a grey rectangle where the
/// picture goes looks broken rather than free, and "yours is a painting, theirs
/// is a photograph" is a far easier difference to explain than an absence.
struct PilotBanner: View {

    let url: URL?
    let preset: BannerPreset
    var height: CGFloat = 132

    /// Whether the banner moves. Pro.
    ///
    /// Motion rather than a different picture, because the thing being sold is
    /// the same banner everybody has, alive. A painted preset gets a band of
    /// light crossing it and a slow bloom drifting the other way; a photograph
    /// gets the gentlest push in and out. All of it is slow enough to be
    /// noticed rather than watched — a banner that demands attention is a
    /// banner nobody can read a name in front of.
    var isAnimated: Bool = false

    @StateObject private var loader = RemoteImageLoader()

    /// Somebody who has asked the system for less movement gets none, Pro or
    /// not. This is decoration; it is the first thing that should go.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two, at different periods and in opposite directions, so they never line
    /// up into one obvious sweep.
    @State private var sheen = false
    @State private var bloom = false

    private var moves: Bool { isAnimated && !reduceMotion }

    var body: some View {
        ZStack {
            preset.gradient

            // Only under a painted banner. With a photograph over the top the
            // sheen is invisible, and invisible animation is still animation.
            if moves, loader.image == nil { light }

            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // A banner is 5:1 and a photograph rarely is, so it is
                    // filled and cropped rather than letterboxed — the top of
                    // the frame, because that is where the sky is.
                    //
                    // Both dimensions, and that is the whole point. Constraining
                    // only the height left the width to `scaledToFill`, which
                    // sizes to the image's own aspect: a wide photograph became
                    // a banner wider than the phone, the header stack took that
                    // width, and the profile's own `containerRelativeFrame`
                    // centred the overspill — which is what pushed the avatar
                    // off the left edge of the screen. Same trap, and the same
                    // fix, as `AircraftPhotoImage`.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The photograph's own motion: a push in and out, slow
                    // enough that you cannot catch it starting. It only ever
                    // scales *up*, so the frame stays covered.
                    .scaleEffect(moves && bloom ? 1.055 : 1)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .animation(.easeOut(duration: 0.25), value: loader.image != nil)
        .onAppear {
            loader.load(url)
            start()
        }
        .onChange(of: url) { _, new in loader.load(new) }
        // Turning Pro on, or Reduce Motion off, starts it without a redraw of
        // the whole profile — and the guard inside means turning either off
        // simply leaves the values where they are, which is where they belong.
        .onChange(of: moves) { _, _ in start() }
    }

    /// What crosses a painted banner.
    ///
    /// Drawn additively over the gradient rather than as its own colour: the
    /// six presets are six different palettes, and a highlight that knows what
    /// is underneath it is one that suits all of them. Sized from the geometry
    /// so it reads the same on a 76pt strip in the editor and a 148pt header.
    private var light: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)

            ZStack {
                // The band. Tilted, because a highlight travelling square
                // across a rectangle reads as a wipe rather than as light.
                LinearGradient(
                    colors: [.clear, .white.opacity(0.20), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 0.42)
                .rotationEffect(.degrees(14))
                .blur(radius: 10)
                .offset(x: sheen ? width * 0.8 : -width * 0.8)

                // The bloom, going the other way and taking longer about it.
                RadialGradient(
                    colors: [.white.opacity(0.15), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: width * 0.22
                )
                .frame(width: width * 0.5, height: width * 0.5)
                .blur(radius: 16)
                .offset(x: bloom ? -width * 0.26 : width * 0.26,
                        y: bloom ? 10 : -10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func start() {
        guard moves else { return }

        // Back to the start, unanimated, before the loop is attached. Without
        // this a second call is a no-op — the flags are already true, setting
        // them to true again animates nothing — so motion switched off and on
        // again would never come back.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            sheen = false
            bloom = false
        }

        // Two periods that do not divide into each other, so the pair takes a
        // long time to repeat the same arrangement.
        withAnimation(.easeInOut(duration: 6.5).repeatForever(autoreverses: true)) {
            sheen = true
        }
        withAnimation(.easeInOut(duration: 10.5).repeatForever(autoreverses: true)) {
            bloom = true
        }
    }
}

/// "PRO", where somebody has one.
struct ProBadge: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    var body: some View {
        Text("PRO")
            .font(.system(size: 8.5, weight: .black))
            .tracking(0.8)
            .foregroundStyle(appearance.theme.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background { Capsule().fill(appearance.theme.accent) }
            .accessibilityLabel("Inflight Pro")
    }
}

/// One pilot in a list.
struct PilotRow: View {

    let pilot: PilotSummary

    /// Set when the live feed can see this pilot right now. The whole reason a
    /// friends list is worth having on a tracker rather than on any other kind
    /// of app.
    var isFlying: Bool = false

    let onOpen: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                PilotAvatar(
                    url: pilot.avatarURL,
                    initials: pilot.initials,
                    side: 38,
                    isPro: pilot.isPro,
                    tint: pilot.accentColor
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(pilot.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.8)

                        if pilot.isPro { ProBadge() }
                    }

                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.8)
                }

                Spacer(minLength: 6)

                if isFlying {
                    HStack(spacing: 4) {
                        Circle().fill(theme.accent).frame(width: 6, height: 6)
                        Text("FLYING")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The handle, plus whichever of the two optional facts they have filled
    /// in. Written as a sentence rather than a table because a row is read at a
    /// glance and three labelled fields is not a glance.
    private var detail: String {
        var parts = ["@\(pilot.handle)"]
        if let aircraft = pilot.favouriteAircraft, !aircraft.isEmpty { parts.append(aircraft) }
        if let home = pilot.homeAirport, !home.isEmpty { parts.append(home) }
        return parts.joined(separator: " · ")
    }
}

/// A horizontal run of avatars — the friends strip on a profile.
///
/// Faces rather than a list, because the question it answers is "who does this
/// person fly with" and a face answers it faster than a name does. Tapping one
/// opens them, which is what makes the graph something you can walk.
struct PilotStrip: View {

    let pilots: [PilotSummary]
    let onOpen: (String) -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(pilots) { pilot in
                    Button { onOpen(pilot.handle) } label: {
                        VStack(spacing: 5) {
                            PilotAvatar(
                                url: pilot.avatarURL,
                                initials: pilot.initials,
                                side: 46,
                                isPro: pilot.isPro,
                                tint: pilot.accentColor
                            )
                            Text(pilot.displayName)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .frame(width: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        // The strip scrolls sideways on purpose, so it must not also be able to
        // drag the panel it sits in.
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A number with a word under it — flights, hours, followers.
struct PilotStat: View {

    let value: String
    let label: String
    var action: (() -> Void)? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// One badge on the shelf.
///
/// Earned ones read at full strength; the rest are dimmed with their progress
/// under them, because a profile that shows what somebody is 40 flights away
/// from is more interesting than one that shows only what they have already
/// done.
struct BadgeChip: View {

    let badge: PilotBadge

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(badge.earned ? theme.accent : theme.surfaceFill)
                    .frame(width: 44, height: 44)

                if !badge.earned {
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                }

                Image(systemName: badge.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(badge.earned ? theme.onAccent : theme.textDim)
            }

            Text(badge.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(badge.earned ? theme.textSecondary : theme.textDim)
                .lineLimit(1)

            if !badge.earned {
                Text("\(badge.progress)/\(badge.target)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(width: 74)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            badge.earned
                ? "\(badge.title), earned. \(badge.detail)"
                : "\(badge.title), \(badge.progress) of \(badge.target). \(badge.detail)"
        )
    }
}

/// One flight out of a logbook.
struct LogbookRow: View {

    let entry: LogbookEntry

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.route)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.8)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.blockTime)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)

                Text(Self.day.string(from: entry.landedAt))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let aircraft = entry.aircraft, !aircraft.isEmpty { parts.append(aircraft) }
        if let distance = entry.distanceNm, distance > 0 {
            parts.append("\(Format.number(Double(distance))) nm")
        }
        if let callsign = entry.callsign, !callsign.isEmpty { parts.append(callsign) }
        return parts.isEmpty ? "Flight" : parts.joined(separator: " · ")
    }
}

// MARK: - The pilot, on a flight

/// The face behind a name on the map.
///
/// Every aeroplane in the feed carries its pilot's Infinite Flight handle, and
/// until now that was where it stopped: a string. This resolves the handle to a
/// profile and draws the picture, which is the whole point of profiles existing
/// — a name on the map leading to a person.
///
/// ## Why it resolves itself
///
/// Most pilots on the server have never claimed a handle here, so most lookups
/// find nothing. `PilotDirectory` caches the misses as well as the hits, which
/// is the half that matters: without it, tapping the same aeroplane twice would
/// ask the server twice to be told "no" twice. Because the miss is cheap and
/// cached, this can be dropped into any row that shows a pilot's name without
/// the caller having to think about it.
///
/// ## What it shows when there is nothing to show
///
/// The same small person glyph the flight window used before. A pilot with no
/// profile should look ordinary, not broken — and certainly not like an
/// advert for signing up, on a window they opened to look at an aeroplane.
struct FlightPilotBadge: View {

    /// The Infinite Flight handle written on the aeroplane.
    let username: String?

    var side: CGFloat = 20
    var nameSize: CGFloat = 11

    /// Whether tapping opens the profile. Off in the peak bar, whose own tap
    /// expands the window — two things on one tap is one too many.
    var isTappable: Bool = true

    /// Whether a Pro pilot is marked as one.
    ///
    /// Opt-in rather than always. The flight window has a line to itself for
    /// the pilot and room for the chip; the peak bar is one strip carrying a
    /// name, a state and a phase, and a fourth thing there costs the name the
    /// width it needs. Off by default so the cramped case is the one that has
    /// to say nothing.
    var showsPro: Bool = false

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @State private var profile: PilotProfile?
    @State private var opened: ProfileLink?

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        content
            .task(id: username) { await resolve() }
            .sheet(item: $opened) { link in PublicProfileView(link: link) }
    }

    @ViewBuilder
    private var content: some View {
        if isTappable, profile != nil {
            Button {
                guard let handle = profile?.handle else { return }
                opened = .handle(handle)
            } label: { row }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if let profile {
                PilotAvatar(
                    url: profile.avatarURL,
                    initials: profile.initials,
                    side: side,
                    isPro: profile.isPro,
                    tint: profile.accentColor
                )
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textDim)
            }

            Text(displayed)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine()

            // The same mark the profile carries, on the aeroplane. Pro is the
            // one thing about anybody's billing that is ever public, and a
            // badge only its owner ever sees is not a badge.
            if showsPro, profile?.isPro == true {
                ProBadge()
                    .fixedSize()
            }

            // A claimed profile is worth marking, because the name on the map
            // is otherwise identical whether somebody is here or not. Small,
            // and never in place of the name.
            if profile != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
        }
    }

    /// The profile's own display name once there is one, because that is what
    /// the pilot chose to be called. The map's handle until then.
    private var displayed: String {
        if let profile, !profile.displayName.isEmpty { return profile.displayName }
        return username ?? "Pilot"
    }

    private func resolve() async {
        profile = nil
        guard let username, !username.isEmpty else { return }
        profile = await PilotDirectory.shared.card(ifUsername: username)
    }
}
