import SwiftUI

/// A list of pilots: somebody's followers, who they follow, or the results of a
/// search.
///
/// One panel for all three because they are one thing — a page of
/// `pilot_summary` rows with a title on it — and because the empty state, the
/// live-flight marks and the paging behaviour are exactly the things that would
/// be got subtly wrong in a second copy.
struct PilotListPanel: View {

    let title: String
    let handle: String
    let direction: PilotDirectory.Direction

    @EnvironmentObject private var feed: LiveFeed

    /// A profile opened from a row.
    ///
    /// Presented from here rather than handed back to whoever presented this
    /// panel. A callback would mean the presenter raising a second sheet while
    /// this one is still on screen, which SwiftUI drops — the list would close
    /// and nothing would open.
    @State private var opened: ProfileLink?

    @State private var pilots: [PilotSummary] = []
    @State private var isLoading = true

    /// Set once a page comes back short, so scrolling to the bottom stops
    /// asking for more.
    @State private var isComplete = false

    private static let pageSize = 60

    var body: some View {
        MapPanel(title: title, subtitle: subtitle) {
            if isLoading && pilots.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            } else if pilots.isEmpty {
                PanelSection(title: title.uppercased()) {
                    PanelEmptyState(
                        symbol: "person.2",
                        title: "Nobody yet",
                        detail: direction == .followers
                            ? "Nobody is following @\(handle) — or their followers aren't public."
                            : "@\(handle) isn't following anybody yet."
                    )
                }
            } else {
                PanelSection(title: title.uppercased()) {
                    ForEach(Array(pilots.enumerated()), id: \.element.id) { index, pilot in
                        if index > 0 { PanelDivider() }
                        PilotRow(
                            pilot: pilot,
                            isFlying: isFlying(pilot),
                            onOpen: { opened = .handle(pilot.handle) }
                        )
                        // The next page is asked for when the last row it has
                        // appears, rather than from a button. There is no
                        // "load more" to tap because the list is not something
                        // anybody came here to operate.
                        .onAppear {
                            guard index == pilots.count - 1 else { return }
                            Task { await loadMore() }
                        }
                    }
                }
            }
        }
        .task { await loadMore() }
        // Erased for the same reason `PublicProfileView` erases this one: the
        // two types present each other, and an opaque type cannot be defined
        // in terms of itself.
        .sheet(item: $opened) { link in
            AnyView(PublicProfileView(link: link).environmentObject(feed))
        }
    }

    private var subtitle: String {
        pilots.isEmpty ? "@\(handle)" : "@\(handle) · \(pilots.count) shown"
    }

    /// Whether the feed can see this pilot right now, matched on the Infinite
    /// Flight name they claim. Built per row rather than as a set because a
    /// page is sixty names and the packet is thousands of aircraft — but only
    /// once the list is on screen, which is why it is not done in `load`.
    private func isFlying(_ pilot: PilotSummary) -> Bool {
        guard let name = pilot.ifUsername?.lowercased(), !name.isEmpty else { return false }
        return feed.flights.contains { $0.username?.lowercased() == name }
    }

    @MainActor
    private func loadMore() async {
        guard !isComplete else { return }

        isLoading = true
        defer { isLoading = false }

        let page = await PilotDirectory.shared.connections(
            of: handle,
            direction: direction,
            limit: Self.pageSize,
            offset: pilots.count
        )

        if page.count < Self.pageSize { isComplete = true }

        // Merged rather than appended: a follow made while this list was open
        // shifts the offset, and the same pilot can otherwise arrive twice.
        let known = Set(pilots.map(\.handle))
        pilots += page.filter { !known.contains($0.handle) }
    }
}

