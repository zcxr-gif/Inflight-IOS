import SwiftUI

/// The instruments, inside the flight window.
///
/// One card carrying whichever of the two displays is switched on, the switch
/// itself, and — for the navigation display — the two controls somebody
/// actually reaches for while reading it: how far it reaches, and which way it
/// is drawn. Everything else about the panel lives in Settings, because it is a
/// thing you set once.
struct InstrumentsCard: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var preferences = InstrumentPreferences.shared
    @StateObject private var source = InstrumentSource()

    let flightId: String
    let theme: FlightInfoTheme

    /// Whether the card is actually being looked at. False while the window is
    /// sitting at its peek, where the card is still in the tree at zero
    /// opacity.
    var isRunning = true

    @State private var isShowingPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            InstrumentDeck(
                flightId: flightId,
                sim: source.sim,
                estimator: source.estimator,
                animator: source.animator,
                waypoints: source.waypoints,
                traffic: source.traffic,
                // The full-screen panel is drawing the same instrument from its
                // own source; the card underneath it has nothing to say until
                // it comes back.
                isRunning: isRunning && !isShowingPanel
            )
            .environmentObject(feed)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .strokeBorder(theme.stroke, lineWidth: 1)
            }

            if preferences.display == .navigation {
                InstrumentRangeControls(theme: theme)
            }
        }
        .instrumentSource(source, flightId: flightId, feed: feed)
        .fullScreenCover(isPresented: $isShowingPanel) {
            InstrumentsPanel(flightId: flightId).environmentObject(feed)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("INSTRUMENTS")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)

            Spacer(minLength: 6)

            InstrumentDisplaySwitch(theme: theme)

            Button {
                isShowingPanel = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 26, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.surfaceFill)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the instruments full screen")
        }
        .padding(.leading, 2)
    }
}

/// The instruments on their own, with the room to be read.
///
/// A full-screen cover rather than another sheet: the flight window is already
/// a sheet, and the one thing this view wants is every point of the screen it
/// can get.
struct InstrumentsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var preferences = InstrumentPreferences.shared
    @StateObject private var source = InstrumentSource()
    @Environment(\.dismiss) private var dismiss

    let flightId: String

    private var theme: FlightInfoTheme { appearance.theme }

    private var flight: Flight? {
        feed.flights.first { $0.id == flightId }
    }

    var body: some View {
        ZStack {
            InstrumentPalette.screen.ignoresSafeArea()

            VStack(spacing: 14) {
                header

                InstrumentDeck(
                    flightId: flightId,
                    sim: source.sim,
                    estimator: source.estimator,
                    animator: source.animator,
                    waypoints: source.waypoints,
                    traffic: source.traffic
                )
                .environmentObject(feed)
                .frame(maxWidth: .infinity)

                controls

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        .instrumentSource(source, flightId: flightId, feed: feed)
        // The instruments are their own look — carbon and colour-coded — and
        // the chrome around them has to be read against that, whatever the
        // app's theme is set to.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flight?.displayName ?? "—")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(InstrumentPalette.scale)

                Text(preferences.display.longLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(InstrumentPalette.scaleDim)
            }

            Spacer(minLength: 8)

            InstrumentDisplaySwitch(theme: theme)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(InstrumentPalette.scale)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(Color.white.opacity(0.12)) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if preferences.display == .navigation {
            VStack(spacing: 10) {
                InstrumentRangeControls(theme: theme)

                Toggle(isOn: $preferences.showsTraffic) {
                    Text("Traffic")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(InstrumentPalette.scale)
                }
                .tint(InstrumentPalette.live)
                .padding(.horizontal, 4)
            }
        } else {
            Text(attitudeNote)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(InstrumentPalette.scaleDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
        }
    }

    /// Says, in words, what the footer of the display says in three: whether
    /// the horizon is measured or worked out.
    private var attitudeNote: String {
        guard let sim = source.sim, sim.isLive, sim.pitch != nil, sim.bank != nil else {
            return """
            Pitch and bank are worked out from the flight path and the rate of \
            turn — the feed does not carry attitude. Everything else here is \
            reported.
            """
        }
        return "Attitude, airspeed and wind are read straight from this pilot's simulator."
    }
}

// MARK: - Controls

/// The PFD / ND switch. Two chips rather than a segmented control, because it
/// has to sit in a card header at the height of a caption.
struct InstrumentDisplaySwitch: View {

    @ObservedObject private var preferences = InstrumentPreferences.shared

    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InstrumentDisplay.allCases) { option in
                let selected = preferences.display == option

                Button {
                    preferences.display = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(selected ? theme.onAccent : theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? theme.accent : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.longLabel)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceFill)
        }
    }
}

/// How far the navigation display reaches, and which way it is drawn.
struct InstrumentRangeControls: View {

    @ObservedObject private var preferences = InstrumentPreferences.shared

    let theme: FlightInfoTheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NavigationDisplayMode.allCases) { mode in
                let selected = preferences.navigationMode == mode

                Button {
                    preferences.navigationMode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(selected ? theme.onAccent : theme.textSecondary)
                        .frame(width: 46, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? theme.accent : theme.surfaceFill)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }

            Spacer(minLength: 4)

            stepButton(symbol: "minus", step: -1)

            Text("\(Int(preferences.rangeNM)) NM")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 54)

            stepButton(symbol: "plus", step: 1)
        }
    }

    private func stepButton(symbol: String, step: Int) -> some View {
        let next = preferences.range(steppedBy: step)
        let available = next != preferences.rangeNM

        return Button {
            preferences.rangeNM = next
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 30, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.surfaceFill)
                }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
        .accessibilityLabel(step > 0 ? "Increase range" : "Decrease range")
    }
}

// MARK: - Keeping the source fed

private struct InstrumentSourceModifier: ViewModifier {

    @ObservedObject var source: InstrumentSource
    @ObservedObject var feed: LiveFeed
    @ObservedObject private var preferences = InstrumentPreferences.shared

    let flightId: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                source.adopt(flightId: flightId)
                source.ingest(flights: feed.flights, rangeNM: preferences.rangeNM)
            }
            .onChange(of: flightId) { _, id in
                source.adopt(flightId: id)
                source.ingest(flights: feed.flights, rangeNM: preferences.rangeNM)
            }
            .onChange(of: feed.lastUpdate) { _, _ in
                source.ingest(flights: feed.flights, rangeNM: preferences.rangeNM)
            }
            // Reaching further has to widen the net the traffic was drawn from,
            // or the display gains empty miles rather than the aircraft in them.
            .onChange(of: preferences.rangeNM) { _, range in
                source.ingest(flights: feed.flights, rangeNM: range)
            }
            // The sim writes its row every fifteen to forty-five seconds. A
            // minute is slower than the source changes and faster than anybody
            // watching a horizon would notice.
            .task(id: flightId) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { return }
                    source.refreshSim()
                }
            }
    }
}

extension View {

    /// Keeps one `InstrumentSource` pointed at an aircraft and fed from the
    /// packets, wherever its displays are being shown.
    func instrumentSource(
        _ source: InstrumentSource,
        flightId: String,
        feed: LiveFeed
    ) -> some View {
        modifier(InstrumentSourceModifier(source: source, feed: feed, flightId: flightId))
    }
}
