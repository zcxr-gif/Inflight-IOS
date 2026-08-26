import SwiftUI
import UIKit

/// Pieces shared by the peak state and the expanded window, so the two phases
/// can't drift apart as either one is worked on.

// MARK: - Phase chip

/// Flight phase as a neutral pill: a dot and the phase name, no colour coding.
struct FlightPhaseChip: View {

    let phase: FlightPhase
    let theme: FlightInfoTheme
    var elevated: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(theme.phaseAccent(for: phase))
                .frame(width: 5, height: 5)

            Text(phase.rawValue)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .flightInfoSurface(theme, radius: 99, elevated: elevated)
        // Never allowed to shrink: it sits next to a callsign that may be long,
        // and the callsign is the piece that gives way.
        .fixedSize()
    }
}

/// What the pilot is doing, as a pill beside their name.
///
/// The phase chip says what the aircraft is doing; this says whether anyone is
/// flying it. Both are needed: an airframe at cruise reads identically whether
/// it is being hand-flown or sitting on autopilot with nobody watching.
struct PilotStateChip: View {

    let state: PilotState
    let theme: FlightInfoTheme
    var elevated: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.system(size: 7.5, weight: .semibold))

            Text(state.label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(theme.pilotStateAccent(for: state))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .flightInfoSurface(theme, radius: 99, elevated: elevated)
        // Never allowed to shrink: it sits beside a username of arbitrary
        // length, and the username is the piece that gives way.
        .fixedSize()
        .accessibilityLabel("\(state.label). \(state.detail)")
    }
}

// MARK: - Controlled marker

/// Somebody is on frequency here.
///
/// Shared by the airports board and the route card so that "controlled" looks
/// like one thing wherever a field is named. Filled with the accent rather than
/// outlined: in a monochrome window this is the one state worth spending the
/// accent on, because it is the difference between a field you can be talked
/// into and one you cannot.
struct AtcOnlineBadge: View {

    let theme: FlightInfoTheme

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background { Capsule().fill(theme.accent) }
            .accessibilityLabel("Controlled")
    }
}

// MARK: - Route

/// The route card, shared by both phases: endpoints, then the progress bar
/// full width as the divider between them and what has been flown, then the
/// aircraft it is being flown in.
struct RouteCard: View {

    let flight: Flight
    let progress: FlightProgress?
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 24
    var inset: CGFloat = 14

    /// Opens one end of the route as a field of its own.
    ///
    /// Optional because the peak state uses this same card and must not become
    /// tappable: the whole peak is a drag target, and endpoints that could
    /// swallow a drag as a tap would make the window hard to open.
    var onSelectAirport: ((Airport) -> Void)? = nil

    /// Fields with somebody on frequency, so an end of the route can say so.
    ///
    /// Passed in rather than read from the feed here: this card is drawn in the
    /// peak state too, and a component that reached for the feed itself would
    /// re-render both phases on every ATC packet. The peak leaves it empty on
    /// purpose — it is the glance, and this is a detail you open the window for.
    var controlledFields: Set<String> = []

    var body: some View {
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                port(icao: flight.departureIcao, alignment: .leading)
                port(icao: flight.arrivalIcao, alignment: .trailing)
            }

            // Full width, and doing the divider's job: endpoints above, what
            // has actually been flown below.
            RouteTrack(fraction: progress?.fraction ?? 0, theme: theme)

            if let progress = progress {
                HStack(spacing: 8) {
                    MiniStat(
                        label: "FLOWN",
                        value: "\(Format.number(progress.flownNM)) NM",
                        theme: theme
                    )
                    MiniStat(
                        label: "REMAINING",
                        value: "\(Format.number(progress.remainingNM)) NM",
                        theme: theme,
                        alignment: .center
                    )
                    MiniStat(
                        label: "ETE",
                        value: eteLabel,
                        theme: theme,
                        alignment: .trailing
                    )
                }
            }

