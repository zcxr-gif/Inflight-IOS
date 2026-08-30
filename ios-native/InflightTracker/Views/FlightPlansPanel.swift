import SwiftUI

/// The pilot's own plans: what they mean to fly, and from and to which stand.
///
/// The third of the three tenses this app keeps, and the only one nobody
/// measures. The map is the present, the logbook is the past, and this is the
/// part that used to live on a piece of paper beside the iPad.
///
/// Reads `FlightPlanBook`, which needs an account — see the note there on why
/// this is the one store in the app that does.
struct FlightPlansPanel: View {

    /// A field to start a new plan from, when the panel was opened from one.
    /// Saves typing an ICAO somebody is already looking at.
    var startingFrom: String? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var book = FlightPlanBook.shared
    @ObservedObject private var accounts = AccountStore.shared

    /// The plan being edited, when one is. A brand-new plan is a blank
    /// `PlannedFlight`, which is why this is the plan itself rather than a
    /// flag: the editor takes what it is editing.
    @State private var editing: EditorTarget?

    /// `sheet(item:)` needs an identity, and a blank plan's own id is the empty
    /// string it does not have yet — which would collide with itself if two
    /// were ever opened in a row.
    private struct EditorTarget: Identifiable {
        let plan: PlannedFlight
        let id: String
    }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Flight plans", subtitle: subtitle) {
            if !accounts.isSignedIn {
                signedOut
            } else {
                filing

                if book.isLoading && !book.hasAnswered {
                    loading
                } else {
                    section(title: "UPCOMING", plans: book.upcoming, empty: emptyUpcoming)
                    section(title: "EARLIER", plans: book.past, empty: nil)
                }

                if let problem = book.problem { trouble(problem) }
            }
        }
        .task { await book.loadIfNeeded() }
        .sheet(item: $editing) { target in
            FlightPlanEditor(target.plan)
        }
    }

    private var subtitle: String? {
        guard accounts.isSignedIn else { return "Sign in to keep your plans" }
        let count = book.upcoming.count
        switch count {
        case 0: return book.hasAnswered ? "Nothing planned" : nil
        case 1: return "1 flight planned"
        default: return "\(count) flights planned"
        }
    }

    // MARK: - States

    private var signedOut: some View {
        PanelSection(title: "ACCOUNT") {
            PanelEmptyState(
                symbol: "person.crop.circle.badge.questionmark",
                title: "Plans need an account",
                detail: "A flight plan has to survive a new phone, so it lives with your account rather than on this device. Sign in from Settings and it will be here."
            )
        }
    }

    private var loading: some View {
        PanelSection(title: "PLANS") {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your plans…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var filing: some View {
        PanelSection(title: "NEW") {
            PanelActionRow(
                title: startingFrom.map { "Plan a flight from \($0)" } ?? "Plan a flight",
                symbol: "plus.circle",
                detail: "Both ends, the stand at each, and when you mean to go."
            ) {
                editing = EditorTarget(
                    plan: PlannedFlight.blank(from: startingFrom ?? ""),
                    id: "new-\(UUID().uuidString)"
                )
            }
        }
    }

    private var emptyUpcoming: PanelEmptyState {
        PanelEmptyState(
            symbol: "calendar.badge.plus",
            title: "Nothing planned yet",
            detail: "File one and it shows up here — with the gate you are leaving from and the one you are aiming for."
        )
    }

    @ViewBuilder
    private func section(title: String, plans: [PlannedFlight], empty: PanelEmptyState?) -> some View {
        if !plans.isEmpty {
            PanelSection(title: "\(title) · \(plans.count)") {
                ForEach(plans) { plan in
                    if plan.id != plans.first?.id { PanelDivider() }
                    PlanRow(plan: plan, theme: theme) {
                        editing = EditorTarget(plan: plan, id: plan.id)
                    }
                }
            }
        } else if let empty = empty, book.hasAnswered {
            PanelSection(title: title) { empty }
        }
    }

    private func trouble(_ message: String) -> some View {
        PanelSection(title: "TROUBLE") {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try again") {
                    Task { await book.load() }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

/// One plan: the route, the stands, and when.
///
/// Three lines, in the order somebody reads them under time pressure — where
/// am I going, which gate, what time. The gates get their own line and their
/// own type because they are the reason this screen exists.
private struct PlanRow: View {

    let plan: PlannedFlight
    let theme: FlightInfoTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(plan.routeLabel)
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.8)

                        if plan.status != .planned {
                            Text(plan.status.label.uppercased())
                                .font(.system(size: 8.5, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(theme.textDim)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background { Capsule().fill(theme.elevatedFill) }
                        }
                    }

                    if let stands = plan.standsLabel {
                        HStack(spacing: 5) {
                            Image(systemName: "figure.walk.departure")
                                .font(.system(size: 9))
                            Text(stands)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine(minimumScale: 0.75)
                    }

                    if let line = scheduleLine {
                        Text(line)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .flightInfoLine(minimumScale: 0.75)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .accessibilityLabel(accessibility)
    }

    /// The schedule as one line. Written out rather than run through a range
    /// formatter because the two halves are independently optional — a plan
    /// with only a departure time is ordinary, and `Date.FormatStyle` has no
    /// spelling for half a range.
    private var scheduleLine: String? {
        let out = plan.scheduledOut.map { Self.stamp($0) }
        let arrive = plan.scheduledIn.map { Self.stamp($0) }

        switch (out, arrive) {
        case let (.some(out), .some(arrive)):
            let block = plan.blockMinutes.map { " · \($0 / 60)h \(String(format: "%02d", $0 % 60))m" } ?? ""
            return "\(out) → \(arrive)\(block)"
        case let (.some(out), .none):
            return "Off blocks \(out)"
        case let (.none, .some(arrive)):
            return "On blocks \(arrive)"
        case (.none, .none):
            let parts = [plan.callsign, plan.aircraft].filter { !$0.isEmpty }
            return parts.isEmpty ? "No time set" : parts.joined(separator: " · ")
        }
    }

    /// Local time, because a plan is something somebody makes around their own
    /// evening. The logbook and the feed are in Zulu; this is a calendar.
    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var accessibility: String {
        var parts = ["\(plan.originICAO) to \(plan.destinationICAO)"]
        if let stands = plan.standsLabel { parts.append(stands) }
        if let line = scheduleLine { parts.append(line) }
        return parts.joined(separator: ", ")
    }
}
