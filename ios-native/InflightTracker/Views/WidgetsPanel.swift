import SwiftUI
import WidgetKit

/// What is on the home screen, and how to change it without going and finding
/// it first.
///
/// ## Why this screen exists
///
/// Pinning has always been possible and has never been findable. The control is
/// one chip inside an open flight window, which means changing what the widget
/// shows requires already knowing which aeroplane is in it, finding that
/// aeroplane on the map, opening it, and un-pinning — and if the flight has
/// landed there is no window left to open at all, so the pin could be stuck on
/// something gone with nowhere to clear it from.
///
/// So: one place that says what the widgets are pointed at, and offers the
/// aircraft worth pointing them at — the pilot's own, and the pilots they
/// watch. Both lists come from the live packet, so this is what is flying now
/// rather than a list of names.
///
/// The widgets themselves can also be pointed at a pilot directly, by
/// long-pressing the tile on the home screen — a rule that survives the flight
/// ending, which a pin does not. That is said here rather than left to be
/// discovered, because a setting nobody knows about is a setting nobody has.
struct WidgetsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var widgets = WidgetBridge.shared
    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Widgets", subtitle: subtitle) {
            PanelSection(title: "THE FLIGHT WIDGET") {
                note(
                    """
                    Long-press the widget on your home screen and tap Edit \
                    Widget to point it at a pilot — it then shows whatever they \
                    are flying, and keeps working when the flight you set it up \
                    on has landed. Pinning below is the other way: one \
                    particular flight, until you change it.
                    """
                )
            }
            .panelEntrance(0)

            PanelSection(title: "PINNED FLIGHT") {
                if let pinned = pinnedFlight {
                    pinnedRow(pinned)
                } else if widgets.pinnedFlightId != nil {
                    strandedPin
                } else {
                    PanelEmptyState(
                        symbol: "square.grid.2x2",
                        title: "Nothing pinned",
                        detail: "Pick one below, or tap Pin in any flight's window."
                    )
                }
            }
            .motion(Motion.row, value: widgets.pinnedFlightId)
            .panelEntrance(1)

            if !candidates.isEmpty {
                PanelSection(title: "FLYING NOW") {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, flight in
                        if index > 0 { PanelDivider() }
                        candidateRow(flight)
                    }
                }
                .panelEntrance(2)
            } else {
                PanelSection(title: "FLYING NOW") {
                    PanelEmptyState(
                        symbol: "airplane.circle",
                        title: "Nobody to pin",
                        detail: emptyDetail
                    )
                }
                .panelEntrance(2)
            }

            PanelSection(title: "PINNED AIRPORT") {
                if let icao = widgets.pinnedAirportIcao {
                    airportRow(icao)
                } else {
                    PanelEmptyState(
                        symbol: "mappin.and.ellipse",
                        title: "No field pinned",
                        detail: "Open an airport and tap Pin to home screen."
                    )
                }
            }
            .motion(Motion.row, value: widgets.pinnedAirportIcao)
            .panelEntrance(3)
        }
    }

    // MARK: - What is pinned

    /// The pinned aircraft as the packet has it now.
    ///
    /// Nil covers two different things and the row below reads them apart: no
    /// pin at all, or a pin on a flight that has ended. The second is why a
    /// pinned id alone is not enough to draw a row from.
    private var pinnedFlight: Flight? {
        guard let id = widgets.pinnedFlightId else { return nil }
        return feed.flights.first { $0.id == id }
    }

    private var subtitle: String {
        if let pinned = pinnedFlight { return "Showing \(pinned.displayName)" }
        if widgets.pinnedFlightId != nil { return "Pinned flight has ended" }
        return "What the home screen is showing"
    }

    private func pinnedRow(_ flight: Flight) -> some View {
        row(
            title: flight.displayName,
            detail: routeLine(for: flight),
            symbol: "square.grid.2x2.fill",
            isOn: true
        ) {
            widgets.pin(nil)
        }
    }

    /// A pin left on a flight that is no longer in the packet.
    ///
    /// Drawn rather than silently ignored, and clearable from here, because the
    /// window it was set from does not exist any more — you cannot open a
    /// flight that has landed. Which is the case this screen was most worth
    /// building for: before it, that pin could not be cleared at all.
    private var strandedPin: some View {
        row(
            title: "That flight has ended",
            detail: "The widget falls back to whatever is next. Clear it to tidy up.",
            symbol: "clock.badge.xmark",
            isOn: false
        ) {
            widgets.pin(nil)
        }
    }

    // MARK: - What can be pinned

    /// This pilot's own aeroplanes first, then the pilots they watch.
    ///
    /// Read from the packet rather than from a stored list: the question this
    /// screen answers is "what can I put on my home screen right now", and an
    /// aeroplane that is not flying is not an answer to it.
    private var candidates: [Flight] {
        let identity = PilotIdentity.shared
        let watched = Set(friends.friends.map { $0.lowercased() })

        var mine: [Flight] = []
        var theirs: [Flight] = []

        for flight in feed.flights {
            if identity.isMe(flight.username) {
                mine.append(flight)
            } else if let name = flight.username?.lowercased(), watched.contains(name) {
                theirs.append(flight)
            }
        }

        let byHeight: (Flight, Flight) -> Bool = { $0.altitudeFeet > $1.altitudeFeet }
        return mine.sorted(by: byHeight) + theirs.sorted(by: byHeight)
    }

    private var emptyDetail: String {
        let identity = PilotIdentity.shared
        if !identity.isSet && friends.count == 0 {
            return "Set your Infinite Flight name and watch a pilot or two, and whoever is flying turns up here."
        }
        return "Neither you nor the pilots you watch are in the air at the moment."
    }

    private func candidateRow(_ flight: Flight) -> some View {
        let isPinned = widgets.isPinned(flight.id)

        return row(
            title: flight.displayName,
            detail: routeLine(for: flight),
            symbol: PilotIdentity.shared.isMe(flight.username) ? "person.crop.circle" : "person.2",
            isOn: isPinned
        ) {
            // A toggle, because there is one widget and one pin: tapping the
            // aeroplane already on the home screen is how you take it off.
            widgets.pin(isPinned ? nil : flight.id)
        }
    }

    private func airportRow(_ icao: String) -> some View {
        row(
            title: icao,
            detail: AirportStore.shared.airport(icao)?.name ?? "Pinned to the home screen",
            symbol: "mappin.and.ellipse",
            isOn: true
        ) {
            widgets.pinAirport(nil)
        }
    }

    // MARK: - Pieces

    /// Who and where, in the one line a row has for it.
    private func routeLine(for flight: Flight) -> String {
        let pilot = flight.username ?? ""
        let route = [flight.departureIcao, flight.arrivalIcao]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " → ")

        let phase = FlightPhase.from(flight).label
        return [pilot, route.isEmpty ? nil : route, phase]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    /// One tappable line: what it is, and whether it is the one on the home
    /// screen. Ticked rather than switched, because only one of them can be.
    private func row(
        title: String,
        detail: String,
        symbol: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: title, symbol: symbol)

                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? theme.textPrimary : theme.textDim)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .motion(Motion.control, value: isOn)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}
