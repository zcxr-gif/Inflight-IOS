import SwiftUI

/// Settings, from the toolbar's settings button.
///
/// The app's own preferences: which server the feed is joined to, and how the
/// flight window looks. What the *map* is showing lives under filters, and how
/// weather reads lives under weather — this panel is everything else.
struct SettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var mapAppearance = MapAppearance.shared
    @ObservedObject private var radar = RadarService.shared
    /// Whether the screen behind this panel is wide enough for the flight
    /// window to have a choice about where it sits.
    ///
    /// Passed in rather than read from the environment here, and that is not a
    /// style preference: this panel is presented in a sheet, and a sheet on an
    /// iPad is a form sheet a few hundred points wide, which reports a
    /// *compact* size class however large the iPad behind it is. Asking here
    /// would hide the row on exactly the device it exists for.
    var isWideScreen: Bool = false

    @ObservedObject private var hints = HintsStore.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var isSideWindow: Bool {
        appearance.placement == .side && isWideScreen
    }

    var body: some View {
        MapPanel(title: "Settings", subtitle: feedSummary) {
            PanelSection(title: "FEED") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
                }
            }

            // All three are in the stack in the map's bottom right corner,
            // which is where they get used. Repeated here because a control
            // that only cycles is one you have to tap three times to see the
            // options of, and because a toggle nobody has found is a feature
            // nobody has.
            PanelSection(title: "MAP") {
                PanelPickerRow(
                    title: "Ground",
                    symbol: "map",
                    options: MapGroundStyle.allCases,
                    label: { $0.label },
                    detail: "What the map is drawn on, under the traffic.",
                    selection: $mapAppearance.style
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Precipitation radar",
                    symbol: "cloud.rain.fill",
                    detail: radarDetail,
                    isOn: $mapAppearance.isRadarVisible
                )

                PanelDivider()

                PanelToggleRow(
                    title: "3D terrain",
                    symbol: "view.3d",
                    detail: "Raises the ground into relief and tilts the camera. The map stays north-up, so the aircraft still point where they are going.",
                    isOn: $mapAppearance.isElevated
                )
            }

            PanelSection(title: "FLIGHT WINDOW") {
                // Only a question where there is room for two answers. On a
                // phone the window is a sheet and there is nothing to decide,
                // so the row is not there to be decided.
                if isWideScreen {
                    PanelPickerRow(
                        title: "Placement",
                        symbol: "rectangle.trailinghalf.inset.filled",
                        options: FlightWindowPlacement.allCases,
                        label: { $0.label },
                        detail: appearance.placement.detail,
                        selection: $appearance.placement
                    )

                    PanelDivider()
                }

                PanelToggleRow(
                    title: "Glass flight info",
                    symbol: "square.on.square.dashed",
                    detail: "Frosts the window and its chrome. Off, everything draws on flat carbon.",
                    isOn: $appearance.isGlassEnabled
                )

                PanelDivider()

                // The peak measures itself, so switching this resizes the sheet
                // even while it is on screen. It is a sheet's setting — the
                // column has no peek to style — so it steps back rather than
                // disappearing, which would leave the section looking like it
                // had lost a row.
                PanelPickerRow(
                    title: "Peek",
                    symbol: "rectangle.portrait.bottomhalf.filled",
                    options: FlightInfoPeakStyle.allCases,
                    label: { $0.label },
                    detail: isSideWindow
                        ? "The column opens in full, so there is no peek to style."
                        : appearance.peakStyle.detail,
                    selection: $appearance.peakStyle
                )
                .disabled(isSideWindow)
                .opacity(isSideWindow ? 0.45 : 1)
            }

            PanelSection(title: "HINTS") {
                PanelToggleRow(
                    title: "Show hints",
                    symbol: "lightbulb",
                    detail: "A line of guidance at the foot of a screen, about that screen. Each one retires after you have seen it a few times.",
                    isOn: $hints.isEnabled
                )

                // Only offered once there is something to bring back, so the
                // section is a switch and nothing else until it has earned the
                // second row.
                if hints.retiredCount > 0 {
                    PanelDivider()

                    Button {
                        hints.restoreAll()
                    } label: {
                        HStack(spacing: 10) {
                            PanelRowLabel(title: "Show them all again", symbol: "arrow.counterclockwise")

                            Spacer(minLength: 8)

                            Text("\(hints.retiredCount) read")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.textDim)
                                .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!hints.isEnabled)
                    .opacity(hints.isEnabled ? 1 : 0.45)
                }
            }

            PanelSection(title: "ABOUT") {
                aboutRow("Version", value: version)
                PanelDivider()
                // Surfaces a packaging problem that otherwise just looks like an
                // empty map, which is hard to diagnose from a TestFlight build.
                aboutRow("Aircraft sprites", value: PlaneSprites.shared.isReady ? "Loaded" : "Missing")
                PanelDivider()
                aboutRow("Traffic", value: "\(feed.flights.count) aircraft")
            }
        }
    }

    /// Says how old the picture is when there is one. Radar with no time
    /// against it is a claim about now that could be a couple of hours out.
    private var radarDetail: String {
        guard mapAppearance.isRadarVisible else {
            return "Rain and snow under the traffic, from RainViewer. Nothing is fetched while this is off."
        }

        guard let frame = radar.frame else {
            return radar.hasAnswered
                ? "No radar picture available right now."
                : "Looking for the latest sweep…"
        }

        return "Showing the sweep observed at \(frame.label). A new one lands about every ten minutes."
    }

    private var feedSummary: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.flights.count) aircraft · \(feed.server)"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private func serverRow(_ server: String) -> some View {
        Button {
            feed.select(server: server)
        } label: {
            HStack(spacing: 10) {
                PanelRowLabel(
                    title: server.replacingOccurrences(of: " Server", with: ""),
                    symbol: "dot.radiowaves.left.and.right"
                )

                Spacer(minLength: 8)

                if feed.server == server {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aboutRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
