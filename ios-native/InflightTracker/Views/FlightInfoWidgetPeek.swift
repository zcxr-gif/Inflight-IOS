import SwiftUI
import UIKit

/// The peek that is the home-screen tile.
///
/// The other three peeks are three arrangements of the window's own parts —
/// its cards, its ground, its type. This one is not an arrangement at all: it
/// is the Flight widget, drawn from the widget's own views on the widget's own
/// model, sitting in the window.
///
/// That is the whole idea, and it is why nothing here is a copy of anything in
/// `InflightWidgets`. `RouteStrip`, `WidgetStat`, `PhaseChip`, `Wordmark` and
/// the palette and type tokens all moved into `Shared` so that both the tile
/// and this draw from one set — a second set would agree on the day it was
/// written and drift afterwards, and the drift would show in the one place
/// anybody can hold the two side by side: a home screen with the app open over
/// it. `WidgetFlight(flight:)` does the same for the numbers, so the tile and
/// the peek cannot disagree about what one aeroplane is doing.
///
/// Two things are deliberately *not* the tile's:
///
///   - the photograph is the one the window already fetched, rather than the
///     one the shared cache holds. The window has it decoded by the time this
///     is drawn, and real traffic's photographs — which come from Planespotters
///     and belong to the airframe rather than to the type — are never written
///     to that cache at all, so a tile drawn from the key would fall back to
///     the painted sky for exactly the aircraft this peek is best at.
///   - it is white on a shaded photograph whichever theme the app is in. A
///     widget is its own surface on somebody's wallpaper and has always been
///     dark; a light-mode version of it would be a light-mode version of
///     something that does not have one.
struct FlightWidgetPeek: View {

    let flight: Flight

    /// The photograph already in the window's hands. Nil draws `DrawnSky`, the
    /// same as an un-cached tile.
    let image: UIImage?

    let theme: FlightInfoTheme

    /// The shortest the tile is ever drawn.
    ///
    /// Everything in it is text over a photograph rather than beside one, so
    /// unlike the photo peek nothing here grows with the picture — which makes
    /// this close to the tile's real height rather than a floor it clears by
    /// accident. It is a floor rather than a fixed height because the type
    /// scales: a long livery on a large accessibility size takes a second line,
    /// and a tile that clipped it would be worse than a tile a few points
    /// taller. See `FlightInfoLayout.openingHeight(for:)`.
    static let minimumHeight: CGFloat = 188

