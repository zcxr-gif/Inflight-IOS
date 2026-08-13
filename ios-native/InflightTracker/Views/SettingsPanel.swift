import SwiftUI

/// Settings, from the toolbar's settings button.
///
/// The app's own preferences: which server the feed is joined to, and how the
/// flight window looks. What the *map* is showing lives under filters, and how
/// weather reads lives under weather — this panel is everything else.
struct SettingsPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Settings", subtitle: feedSummary) {
            PanelSection(title: "FEED") {
                ForEach(AppConfig.servers, id: \.self) { server in
                    if server != AppConfig.servers.first { PanelDivider() }
                    serverRow(server)
                }
            }

            PanelSection(title: "FLIGHT WINDOW") {
                PanelToggleRow(
                    title: "Glass flight info",
                    symbol: "square.on.square.dashed",
                    detail: "Frosts the window and its chrome. Off, everything draws on flat carbon.",
                    isOn: $appearance.isGlassEnabled
                )

                PanelDivider()

                // The peak measures itself, so switching this resizes the sheet
                // even while it is on screen.
                PanelPickerRow(
                    title: "Peek",
                    symbol: "rectangle.portrait.bottomhalf.filled",
                    options: FlightInfoPeakStyle.allCases,
                    label: { $0.label },
                    detail: appearance.peakStyle.detail,
                    selection: $appearance.peakStyle
                )
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
