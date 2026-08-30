import SwiftUI

/// Filing a flight: where from, where to, which stand at each end, and when.
///
/// ## What is free and what is Pro, on one screen
///
/// All of the fields are free. Both gates are free. The schedule is free. The
/// only thing behind the subscription is the *map* — the button beside each
/// gate field that opens the airport, draws every stand on it and lets you tap
/// one. A free account types `B24`; a Pro account taps B24; the row that
/// reaches the server is the same row either way.
///
/// That is a deliberate shape and worth being plain about, because the
/// tempting version — gates for Pro, times for free — would have made the
/// feature useless to most people in order to sell it to a few. What is
/// actually worth paying for here is not the ability to record a gate. It is
/// not having to know, at an airport you have never flown into, whether the
/// stand you want is called 543 or B43.
struct FlightPlanEditor: View {

    /// The plan as it arrived. A blank one from `PlannedFlight.blank` is a new
    /// plan; anything else is an amendment.
    let original: PlannedFlight

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var book = FlightPlanBook.shared
    @ObservedObject private var entitlements = Entitlements.shared

    @State private var draft: PlannedFlight

    /// The two schedule fields are optional in the table, and a `DatePicker`
    /// cannot express "no time". So each gets a switch, and the date behind it
    /// is only sent when the switch is on.
    @State private var hasDeparture = false
    @State private var hasArrival = false
    @State private var departureTime = Date()
    @State private var arrivalTime = Date()

    /// Which end's map is open, when one is.
    @State private var picking: GateMapPicker.Role?

    @State private var isShowingPaywall = false
    @State private var isConfirmingDelete = false

