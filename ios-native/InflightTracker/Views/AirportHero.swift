import SwiftUI

/// The photograph at the top of a field's panel, with the field's identity
/// riding the bottom of it.
///
/// The web tracker opened every airport window on a hero image
/// (`old/www/flight.js` -> `airport-hero`), falling back to one bundled picture
/// of a generic apron when the backend had nothing. A single stock photo shown
/// for thousands of different fields reads as a loading failure, so the
/// fallback here is a ground of the panel's own — derived from the ICAO, so a
/// field looks the same every time you open it — rather than a photograph of
/// somewhere else.
struct AirportHero: View {

    let airport: Airport

    /// Nil until the lookup answers. Distinct from an answer with no photo,
    /// which is `info` set with a nil `imageURL`.
    let info: AirportInfo?

    /// Somebody is working the field right now.
    let isControlled: Bool

    /// What the field is currently good for, when a report has been read.
    let category: Metar.FlightCategory?

    let theme: FlightInfoTheme

    @StateObject private var loader = RemoteImageLoader()

    /// Tall enough to be a photograph rather than a strip, short enough that
    /// the traffic — which is what the panel is actually for — is still on
    /// screen when it opens.
    private static let height: CGFloat = 168

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            PhotoScrim()
            identity
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                .strokeBorder(theme.stroke, lineWidth: 1)
        }
        .onChange(of: info?.imageURL) { _, url in
            loader.load(url)
        }
        .onAppear { loader.load(info?.imageURL) }
    }

    // MARK: - Behind

    @ViewBuilder
    private var backdrop: some View {
        if let image = loader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.opacity)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            AirportPlaceholderGround(icao: airport.icao)

            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 78, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.10))
                .offset(x: 86, y: -18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - In front

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(airport.icao)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize()

                if !airport.flag.isEmpty {
                    Text(airport.flag)
                        .font(.system(size: 20))
                        .accessibilityHidden(true)
                }

                if info?.has3DBuildings == true {
                    heroBadge("3D")
                }

                if isControlled {
                    AtcOnlineBadge(theme: theme)
                }

                if let category = category {
                    FlightCategoryBadge(category: category)
                }
            }

            Text(airport.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .flightInfoLine(minimumScale: 0.7)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .flightInfoLine(minimumScale: 0.7)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where it is and how high, once the lookup has said. Left out entirely
    /// rather than held open as a placeholder — the line appears when it has
    /// something to say.
    private var subtitle: String? {
        var parts: [String] = []
        if let location = info?.locationLabel { parts.append(location) }
        if let elevation = info?.elevationLabel { parts.append("\(elevation) elev") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Small caps on a translucent slab — legible over a photograph without
    /// needing to know what colour the photograph is.
    private func heroBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(.white.opacity(0.22))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
            .fixedSize()
    }
}

/// What a field looks like when there is no photograph of it.
///
/// A ground rather than a picture. The web build fell back to one bundled
/// photo of a generic apron, shown identically for thousands of different
/// fields, which read as a broken image the second you saw it twice — this is
/// honest about having nothing, and it is at least *this* field's nothing: the
/// hue comes off the ICAO, so a field looks the same every time you open it.
struct AirportPlaceholderGround: View {

    let icao: String

    var body: some View {
        let hue = Self.hue(for: icao)

        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.34, brightness: 0.34),
                Color(hue: hue, saturation: 0.42, brightness: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Stable per field and spread across the wheel. Summing the scalars would
    /// put every K-prefixed American field within a few degrees of every
    /// other, so each character is weighted by its position.
    static func hue(for icao: String) -> Double {
        var accumulator = 0
        for (index, scalar) in icao.unicodeScalars.enumerated() {
            accumulator = (accumulator &* 31 &+ Int(scalar.value) &* (index + 7)) % 3_600
        }
        return Double(accumulator) / 3_600
    }
}

/// A field's photograph at row size, for the board and anywhere else a list of
/// airports wants a face rather than four letters.
///
/// The lookup is fired when the row appears rather than when the panel opens,
/// so scrolling a long board only asks about the fields you actually reach —
/// and every answer warms the cache the field's own panel reads.
struct AirportThumbnail: View {

    let icao: String
    let theme: FlightInfoTheme
    var size: CGFloat = 42

    @StateObject private var loader = RemoteImageLoader()
    @State private var info: AirportInfo?

    var body: some View {
        ZStack {
            AirportPlaceholderGround(icao: icao)

            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: size * 0.34, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.stroke, lineWidth: 1)
        }
        .accessibilityHidden(true)
        .onAppear {
            info = AirportInfoService.shared.cached(icao)
            loader.load(info?.imageURL)

            AirportInfoService.shared.info(for: icao) { resolved in
                info = resolved
                loader.load(resolved.imageURL)
            }
        }
    }
}

/// VFR / MVFR / IFR / LIFR, in the colours those four have everywhere else in
/// aviation.
///
/// The only badge in the app that carries meaning in its colour, and
/// deliberately so: the palette is a convention pilots already read at a
/// glance, and rendering it in the window's monochrome would leave four words
/// that all look the same.
struct FlightCategoryBadge: View {

    let category: Metar.FlightCategory

    var body: some View {
        let tint = category.tint
        let color = Color(red: tint.red, green: tint.green, blue: tint.blue)

        return Text(category.label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(color.opacity(0.18))
            }
            .overlay {
                Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1)
            }
            .fixedSize()
            .accessibilityLabel("\(category.label), \(category.detail)")
    }
}

/// The row of numbers under a field's hero: movements, who is on frequency,
/// how long the longest runway is, how high the field sits.
///
/// The web tracker had the same strip (`apt-stats-bar`) and it is the fastest
/// read on the whole panel — four figures that answer "is this field worth
/// flying to right now" without scrolling.
struct AirportStatStrip: View {

    let inbound: Int
    let outbound: Int
    let onGround: Int
    let longestRunway: Runway?
    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 0) {
            cell(value: "\(inbound)", label: "INBOUND", symbol: "airplane.arrival")
            divider
            cell(value: "\(outbound)", label: "DEPARTED", symbol: "airplane.departure")
            divider
            cell(value: "\(onGround)", label: "ON GROUND", symbol: "airplane")
            divider
            cell(
                value: longestRunway.map { Format.number(Double($0.lengthFeet)) } ?? "—",
                label: "LONGEST FT",
                symbol: "road.lanes"
            )
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(width: 1, height: 30)
    }

    private func cell(value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textDim)

                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.6)
            }

            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.lowercased()), \(value)")
    }
}
