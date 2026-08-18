import SwiftUI

/// Who among the people you follow has put one down best.
///
/// Every number here is measured by Infinite Flight rather than worked out from
/// the map, which is what makes a leaderboard defensible at all: a board built
/// on inferred landing rates would be a ranking of who the feed happened to
/// sample closest to the runway.
///
/// It follows from that that the board is empty for most people, and it says
/// so rather than showing zeroes. Somebody has to have flown with Connect
/// attached to be on it.
struct LandingBoardView: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var entries: [PilotLandingBoardEntry] = []
    @State private var window: Window = .month
    @State private var isLoading = true
    @State private var opened: ProfileLink?

    private var theme: FlightInfoTheme { appearance.theme }

    enum Window: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case season = 90

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .week: return "7 days"
            case .month: return "30 days"
            case .season: return "90 days"
            }
        }
    }

    var body: some View {
        MapPanel(title: "Landing board", subtitle: subtitle) {

            PanelSection(title: "WINDOW") {
                PanelPickerRow(
                    title: "Counting",
                    symbol: "calendar",
                    options: Window.allCases,
                    label: { $0.label },
                    selection: $window
                )
            }

            if !accounts.isSignedIn {
                note("Sign in to see how the pilots you follow are landing.")
            } else if isLoading {
                note("Working it out…")
            } else if entries.isEmpty {
                note("Nobody you follow has landed with Infinite Flight Connect attached "
                   + "in this window. Landing rates are measured by the simulator, so a "
                   + "pilot has to have been connected for the landing to count.")
            } else {
                PanelSection(title: "BEST TOUCHDOWN") {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { PanelDivider() }
                        row(entry, place: index + 1)
                    }
                }
            }
        }
        .task(id: window) { await load() }
        .sheet(item: $opened) { link in PublicProfileView(link: link) }
    }

    private var subtitle: String {
        entries.isEmpty ? "Measured by the sim" : "\(entries.count) pilots · measured by the sim"
    }

    private func row(_ entry: PilotLandingBoardEntry, place: Int) -> some View {
        Button {
            opened = .handle(entry.handle)
        } label: {
            HStack(spacing: 11) {
                Text("\(place)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(place <= 3 ? theme.accent : theme.textDim)
                    .frame(width: 20, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(entry.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if entry.isPro {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.accent)
                        }
                        if entry.isSelf {
                            Text("YOU")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.6)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.accent.opacity(0.18)))
                                .foregroundStyle(theme.accent)
                        }
                    }

                    Text("\(entry.landings) landing\(entry.landings == 1 ? "" : "s")"
                       + " · avg \(entry.averageFPM) fpm"
                       + (entry.greasers > 0 ? " · \(entry.greasers) greased" : ""))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(entry.bestFPM)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text(entry.verdict.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(theme.textDim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func load() async {
        guard accounts.isSignedIn else {
            entries = []
            isLoading = false
            return
        }
        isLoading = true
        entries = await PilotDirectory.shared.landingBoard(windowDays: window.rawValue)
        isLoading = false
    }
}
