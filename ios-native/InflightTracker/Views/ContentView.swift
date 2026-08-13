import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @State private var selection: SelectedFlight?

    /// Which phase the info window is in. Owned here so it can be reset to the
    /// peak state each time a different aircraft is tapped.
    @State private var detent: PresentationDetent = .flightInfoPeak

    /// Latest camera request from the buttons beside the info window.
    @State private var mapCommand: MapCommand?

    var body: some View {
        ZStack(alignment: .top) {
            TrackerMapView(
                flights: feed.flights,
                selection: $selection,
                command: mapCommand,
                bottomInset: selection == nil ? 0 : FlightInfoLayout.peakHeight
            )
            .ignoresSafeArea()

            statusBar
                .padding(.horizontal, 16)
                .padding(.top, 8)

            mapControls
        }
        .animation(.easeInOut(duration: 0.22), value: selection?.id)
        .sheet(item: $selection) { selected in
            FlightDetailView(flightId: selected.id)
                .environmentObject(feed)
                .presentationDetents([.flightInfoPeak, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .flightInfoSheetInteraction()
        }
        .onChange(of: selection?.id) { _ in detent = .flightInfoPeak }
        .onAppear { feed.connect() }
    }

    /// Sits above the peak state while an aircraft is open. At the full window
    /// the sheet covers this corner anyway, so there is nothing to hide.
    @ViewBuilder
    private var mapControls: some View {
        if selection != nil {
            VStack(spacing: 10) {
                mapButton("scope", "Centre on aircraft") {
                    mapCommand = MapCommand(kind: .centerOnFlight)
                }
                mapButton("arrow.up.left.and.arrow.down.right", "Show whole route") {
                    mapCommand = MapCommand(kind: .fitRoute)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, FlightInfoLayout.peakHeight + 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    private func mapButton(
        _ symbol: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .accessibilityLabel(label)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(feed.status.isLive ? "\(feed.flights.count) aircraft" : feed.status.label)
                    .font(.system(size: 14, weight: .semibold))
                // Surfaces a packaging problem that would otherwise just look
                // like an empty map, which is hard to diagnose from TestFlight.
                Text(PlaneSprites.shared.isReady ? feed.server : "Sprite sheet missing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Menu {
                Picker("Server", selection: serverBinding) {
                    ForEach(AppConfig.servers, id: \.self) { server in
                        Text(server.replacingOccurrences(of: " Server", with: "")).tag(server)
                    }
                }

                Divider()

                // The switch the whole info window theme hangs off; off falls
                // back to the opaque carbon surfaces.
                Toggle("Glass flight info", isOn: $appearance.isGlassEnabled)
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var serverBinding: Binding<String> {
        Binding(
            get: { feed.server },
            set: { feed.select(server: $0) }
        )
    }

    private var statusColor: Color {
        switch feed.status {
        case .live: return .green
        case .connecting, .idle: return .orange
        case .offline: return .red
        }
    }
}