/// Finding somebody.
///
/// Two characters minimum, matched against handles, display names and the
/// Infinite Flight names people claim — so a pilot seen on the map can be
/// looked up by the name on their tail.
struct PilotSearchPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var query = ""
    @State private var results: [PilotSummary] = []
    @State private var isSearching = false
    @State private var opened: ProfileLink?
    @FocusState private var isTyping: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Pilots", subtitle: "Find somebody on Inflight") {
            PanelSection(title: "SEARCH") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textDim)

                    TextField("Handle, name or Infinite Flight name", text: $query)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isTyping)

                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if isSearching {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if !results.isEmpty {
                PanelSection(title: "RESULTS") {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, pilot in
                        if index > 0 { PanelDivider() }
                        PilotRow(
                            pilot: pilot,
                            isFlying: isFlying(pilot),
                            onOpen: { opened = .handle(pilot.handle) }
                        )
                    }
                }
            } else if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                PanelSection(title: "RESULTS") {
                    PanelEmptyState(
                        symbol: "person.crop.circle.badge.questionmark",
                        title: "Nobody by that name",
                        detail: "Handles are exact. Try the start of one, or the Infinite Flight name they fly under."
                    )
                }
            } else {
                PanelSection(title: "RESULTS") {
                    PanelEmptyState(
                        symbol: "magnifyingglass",
                        title: "Two letters is enough",
                        detail: "Search by handle, by the name somebody goes by, or by the Infinite Flight name on their aeroplane."
                    )
                }
            }
        }
        // Debounced by cancelling: `task(id:)` tears down the previous one on
        // every keystroke, so a fast typist makes one request rather than one
        // per letter, and a slow connection cannot deliver stale results over
        // fresh ones.
        .task(id: query) { await runSearch() }
        .sheet(item: $opened) { link in
            AnyView(PublicProfileView(link: link).environmentObject(feed))
        }
    }

    @MainActor
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }

        results = await PilotDirectory.shared.search(trimmed)
    }

    private func isFlying(_ pilot: PilotSummary) -> Bool {
        guard let name = pilot.ifUsername?.lowercased(), !name.isEmpty else { return false }
        return feed.flights.contains { $0.username?.lowercased() == name }
    }
}

/// Reporting a profile.
///
/// Required of anything with user-generated content, and written to be used
/// rather than to satisfy a requirement: the reasons are in the order somebody
/// scanning for theirs would find it, the detail box is optional, and the
/// answer says what actually happens next rather than thanking them.
struct ReportProfileSheet: View {

    let handle: String

    /// Returns a message when it failed, nil when it worked.
    let submit: (PilotDirectory.ReportReason, String) async -> String?

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.dismiss) private var dismiss

    @State private var reason: PilotDirectory.ReportReason = .sexual
    @State private var detail = ""
    @State private var isSending = false
    @State private var problem: String?
    @State private var isSent = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Report", subtitle: "@\(handle)") {
            if isSent {
                PanelSection(title: "SENT") {
                    PanelEmptyState(
                        symbol: "checkmark.circle",
                        title: "Thanks — it's with us",
                        detail: "A few reports take a profile out of public view straight away, and every one of them is looked at. You won't be told who else reported it."
                    )
                }
            } else {
                PanelSection(title: "WHAT'S WRONG") {
                    ForEach(Array(PilotDirectory.ReportReason.allCases.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { PanelDivider() }
                        PanelCheckRow(
                            title: option.label,
                            symbol: symbol(option),
                            isOn: reason == option
                        ) {
                            reason = option
                        }
                    }
                }

                PanelSection(title: "ANYTHING ELSE (OPTIONAL)") {
                    TextField("What should we look at?", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }

                if let problem = problem {
                    Text(problem)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 2)
                }

                Button {
                    Task { await send() }
                } label: {
                    Text(isSending ? "Sending…" : "Send report")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                                .fill(theme.accent)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
        }
    }

    private func symbol(_ reason: PilotDirectory.ReportReason) -> String {
        switch reason {
        case .sexual: return "eye.slash"
        case .hate: return "exclamationmark.bubble"
        case .harassment: return "person.crop.circle.badge.exclamationmark"
        case .impersonation: return "person.2.slash"
        case .spam: return "megaphone"
        case .violence: return "exclamationmark.triangle"
        case .other: return "ellipsis.circle"
        }
    }

    @MainActor
    private func send() async {
        isSending = true
        problem = nil
        defer { isSending = false }

        if let failure = await submit(reason, detail) {
            problem = failure
        } else {
            isSent = true
        }
    }
}