    /// The corner the home screen rounds a widget to, near enough. The window's
    /// own large radius, which is within a point or two of it and means the
    /// tile sits inside the sheet concentrically rather than nearly so.
    private var radius: CGFloat { theme.radiusLarge }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        // Resolved once. It walks the airport table and does the route's
        // great-circle arithmetic, which is not work to do five times because
        // five subviews each wanted a number out of it.
        card(WidgetFlight(flight: flight))
    }

    private func card(_ tile: WidgetFlight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(tile)

            Spacer(minLength: 10)

            RouteStrip(
                departure: tile.departureIcao,
                arrival: tile.arrivalIcao,
                progress: tile.progress,
                isLanded: !tile.isAirborne && (tile.progress ?? 0) > 0.9,
                icaoSize: 26
            )

            Spacer(minLength: 12)

            readouts(tile)

            Spacer(minLength: 12)

            foot(tile)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, alignment: .leading)
        .background { PlaneBackdrop(image: image, style: .framed, altitudeFt: tile.altitudeFt) }
        .clipShape(shape)
        // The hairline a widget gets from the home screen's own compositing.
        // Without it a dark photograph ends on a dark sheet and the tile has no
        // edge at all.
        .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        // The tile is one thing to read, not eight. Said as the widget's own
        // summary rather than as a list of its labels.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(tile))
    }

    // MARK: - Who

    private func header(_ tile: WidgetFlight) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.callsign)
                    .font(WidgetType.title(15))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine()
                    // Tapping a second aeroplane changes this window rather
                    // than replacing it, the same as every other peek.
                    .motionWords(tile.callsign)

                Text(descriptor(tile))
                    .font(WidgetType.caption(10))
                    .foregroundStyle(WidgetPalette.secondary)
                    .flightInfoWidgetLine()
                    .motionWords(descriptor(tile))
            }

            Spacer(minLength: 6)

            PhaseChip(symbol: tile.phaseSymbol, text: tile.phaseLabel)
                // Clear of the photographer's credit, which the window floats
                // over this same corner for a real aeroplane.
                .padding(.top, 2)
        }
    }

    // MARK: - How

    /// The large tile's three numbers, which is what the window has the width
    /// for. A medium tile leaves these out; a peek is a good deal wider than
    /// one and would have a band of empty photograph where they go.
    private func readouts(_ tile: WidgetFlight) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            WidgetStat(
                value: tile.totalNM > 1 ? "\(WidgetFormat.number(tile.remainingNM)) NM" : "—",
                label: "TO RUN",
                valueSize: 15
            )

            Spacer(minLength: 6)

            WidgetStat(
                value: "\(WidgetFormat.number(Double(tile.altitudeFt))) FT",
                label: "ALTITUDE",
                alignment: .center,
                valueSize: 15
            )

            Spacer(minLength: 6)

            WidgetStat(
                value: "\(tile.groundSpeedKt) KTS",
                label: "GROUND SPEED",
                alignment: .trailing,
                valueSize: 15
            )
        }
    }

    private func foot(_ tile: WidgetFlight) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                countdown(tile)

                Text(footnote(tile))
                    .font(WidgetType.caption(10))
                    .foregroundStyle(WidgetPalette.dim)
                    .flightInfoWidgetLine()
                    .motionWords(footnote(tile))
            }

            Spacer(minLength: 8)

            Wordmark(size: 10)
        }
    }

    /// How long is left, or what it is doing when that is not a question with
    /// an answer.
    ///
    /// A rendered figure rather than the tile's `Text(timerInterval:)`. The
    /// widget counts down because it is re-rendered on the system's schedule
    /// and would otherwise sit on a number that is an hour old; this is over a
    /// live socket, so the figure is replaced every few seconds by a new one
    /// worked out from where the aeroplane actually is. A ticking clock beside
    /// that would be the same estimate arriving twice, out of step with itself.
    @ViewBuilder
    private func countdown(_ tile: WidgetFlight) -> some View {
        if tile.isAirborne, let remaining = enroute(tile) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(WidgetFormat.duration(remaining))
                    .font(WidgetType.readout(17))
                    .foregroundStyle(WidgetPalette.text)
                    .flightInfoWidgetLine()
                    .motionWords(WidgetFormat.duration(remaining))

                Text("left")
                    .font(WidgetType.caption(11))
                    .foregroundStyle(WidgetPalette.secondary)
            }
        } else {
            Text(tile.isAirborne ? "Arriving" : tile.phaseLabel)
                .font(WidgetType.readout(17))
                .foregroundStyle(WidgetPalette.text)
                .flightInfoWidgetLine()
                .motionWords(tile.isAirborne ? "Arriving" : tile.phaseLabel)
        }
    }

    // MARK: - Lines

    /// Seconds to run, when there are any. `eta` was worked out against the
    /// moment the model was built, which is this frame.
    private func enroute(_ tile: WidgetFlight) -> TimeInterval? {
        guard let eta = tile.eta else { return nil }
        let remaining = eta.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    /// What it is, under the callsign — the same line the tile puts there.
    ///
    /// A space rather than an empty string when there is nothing to say: this
    /// line holds the header's height, and a tile that loses a line the moment
    /// a lookup comes back empty is a tile that jumps.
    private func descriptor(_ tile: WidgetFlight) -> String {
        var parts: [String] = []

        if !tile.aircraftType.isEmpty { parts.append(tile.aircraftType) }
        if !tile.liveryName.isEmpty,
           tile.liveryName.caseInsensitiveCompare(tile.aircraftType) != .orderedSame {
            parts.append(tile.liveryName)
        }
        // A real aeroplane has a type designator and no livery; one the feed
        // has told us nothing about has neither, and is still somebody.
        if parts.isEmpty, !tile.username.isEmpty { parts.append(tile.username) }
        if parts.isEmpty, !tile.registration.isEmpty { parts.append(tile.registration) }

        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    /// Distance to run, or who is flying it — and for a real aeroplane, which
    /// airframe it is. The tile's own line says how old the reading is instead,
    /// which is a thing only a widget has to admit to.
    private func footnote(_ tile: WidgetFlight) -> String {
        guard tile.totalNM > 1 else {
            if !tile.username.isEmpty { return tile.username }
            if !tile.registration.isEmpty { return tile.registration }
            return "No route filed"
        }
        return "\(WidgetFormat.number(tile.remainingNM)) NM to run"
    }

    private func summary(_ tile: WidgetFlight) -> String {
        var parts = [tile.callsign, descriptor(tile), tile.phaseLabel]

        if !tile.departureIcao.isEmpty || !tile.arrivalIcao.isEmpty {
            parts.append("\(tile.departureIcao) to \(tile.arrivalIcao)")
        }

        parts.append("\(WidgetFormat.number(Double(tile.altitudeFt))) feet")
        parts.append("\(tile.groundSpeedKt) knots")

        if tile.isAirborne, let remaining = enroute(tile) {
            parts.append("\(WidgetFormat.duration(remaining)) left")
        }

        return parts.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            .joined(separator: ", ")
    }
}