            Text(aircraftLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .frame(maxWidth: .infinity)
        }
        .padding(inset)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var aircraftLine: String {
        let parts = [flight.aircraftName, flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown aircraft" : parts.joined(separator: " · ")
    }

    private var eteLabel: String {
        guard let ete = progress?.estimatedTimeEnroute(groundSpeedKnots: flight.groundSpeedKnots) else {
            return "—"
        }
        return Format.duration(ete)
    }

    @ViewBuilder
    private func port(icao: String?, alignment: HorizontalAlignment) -> some View {
        let airport = AirportStore.shared.airport(icao)

        // Tappable only where there is a field behind the code to open. A route
        // filed to an ICAO the dataset has never heard of still draws — it just
        // isn't a button.
        if let airport = airport, let onSelectAirport = onSelectAirport {
            Button {
                onSelectAirport(airport)
            } label: {
                portLabel(icao: icao, airport: airport, alignment: alignment, isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(airport.icao), \(airport.name). Open this airport.")
        } else {
            portLabel(icao: icao, airport: airport, alignment: alignment, isLink: false)
        }
    }

    private func portLabel(
        icao: String?,
        airport: Airport?,
        alignment: HorizontalAlignment,
        isLink: Bool
    ) -> some View {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let frameAlignment: Alignment = alignment == .leading ? .leading : .trailing
        let isControlled = airport.map { controlledFields.contains($0.icao) } ?? false

        return VStack(alignment: alignment, spacing: 4) {
            // Against the code rather than down with the airport's name: "is my
            // destination controlled" is a question about the field, and the
            // name line is already carrying a flag and a chevron.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(code.isEmpty ? "———" : code)
                    .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)

                if isControlled { AtcOnlineBadge(theme: theme) }
            }

            HStack(spacing: 4) {
                if let flag = airport?.flag, !flag.isEmpty {
                    Text(flag).font(.system(size: 9))
                }
                Text((airport?.name ?? "Unknown").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)

                // The only mark that either end goes anywhere. Sits after the
                // name on both sides rather than mirroring, so the two
                // endpoints read as the same kind of thing rather than as a
                // pair pointing at each other.
                if isLink {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        // Each endpoint takes half the row, so a long airport name can only
        // shrink, never widen the card.
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .contentShape(Rectangle())
    }
}

/// The progress track: filled to `fraction`, with the plane riding the head of
/// the fill. Endpoint dots match the web tracker — filled at the origin, hollow
/// at the destination.
struct RouteTrack: View {

    let fraction: Double
    let theme: FlightInfoTheme
    var planeSize: CGFloat = 11

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.trackFill)
                    .frame(height: 3)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, width * clamped), height: 3)

                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)

