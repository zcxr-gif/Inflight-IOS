import SwiftUI

/// The app's main UI, opened from the button in the top right.
///
/// This is where the tracker's controls collect: the server the feed is joined
/// to and the window's appearance today, with settings, map filters and ATC to
/// follow. The button replaces the old status capsule, so the map's chrome is
/// one weather chip on the left and one control button on the right.
struct ControlHubButton: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Presentation is owned by the map, which can only have one sheet up at a
    /// time — the flight window uses the same one.
    let action: () -> Void

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay { Capsule().fill(Color.black.opacity(0.16)) }
                    .overlay { Capsule().strokeBorder(theme.stroke, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Controls")
        .environment(\.colorScheme, .dark)
    }

    private var statusColor: Color {
        switch feed.status {
        case .live: return .green
        case .connecting, .idle: return .orange
        case .offline: return .red
        }
    }
}

/// Contents of the hub. Each future area gets its row here, so wiring one up
/// is a matter of replacing its placeholder with a destination.
struct ControlHubPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                section("FEED") {
                    VStack(spacing: 0) {
                        ForEach(AppConfig.servers, id: \.self) { server in
                            serverRow(server)

                            if server != AppConfig.servers.last {
                                Rectangle().fill(theme.stroke).frame(height: 1)
                            }
                        }
                    }
                }

                section("APPEARANCE") {
                    Toggle(isOn: $appearance.isGlassEnabled) {
                        rowLabel("Glass flight info", symbol: "square.on.square.dashed")
                    }
                    .tint(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                section("COMING NEXT") {
                    VStack(spacing: 0) {
                        placeholder("Settings", symbol: "gearshape.fill")
                        Rectangle().fill(theme.stroke).frame(height: 1)
                        placeholder("Map filters", symbol: "line.3.horizontal.decrease.circle.fill")
                        Rectangle().fill(theme.stroke).frame(height: 1)
                        placeholder("ATC", symbol: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .padding(16)
        }
        .background { theme.windowFill.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Controls")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                // The sprite check surfaces a packaging problem that otherwise
                // just looks like an empty map, which is hard to diagnose from
                // a TestFlight build.
                Text(PlaneSprites.shared.isReady ? feedSummary : "Sprite sheet missing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }

            Spacer(minLength: 8)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
        }
    }

    private var feedSummary: String {
        guard feed.status.isLive else { return feed.status.label }
        return "\(feed.flights.count) aircraft · \(feed.server)"
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
                .padding(.leading, 2)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private func serverRow(_ server: String) -> some View {
        Button {
            feed.select(server: server)
        } label: {
            HStack(spacing: 10) {
                rowLabel(
                    server.replacingOccurrences(of: " Server", with: ""),
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

    private func placeholder(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            rowLabel(title, symbol: symbol)

            Spacer(minLength: 8)

            Text("SOON")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background { Capsule().fill(theme.elevatedFill) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(0.55)
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.8)
        }
    }
}
