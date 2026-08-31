import SwiftUI

/// Filing the flight you are actually making, from the window that is already
/// showing it.
///
/// The plans panel has always been able to do this, and asks you to type every
/// field of it: both ICAOs, the callsign, the aircraft, the livery. All five of
/// those are on screen in front of you the moment your own aeroplane is open,
/// which is what this row is — the same editor, with the aeroplane's own
/// details already in it.
///
/// ## Whose flight it has to be
///
/// Yours, and there is no second way to read that. A plan is a row in
/// `pilot_flight_plans` that belongs to an account, so filing somebody else's
/// aircraft would not be filing *their* plan — it would be writing a claim
/// about your own flying out of an aeroplane you are not in. So the row is
/// absent, not disabled, on every aircraft but the one flying under this
/// pilot's own name: a control that appears on three thousand aeroplanes and
/// works on one is a control that reads as broken.
///
/// The name is `PilotIdentity`'s, which is the same field the website holds and
/// the same one "find my aircraft" matches on. It is set by the person holding
/// the phone rather than proved by anything, which is fine for what it gates
/// here: nothing on the server is unlocked by it, and the row it leads to
/// writes only into the caller's own account either way.
///
/// ## And an account
///
/// `FlightPlanBook` is the one store in this app that needs a sign-in — a plan
/// has to survive a new phone, so it lives with the account rather than in this
/// install's defaults. The row still appears signed out, and says so, rather
/// than vanishing: somebody looking at their own aeroplane should find out that
/// this exists, not that it doesn't.
struct FileThisFlightRow: View {

    let flight: Flight
    let theme: FlightInfoTheme

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var identity = PilotIdentity.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var book = FlightPlanBook.shared

    /// The editor, once it is open. Carries its own id because a plan that has
    /// never been saved has an empty one — the same reason `FlightPlansPanel`
    /// wraps it.
    @State private var editing: EditorTarget?

    @State private var isShowingAccount = false

    private struct EditorTarget: Identifiable {
        let plan: PlannedFlight
        let id: String
    }

    /// Whether this is the aeroplane this pilot is flying.
    private var isMine: Bool { identity.isMe(flight.username) }

    /// The plan this flight would amend rather than duplicate, when one is
    /// already filed for the same route.
    private var filed: PlannedFlight? {
        book.upcomingPlan(from: flight.departureIcao, to: flight.arrivalIcao)
    }

    var body: some View {
        // Somebody else's aeroplane, or nobody's — nothing to offer.
        if isMine {
            Button(action: open) {
                HStack(spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.8)

                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
                .padding(14)
                .flightInfoSurface(theme, radius: theme.radiusMedium, interactive: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(detail)
            // Only so `filed` can answer. Reads once per launch and not again
            // — see `FlightPlanBook.loadIfNeeded`.
            //
            // Keyed on the sign-in rather than fired once, because the row
            // itself is a way of signing in: somebody who taps it signed out,
            // makes an account and comes back would otherwise be offered a
            // fresh plan for a route they already have one for, having never
            // been in a state where the list could be read.
            .task(id: accounts.isSignedIn) {
                guard accounts.isSignedIn else { return }
                await book.loadIfNeeded()
            }
            .sheet(item: $editing) { target in
                FlightPlanEditor(target.plan)
            }
            .sheet(isPresented: $isShowingAccount) {
                AccountPanel().environmentObject(feed)
            }
        }
    }

    // MARK: - What it says

    private var symbol: String {
        guard accounts.isSignedIn else { return "person.crop.circle.badge.questionmark" }
        return filed == nil ? "calendar.badge.plus" : "calendar.badge.checkmark"
    }

    private var title: String {
        guard accounts.isSignedIn else { return "File this flight" }
        return filed == nil ? "File this flight" : "Update your filed plan"
    }

    private var detail: String {
        guard accounts.isSignedIn else {
            return "Plans live with your account so they survive a new phone. Sign in and this flight fills the form in for you."
        }
        guard let filed = filed else {
            return "Files \(route) with the callsign, aircraft and livery you are flying already in."
        }
        return "You have \(filed.routeLabel) planned. Opens it with what you are actually flying."
    }

    /// The route as the feed reports it, with dashes where it reports nothing —
    /// an aeroplane airborne with no destination filed in the sim can still be
    /// planned, it just starts the editor with one end to fill in.
    private var route: String {
        "\(flight.departureIcao ?? "————") → \(flight.arrivalIcao ?? "————")"
    }

    // MARK: - Opening it

    private func open() {
        guard isMine else { return }

        guard accounts.isSignedIn else {
            isShowingAccount = true
            return
        }

        if let filed = filed {
            editing = EditorTarget(plan: filed.amended(with: flight), id: filed.id)
        } else {
            editing = EditorTarget(
                plan: PlannedFlight.from(flight: flight),
                id: "new-\(UUID().uuidString)"
            )
        }
    }
}