                Circle()
                    .strokeBorder(theme.trackFill, lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .offset(x: max(0, width - 6))

                Image(systemName: "airplane")
                    .font(.system(size: planeSize, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    // Kept inside the track so the glyph never clips the card.
                    .offset(x: min(max(0, width * clamped - planeSize / 2), max(0, width - planeSize)))
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
        .frame(height: planeSize + 3)
    }
}

/// Where an aircraft is when there is no route to draw — parked at a gate,
/// taxiing, or airborne with no destination filed.
struct PlaceCard: View {

    let kicker: String
    let symbol: String
    let airport: Airport?
    let theme: FlightInfoTheme
    var icaoSize: CGFloat = 22

    /// Opens the field this card names. Optional for the same reason the route
    /// card's is — the peak state draws this too, and everything in the peak
    /// belongs to the drag.
    var onSelectAirport: ((Airport) -> Void)? = nil

    /// Fields with somebody on frequency — see `RouteCard.controlledFields`.
    var controlledFields: Set<String> = []

    var body: some View {
        if let airport = airport, let onSelectAirport = onSelectAirport {
            Button {
                onSelectAirport(airport)
            } label: {
                card(isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kicker) \(airport.icao), \(airport.name). Open this airport.")
        } else {
            card(isLink: false)
        }
    }

    private func card(isLink: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: icaoSize * 0.52, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .frame(width: icaoSize * 1.7, height: icaoSize * 1.7)
                .background(Circle().fill(theme.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(kicker)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(airport?.icao ?? "———")
                        .font(.system(size: icaoSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    if let airport = airport, controlledFields.contains(airport.icao) {
                        AtcOnlineBadge(theme: theme)
                    }
                }

                HStack(spacing: 4) {
                    if let flag = airport?.flag, !flag.isEmpty {
                        Text(flag).font(.system(size: 9))
                    }
                    Text((airport?.name ?? "Position unknown").uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLink {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Hero

/// The photo header, shared by the full window and the photo peak state.
///
/// Both draw it at the same size from the same rules, so dragging the window
/// open grows what is already on screen instead of swapping one header for
/// another.
struct FlightHero: View {

    /// The first photograph, already loaded by the window. It sets the
    /// header's height and fills the first page without waiting.
    let image: UIImage?

    let spriteKey: String
    let contributor: String?
    let theme: FlightInfoTheme
    let width: CGFloat

    /// Everything the lookup returned for this type and livery.
    ///
    /// Empty for the peak state, which is a preview under a sheet you drag —
    /// a horizontal swipe there is a gesture fighting the window rather than a
    /// gallery. Left empty it draws exactly the single photo it always did.
    var photos: [AircraftPhoto] = []

    @State private var page = 0

    private var isGallery: Bool { photos.count > 1 }

    /// Takes the photo's own shape where it can, so a fitted photo fills the
    /// header edge to edge instead of sitting between blurred bars. Extremes
    /// are clamped — a panoramic shot may not eat the whole sheet.
    ///
    /// Measured from the first photograph even in a gallery: the others are
    /// fitted into the height it sets. A header that resized itself under your
    /// thumb as you paged through shots of different shapes would be a worse
    /// thing than a little letterboxing.
    static func height(for width: CGFloat, image: UIImage?) -> CGFloat {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            return min(max(width * 0.56, 190), 250)
        }

        let ratio = image.size.height / image.size.width
        return min(max(width * ratio, 180), 300)
    }

    var body: some View {
        Group {
            if isGallery {
                TabView(selection: $page) {
                    ForEach(Array(photos.enumerated()), id: \.element.url) { index, photo in
                        HeroPage(
                            photo: photo,
                            // The window has already fetched the first one.
                            preloaded: index == 0 ? image : nil,
                            spriteKey: spriteKey,
                            theme: theme
                        )
                        .tag(index)
                    }
                }
                // The app draws its own, in the theme's ink — the system's dots
                // are white, which disappears on a light window over a pale sky.
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                AircraftPhotoImage(
                    image: image,
                    spriteKey: spriteKey,
                    theme: theme,
                    iconSize: 64,
                    // Airliner photos are wide; filling this frame would cut
                    // the nose and tail off, so the whole airframe is fitted
                    // onto a blurred copy of itself instead.
                    contentMode: .fit
                )
            }
        }
        .frame(width: width, height: Self.height(for: width, image: image))
        .overlay { PhotoScrim(theme: theme) }
        // The photo's own alpha is faded out at the bottom, so it melts into
        // the window's ground rather than ending on a black band.
        .mask { PhotoFadeMask() }
        // Both of these go on after the mask, so neither fades out with the
        // bottom of the photograph.
        .overlay(alignment: .topTrailing) { credit }
        .overlay(alignment: .bottomLeading) { pageDots }
        // A shorter list arriving — another aircraft's photos, or a failed
        // reload — must not leave the playhead past the end of it.
        .onChange(of: photos.count) { _, count in
            if page >= count { page = 0 }
        }
    }

    /// Whoever took the photograph currently on screen.
    private var currentContributor: String? {
        guard isGallery, photos.indices.contains(page) else { return contributor }
        return photos[page].contributor
    }

    @ViewBuilder
    private var credit: some View {
        if let contributor = currentContributor {
            Text("© \(contributor)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .flightInfoSurface(theme, radius: 6, elevated: true)
                .flightInfoLine(minimumScale: 0.8)
                // Clear of the drag indicator, which floats over the photo.
                .frame(maxWidth: 150, alignment: .trailing)
                .padding(.top, 12)
                .padding(.trailing, 12)
                // The credit belongs to the photograph, so it changes with it
                // rather than being replaced under a stationary label.
                .motion(Motion.content, value: currentContributor)
        }
    }

    @ViewBuilder
    private var pageDots: some View {
        if isGallery {
            HStack(spacing: 5) {
                ForEach(photos.indices, id: \.self) { index in
                    Circle()
                        .fill(theme.textPrimary)
                        .opacity(index == page ? 0.9 : 0.3)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .flightInfoSurface(theme, radius: 8, elevated: true)
            .padding(.leading, 12)
            .padding(.bottom, 10)
            .motion(Motion.content, value: page)
            .accessibilityLabel("Photo \(page + 1) of \(photos.count)")
        }
    }
}

/// One photograph in the header's gallery.
///
/// Its own loader, so pages fetch as they are reached rather than all at once
/// — the shared image cache means paging back to one is instant.
private struct HeroPage: View {

    let photo: AircraftPhoto
    let preloaded: UIImage?
    let spriteKey: String
    let theme: FlightInfoTheme

    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        AircraftPhotoImage(
            image: preloaded ?? loader.image,
            spriteKey: spriteKey,
            theme: theme,
            iconSize: 64,
            contentMode: .fit
        )
        .onAppear { if preloaded == nil { loader.load(photo.url) } }
        .onChange(of: photo.url) { _, url in
            if preloaded == nil { loader.load(url) }
        }
    }
}

/// Callsign, phase, pilot and registration. Sits at the seam under the hero.
struct FlightIdentityBlock: View {

    let flight: Flight
    let registration: String
    let theme: FlightInfoTheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(flight.displayName)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)

                    FlightPhaseChip(phase: FlightPhase.from(flight), theme: theme, elevated: true)
                }

                HStack(spacing: 6) {
                    // The pilot's own picture when they have claimed a profile
                    // here, and the plain glyph when they have not. Tappable in
                    // this window, which is the one with room to leave for.
                    FlightPilotBadge(username: flight.username, side: 22)

                    PilotStateChip(state: flight.pilotState, theme: theme, elevated: true)
                }

                // Where the flight is in its day. What it is being flown in
                // lives at the foot of the route card.
                Text(stateLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !registration.isEmpty {
                Text(registration)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .flightInfoSurface(theme, radius: 7, elevated: true)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 2)
    }

    private var stateLine: String {
        let phase = FlightPhase.from(flight)
        let altitude = "\(Format.number(flight.altitudeFeet)) ft"
        let speed = "\(Format.number(flight.groundSpeedKnots)) kts"
        return "\(phase.rawValue.capitalized) · \(altitude) · \(speed)"
    }
}

// MARK: - Aircraft photo

/// Community aircraft photo with the sprite placeholder underneath, so the
/// frame is never empty while the request is in flight.
struct AircraftPhotoImage: View {

    let image: UIImage?
    let spriteKey: String
    let theme: FlightInfoTheme
    var iconSize: CGFloat = 44

    /// `.fit` keeps the whole airframe in frame — a blurred, scaled copy of
    /// the same photo fills what is left, so the frame is still edge to edge
    /// but the nose and tail are never cropped off.
    var contentMode: ContentMode = .fit

    var body: some View {
        ZStack {
            if let image = image {
                if contentMode == .fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 18, opaque: true)
                        // Blur samples past the edges, so oversize the backdrop
                        // rather than letting it fade out at the frame.
                        .scaleEffect(1.2)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                placeholder
            }
        }
        // Fill the frame, then clip: a resizable image reports its own
        // intrinsic size, which would otherwise widen everything around it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(theme.surfaceFill)

            if let icon = PlaneSprites.shared.icon(forKey: spriteKey, selected: false) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .rotationEffect(.degrees(90))
                    .opacity(0.45)
            }
        }
    }
}

/// Dissolves the bottom of the hero photo into whatever the window is sitting
/// on.
///
/// Used as a mask rather than as a black gradient painted on top: a black fade
/// leaves a dark band that belongs to neither the photo nor the window, while
/// fading the photo's own alpha lets the sheet's blur (or the carbon ground)
/// come through and the two blend into each other.
struct PhotoFadeMask: View {

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.58),
                .init(color: .black.opacity(0.55), location: 0.82),
                .init(color: .black.opacity(0.12), location: 0.95),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Just enough shading under the identity block to keep the text over it off a
/// bright sky. Fades out again at the very bottom so it can't reintroduce the
/// band the mask is there to avoid.
///
/// Which way it shades depends on the theme, and it used to be black either
/// way. The text over a photo is the window's own ink — white on the dark
/// themes, near-black on the light ones — so on light this was darkening the
/// photo *and* the top of the window behind the very text it was meant to be
/// helping. White lifts a light theme's photo the way black settles a dark
/// one's, and a little more of it, because a white wash reads softer than a
/// black one at the same opacity.
struct PhotoScrim: View {

    let theme: FlightInfoTheme

    private var shade: Color { theme.isLight ? .white : .black }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: shade.opacity(theme.isLight ? 0.14 : 0.10), location: 0.45),
                .init(color: shade.opacity(theme.isLight ? 0.40 : 0.30), location: 0.78),
                .init(color: shade.opacity(theme.isLight ? 0.14 : 0.10), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Flown path

/// What the flown path looks like from the side.
///
/// Built from the same breadcrumbs the map draws — the backend's history plus
/// live samples — so the window shows the whole climb, cruise and descent
/// rather than just the current numbers.
struct AltitudeProfileCard: View {

    let points: [TrackPoint]
    let theme: FlightInfoTheme

    private var altitudes: [Double] {
        points.map { $0.altitudeFeet.isFinite ? max($0.altitudeFeet, 0) : 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("FLOWN PROFILE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.textDim)

                Spacer(minLength: 4)

                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textDim)
            }

            profile
                .frame(height: 62)

            HStack(spacing: 8) {
                MiniStat(label: "PEAK", value: "\(Format.number(peakAltitude)) ft", theme: theme)
                MiniStat(
                    label: "TOP SPEED",
                    value: "\(Format.number(topSpeed)) kts",
                    theme: theme,
                    alignment: .center
                )
                MiniStat(
                    label: "TRACKED",
                    value: "\(Format.number(trackedNM)) NM",
                    theme: theme,
                    alignment: .trailing
                )
            }
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    /// Where each sample sits along the x-axis, as a fraction of the whole
    /// track.
    ///
    /// Distance, not sample index. The breadcrumbs are thinned by distance but
    /// the backend's history and the live feed do not sample at the same rate,
    /// so an index axis stretches whichever part of the flight happened to be
    /// sampled hardest — usually the bit since the window was opened, which
    /// makes a fourteen-hour cruise look like a third of the flight. Plotting
    /// against distance flown makes the shape match the map.
    private var fractions: [Double] {
        guard points.count >= 2 else { return points.isEmpty ? [] : [0] }

        var running: [Double] = [0]
        var total: Double = 0
        for (from, to) in zip(points, points.dropFirst()) {
            total += FlightProgress.distanceNM(from: from.coordinate, to: to.coordinate)
            running.append(total)
        }

        // A track that has not moved — an aircraft parked with the window open
        // — has no distance to divide by, so it falls back to even spacing
        // rather than stacking every sample on the left edge.
        guard total > 0 else {
            let last = Double(points.count - 1)
            return (0..<points.count).map { Double($0) / last }
        }
        return running.map { $0 / total }
    }

    private var profile: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let values = altitudes
            let xs = fractions
            let ceiling = max(values.max() ?? 1, 1)

            ZStack {
                // The fill carries the ramp as a vertical gradient, so the
                // colour under the trace agrees with the height it is drawn at
                // rather than being a tint of the accent.
                shape(in: size, values: values, xs: xs, ceiling: ceiling, closed: true)
                    .fill(
                        LinearGradient(
                            stops: gradientStops(ceiling: ceiling, opacity: 0.30),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )

                // And the trace itself is stroked with the same ramp, which is
                // what makes a climb read as a sweep through the colours the
                // map is drawing the path in.
                shape(in: size, values: values, xs: xs, ceiling: ceiling, closed: false)
                    .stroke(
                        LinearGradient(
                            stops: gradientStops(ceiling: ceiling, opacity: 1),
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }

    /// Ramp stops placed at the height each colour actually means, scaled to
    /// this flight's ceiling.
    ///
    /// Anchored to feet rather than spread evenly, so a short hop that never
    /// leaves 8,000 ft draws entirely in the low colours instead of running the
    /// whole ramp inside its own small range and claiming to have been to the
    /// flight levels.
    private func gradientStops(ceiling: Double, opacity: Double) -> [Gradient.Stop] {
        let heights = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 * ceiling }
        return heights.map { feet in
            Gradient.Stop(
                color: Color(uiColor: AltitudeBand.color(forFeet: feet)).opacity(opacity),
                location: ceiling > 0 ? CGFloat(feet / ceiling) : 0
            )
        }
    }

    private func shape(
        in size: CGSize,
        values: [Double],
        xs: [Double],
        ceiling: Double,
        closed: Bool
    ) -> Path {
        Path { path in
            guard values.count >= 2, values.count == xs.count,
                  size.width > 0, size.height > 0 else { return }

            func point(_ index: Int) -> CGPoint {
                let normalised = CGFloat(values[index] / ceiling)
                return CGPoint(
                    x: CGFloat(xs[index]) * size.width,
                    // A little headroom so the peak doesn't sit on the edge.
                    y: size.height - normalised * (size.height - 3) - 1
                )
            }

            path.move(to: point(0))
            for index in 1..<values.count { path.addLine(to: point(index)) }

            guard closed else { return }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }

    private var peakAltitude: Double { altitudes.max() ?? 0 }

    private var topSpeed: Double {
        points.map { $0.groundSpeedKnots.isFinite ? $0.groundSpeedKnots : 0 }.max() ?? 0
    }

    /// Length of the path itself, which is longer than the great-circle
    /// distance whenever the aircraft has been vectored around.
    private var trackedNM: Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + FlightProgress.distanceNM(from: pair.0.coordinate, to: pair.1.coordinate)
        }
    }
}

// MARK: - Small readouts

/// Label-over-value readout used for the route's flown / remaining / ETE row.
struct MiniStat: View {

    let label: String
    let value: String
    let theme: FlightInfoTheme
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

// MARK: - Text helpers

extension View {

    /// One line, shrinking before it truncates. Every string in the window is
    /// user or feed supplied, so nothing may push the layout wider.
    func flightInfoLine(minimumScale: CGFloat = 0.7) -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(minimumScale)
            .truncationMode(.tail)
    }
}

// MARK: - What the simulator itself is reporting

/// The half of a flight the public feed can never produce.
///
/// The feed describes every aeroplane in the sky from a cloud service: where it
/// is, how fast, how high. It cannot say how much fuel is left, where the gear
/// is, what the wind is doing at the wing, or what the pilot has the thrust set
/// to — none of that leaves the device Infinite Flight is running on. This is
/// the pilot's own copy of the sim, published by their phone through Connect
/// and read back here by flight id.
///
/// **Absent rather than empty when nobody is broadcasting.** A permanent
/// "waiting for aircraft data" on a flight that will never have any is worse
/// than no block at all — it reads as something broken instead of something
/// that was never switched on. Almost every aircraft on the map falls into that
/// case, which is why the card is conditional at its call site.
///
/// **Nothing is dated now unless it is now.** When the pilot's app has been
/// suspended behind the simulator the server keeps their position alive from
/// the feed, and the sim's own figures — the fuel, the configuration, the wind
/// — stay exactly as last reported. Those get `sim_live_at` against them, so a
/// reader sees "3.2 t · 14 min ago" rather than a stale number presented as a
/// current one.
struct SimReadoutCard: View {

    let status: PilotLiveStatus
    let theme: FlightInfoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !primary.isEmpty {
                HStack(spacing: 8) {
                    ForEach(primary, id: \.label) { stat in
                        MiniStat(
                            label: stat.label,
                            value: stat.value,
                            theme: theme,
                            alignment: stat.alignment
                        )
                    }
                }
            }

            if !secondary.isEmpty {
                HStack(spacing: 8) {
                    ForEach(secondary, id: \.label) { stat in
                        MiniStat(
                            label: stat.label,
                            value: stat.value,
                            theme: theme,
                            alignment: stat.alignment
                        )
                    }
                }
            }

            if let configuration = configurationLine {
                Text(configuration)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.75)
            }

            if let warning = warningLine {
                Text(warning)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
            }

            if let age = ageLine {
                Text(age)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("FROM THE SIM")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)

            Text("@\(status.handle)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)

            Spacer(minLength: 4)

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10))
                .foregroundStyle(theme.textDim)
        }
    }

    private struct Stat {
        let label: String
        let value: String
        var alignment: HorizontalAlignment = .leading
    }

    /// Fuel first, because it is the one people ask for and the one the feed
    /// has no way of knowing.
    private var primary: [Stat] {
        var out: [Stat] = []

        if let fuel = status.fuelRemainingKg, fuel > 0 {
            out.append(Stat(label: "FUEL", value: Self.tonnes(fuel)))
        }
        if let burn = status.fuelBurnKgh, burn > 0 {
            out.append(Stat(label: "BURN", value: "\(Format.number(Double(burn))) kg/h", alignment: .center))
        }
        if let n1 = status.engineN1, n1 > 0 {
            out.append(Stat(label: "N1", value: "\(n1)%", alignment: out.count >= 2 ? .trailing : .leading))
        }
        return out
    }

    private var secondary: [Stat] {
        var out: [Stat] = []

        if let ias = status.indicatedAirspeedKnots, ias > 0 {
            out.append(Stat(label: "IAS", value: "\(ias) kts"))
        }
        if let agl = status.altitudeAGL {
            out.append(Stat(label: "AGL", value: "\(Format.number(Double(agl))) ft", alignment: .center))
        }
        if let wind = windSummary {
            out.append(Stat(label: "WIND", value: wind, alignment: out.count >= 2 ? .trailing : .leading))
        }
        return out
    }

    private var windSummary: String? {
        guard let velocity = status.windVelocityKnots else { return nil }
        guard let direction = status.windDirection else { return "\(velocity) kt" }
        let gust = status.windGustKnots.map { $0 > velocity ? "G\($0)" : "" } ?? ""
        return String(format: "%03d/%d%@", direction, velocity, gust)
    }

    /// Gear, flaps and the lights, in the order a pilot would read them off.
    /// One line rather than a grid: none of it is a number, and all of it is
    /// only interesting as a picture of how the aeroplane is set up.
    private var configurationLine: String? {
        var parts: [String] = []

        if let gear = status.gearState {
            parts.append(gear == 0 ? "Gear up" : "Gear down")
        }
        if let flaps = status.flapsState, flaps > 0 {
            parts.append("Flaps \(flaps)")
        }
        if let spoilers = status.spoilersState, spoilers > 0 {
            parts.append(spoilers > 1 ? "Spoilers armed" : "Spoilers")
        }
        if status.reverseThrust == true { parts.append("Reverse") }
        if status.parkingBrake == true { parts.append("Brake set") }
        if status.landingLights == true { parts.append("Landing lights") }
        if status.strobeLights == true { parts.append("Strobes") }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Only when true. A card that says "Stalling: no" is a card nobody reads
    /// the day it says yes.
    private var warningLine: String? {
        var parts: [String] = []
        if status.isStalling == true { parts.append("STALL") }
        if status.isOverspeeding == true { parts.append("OVERSPEED") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Says how old the sim's figures are whenever they are not current, and
    /// says nothing at all when they are.
    private var ageLine: String? {
        guard let sampled = status.simLiveAt else { return nil }
        let age = Date().timeIntervalSince(sampled)
        guard age > 120 else { return nil }

        let minutes = Int(age / 60)
        let when = minutes < 60
            ? "\(minutes) min ago"
            : "\(minutes / 60) h ago"
        return "From the sim \(when) — the position since then is the map's, not theirs."
    }

    private static func tonnes(_ kilograms: Int) -> String {
        kilograms >= 1000
            ? String(format: "%.1f t", Double(kilograms) / 1000)
            : "\(kilograms) kg"
    }
}

// MARK: - On frequency

/// Who this aeroplane is talking to, in its own window.
///
/// Only ever drawn on the flight the pilot is actually flying, and only while
/// Infinite Flight Connect is attached to it. That is not a limitation to work
/// around — it is where the information exists. The public Live API knows which
/// controllers are *open* on a server, which is what the ATC panel lists, and it
/// has no idea which of them any particular aeroplane is tuned to. Only the
/// simulator knows that, and it only tells the device it is linked to.
///
/// The match is on the flight id the sim published rather than on a name, so
/// this cannot end up on somebody else's aircraft: no id, no card.
///
/// Two halves, and they are not equally certain:
///
///   - **The frequency.** `com_1/atc_name` was observed in a real manifest, is
///     polled like any other state, and changes when the pilot changes
///     frequency. It works.
///   - **The transcript.** A pushed stream whose paths were named from the
///     developer reference rather than seen, and which this build of Infinite
///     Flight may well not expose at all. So it is drawn only when messages have
///     actually arrived. There is no empty state and no explanation here: a
///     window about an aeroplane is the wrong place for a paragraph about an
///     API, and the Connect panel already carries that sentence for anyone who
///     goes looking.
struct ConnectFrequencyCard: View {

    /// The flight the window is open on. Compared against the id the sim
    /// published, which is what makes this "your aeroplane" rather than "an
    /// aeroplane".
    let flightId: String

    let theme: FlightInfoTheme

    @ObservedObject private var session = ConnectSession.shared

    /// Asked of the session rather than worked out here.
    ///
    /// This view used to compare the flight ids itself, which was the same
    /// check and not the same thing: the live-status publisher was making its
    /// own version of it a few files away, and two copies of "is this the right
    /// aeroplane" is one copy that will be missing a clause. The session owns
    /// the question — including the parts a view could not see, like whether
    /// the transcript was captured under this flight or the one before it.
    private var atc: (facility: String?, log: [ConnectATCMessage])? {
        session.atc(for: flightId)
    }

    var body: some View {
        // Nothing tuned and nothing said is nothing to draw. The card does not
        // appear at all rather than appearing empty.
        if let atc = atc {
            let facility = atc.facility
            let log = atc.log

            VStack(alignment: .leading, spacing: 10) {
                header

                if let facility = facility {
                    Text(facility)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.6)
                }

                if !log.isEmpty {
                    if facility != nil {
                        Rectangle()
                            .fill(theme.stroke)
                            .frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(log.prefix(5)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                if let from = line.from {
                                    Text(from.uppercased())
                                        .font(.system(size: 8.5, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(theme.accent)
                                }

                                Text(line.text)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
            // The frequency changes mid-flight and the log grows a line at a
            // time, so both move rather than jumping.
            .motion(Motion.row, value: facility)
            .motion(Motion.row, value: log.count)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("ON FREQUENCY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)

            Text("FROM YOUR SIM")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)

            Spacer(minLength: 4)

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10))
                .foregroundStyle(theme.textDim)
        }
    }
}