    init(_ plan: PlannedFlight) {
        self.original = plan
        _draft = State(initialValue: plan)
    }

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: original.isSaved ? "Edit plan" : "Plan a flight", subtitle: summary) {
            route
            gates
            schedule
            aircraft
            notes
            if original.isSaved { progress }
            actions
            if let problem = book.problem { trouble(problem) }
        }
        .onAppear(perform: seedSchedule)
        .sheet(item: $picking) { role in picker(role) }
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .gateMap) }
    }

    private var summary: String {
        guard draft.isComplete else { return "Both ends, then everything else." }
        let name = AirportStore.shared.airport(draft.destinationICAO)?.name
        return name.map { "\(draft.routeLabel) · \($0)" } ?? draft.routeLabel
    }

    // MARK: - Route

    private var route: some View {
        PanelSection(title: "ROUTE") {
            FieldRow(
                title: "From",
                symbol: "airplane.departure",
                placeholder: "ICAO",
                detail: airportName(draft.originICAO),
                text: Binding(
                    get: { draft.originICAO },
                    set: { draft.originICAO = $0.uppercased() }
                )
            )

            PanelDivider()

            FieldRow(
                title: "To",
                symbol: "airplane.arrival",
                placeholder: "ICAO",
                detail: airportName(draft.destinationICAO),
                text: Binding(
                    get: { draft.destinationICAO },
                    set: { draft.destinationICAO = $0.uppercased() }
                )
            )
        }
    }

    /// The field's own name under the code, so a typo is visible before it is
    /// saved rather than after. Silent about a code that resolves to nothing —
    /// the offline table is large but not complete, and telling somebody their
    /// perfectly real airstrip does not exist would be wrong.
    private func airportName(_ icao: String) -> String? {
        AirportStore.shared.airport(icao)?.name
    }

    // MARK: - Gates

    private var gates: some View {
        PanelSection(title: "GATES") {
            GateRow(
                role: .departure,
                icao: draft.originICAO,
                stand: $draft.departureStand,
                canOpenMap: entitlements.isPro,
                onOpenMap: { open(.departure) }
            )

            PanelDivider()

            GateRow(
                role: .arrival,
                icao: draft.destinationICAO,
                stand: $draft.arrivalStand,
                canOpenMap: entitlements.isPro,
                onOpenMap: { open(.arrival) }
            )

            PanelDivider()

            Text(gateFootnote)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var gateFootnote: String {
        entitlements.isPro
            ? "Type a stand, or tap the map button to pick one off the field."
            : "Type the stand you want. Inflight Pro adds the airport map: open the field, see every stand on it, and tap one."
    }

    /// Opening the map needs a field to open and a subscription to open it
    /// with. Both refusals are quiet and specific rather than a disabled
    /// button, which explains nothing.
    private func open(_ role: GateMapPicker.Role) {
        guard entitlements.isPro else {
            isShowingPaywall = true
            return
        }
        picking = role
    }

    @ViewBuilder
    private func picker(_ role: GateMapPicker.Role) -> some View {
        let icao = role == .departure ? draft.originICAO : draft.destinationICAO

        if let airport = AirportStore.shared.airport(icao) {
            GateMapPicker(
                airport: airport,
                role: role,
                selected: role == .departure ? draft.departureStand : draft.arrivalStand
            ) { stand in
                switch role {
                case .departure: draft.departureStand = stand
                case .arrival: draft.arrivalStand = stand
                }
            }
        } else {
            // Reached by opening the map for an ICAO the offline table has
            // never heard of. A sheet that says why beats one that is blank.
            MapPanel(title: "No such field", subtitle: icao.isEmpty ? nil : icao) {
                PanelEmptyState(
                    symbol: "questionmark.circle",
                    title: "That airport isn't in the dataset",
                    detail: "Check the ICAO, or type the stand by hand — a plan does not need the map."
                )
            }
        }
    }

    // MARK: - Schedule

    private var schedule: some View {
        PanelSection(title: "SCHEDULE") {
            PanelToggleRow(
                title: "Off blocks",
                symbol: "clock",
                detail: "When you mean to push back.",
                isOn: $hasDeparture
            )

            if hasDeparture {
                DatePicker(
                    "Off blocks",
                    selection: $departureTime,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            PanelDivider()

            PanelToggleRow(
                title: "On blocks",
                symbol: "clock.badge.checkmark",
                detail: arrivalDetail,
                isOn: $hasArrival
            )

            if hasArrival {
                DatePicker(
                    "On blocks",
                    selection: $arrivalTime,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .motion(Motion.content, value: hasDeparture)
        .motion(Motion.content, value: hasArrival)
    }

    /// Says the block time back once both ends are set, which is the one thing
    /// a pair of times is worth computing: it is how somebody notices they have
    /// planned a four-minute transatlantic.
    private var arrivalDetail: String {
        guard hasDeparture, hasArrival else { return "When you mean to be on stand." }
        let minutes = Int(arrivalTime.timeIntervalSince(departureTime) / 60)
        guard minutes > 0 else { return "That is before you leave." }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m block time."
    }

    // MARK: - The rest

    private var aircraft: some View {
        PanelSection(title: "AIRCRAFT") {
            FieldRow(
                title: "Callsign",
                symbol: "dot.radiowaves.left.and.right",
                placeholder: "BAW117",
                text: $draft.callsign
            )

            PanelDivider()

            FieldRow(
                title: "Type",
                symbol: "airplane",
                placeholder: "B77W",
                text: $draft.aircraft
            )

            PanelDivider()

            FieldRow(
                title: "Livery",
                symbol: "paintbrush",
                placeholder: "British Airways",
                autocapitalisation: .words,
                text: $draft.livery
            )
        }
    }

    private var notes: some View {
        PanelSection(title: "REMARKS") {
            FieldRow(
                title: "Notes",
                symbol: "text.alignleft",
                placeholder: "Anything worth remembering",
                autocapitalisation: .sentences,
                text: $draft.remarks
            )
        }
    }

    private var progress: some View {
        PanelSection(title: "STATUS") {
            PanelPickerRow(
                title: "This plan",
                symbol: draft.status.symbol,
                options: PlannedFlight.Status.allCases,
                label: { $0.label },
                detail: "Flown and cancelled plans stay in the list — the quickest way to plan a leg is to copy one you have already flown.",
                selection: $draft.status
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: save) {
                HStack(spacing: 8) {
                    if book.isSaving {
                        ProgressView().controlSize(.small).tint(theme.onAccent)
                    }
                    Text(original.isSaved ? "Save changes" : "File this plan")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(draft.isComplete ? theme.onAccent : theme.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                        .fill(draft.isComplete ? theme.accent : theme.elevatedFill)
                }
            }
            .buttonStyle(.pressable(scale: 0.98))
            .disabled(!draft.isComplete || book.isSaving)

            if original.isSaved {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Text("Delete this plan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Delete this plan?",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { delete() }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("\(original.routeLabel) will be removed from your plans.")
                }
            }
        }
    }

    private func trouble(_ message: String) -> some View {
        PanelSection(title: "THAT DIDN'T SAVE") {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    // MARK: - Doing it

    /// Reads the two optional timestamps into the switch-and-date pair the
    /// pickers need.
    ///
    /// A new plan starts with the departure switch off and the date at the next
    /// round hour, which is a better guess than "now" — nobody schedules a
    /// pushback for 14:37 — and an arrival an hour and a half after it, which
    /// is only ever a starting point somebody drags.
    private func seedSchedule() {
        hasDeparture = draft.scheduledOut != nil
        hasArrival = draft.scheduledIn != nil

        let nextHour = Calendar.current.date(
            bySetting: .minute,
            value: 0,
            of: Date().addingTimeInterval(3600)
        ) ?? Date().addingTimeInterval(3600)

        departureTime = draft.scheduledOut ?? nextHour
        arrivalTime = draft.scheduledIn ?? departureTime.addingTimeInterval(90 * 60)
    }

    private func save() {
        draft.scheduledOut = hasDeparture ? departureTime : nil
        draft.scheduledIn = hasArrival ? arrivalTime : nil

        Task {
            if await book.save(draft) { dismiss() }
        }
    }

    private func delete() {
        Task {
            if await book.delete(original) { dismiss() }
        }
    }
}

// MARK: - Rows

/// A labelled text field on a panel card.
///
/// Not in `PanelComponents` yet, and deliberately: it is the first row in the
/// app that takes typing, and a shared component built from one caller is a
/// component shaped by one caller. It moves there the day a second panel wants
/// one.
private struct FieldRow: View {

    let title: String
    let symbol: String
    let placeholder: String
    var detail: String? = nil
    var autocapitalisation: TextInputAutocapitalization = .characters
    @Binding var text: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                PanelRowLabel(title: title, symbol: symbol)

                Spacer(minLength: 12)

                TextField(placeholder, text: $text)
                    .font(.system(size: 14, weight: .semibold, design: monospaced ? .monospaced : .default))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(autocapitalisation)
                    .autocorrectionDisabled(monospaced)
                    .submitLabel(.done)
            }

            if let detail = detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.leading, 30)
                    .flightInfoLine(minimumScale: 0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Codes get the monospaced face; prose does not. An ICAO and a callsign
    /// are read a character at a time, and a proportional zero next to a
    /// proportional O is how a typo survives being looked at.
    private var monospaced: Bool { autocapitalisation == .characters }
}

/// One end's stand: the name, and the way to the map.
private struct GateRow: View {

    let role: GateMapPicker.Role
    let icao: String
    @Binding var stand: PlannedFlight.Stand?
    let canOpenMap: Bool
    let onOpenMap: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var title: String {
        role == .departure ? "Departure gate" : "Arrival gate"
    }

    /// Typing into the field keeps whatever name is typed and drops the
    /// coordinate, which is the honest thing to do: the point belonged to the
    /// stand that was tapped, and this is now a different stand.
    private var text: Binding<String> {
        Binding(
            get: { stand?.ref ?? "" },
            set: { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    stand = nil
                    return
                }
                if let existing = stand, existing.ref == trimmed { return }
                stand = PlannedFlight.Stand(ref: String(trimmed.prefix(12)))
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                PanelRowLabel(title: title, symbol: "figure.walk.departure")

                Spacer(minLength: 8)

                TextField("Gate", text: text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .frame(maxWidth: 110)

                Button(action: onOpenMap) {
                    Image(systemName: canOpenMap ? "map.fill" : "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canOpenMap ? theme.onAccent : theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(canOpenMap ? theme.accent : theme.elevatedFill)
                        }
                }
                .buttonStyle(.pressable(scale: 0.94))
                .disabled(icao.count < 3)
                .opacity(icao.count < 3 ? 0.4 : 1)
                .accessibilityLabel(
                    canOpenMap
                        ? "Pick the \(role == .departure ? "departure" : "arrival") gate on the airport map"
                        : "Picking a gate on the map is part of Inflight Pro"
                )
            }

            if let detail = detail {
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.leading, 30)
                    .flightInfoLine(minimumScale: 0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Says where the map would open, or that it cannot open anywhere yet —
    /// which is the answer to "why is that button dim".
    private var detail: String? {
        guard icao.count >= 3 else {
            return "Fill in the \(role == .departure ? "departure" : "arrival") airport first."
        }
        if stand?.coordinate != nil { return "Picked at \(icao)." }
        return AirportStore.shared.airport(icao)?.name ?? icao
    }
}

/// The picker's two roles are what `sheet(item:)` keys on, so they need an id.
extension GateMapPicker.Role: Identifiable {

    var id: String {
        switch self {
        case .departure: return "departure"
        case .arrival: return "arrival"
        }
    }
}
