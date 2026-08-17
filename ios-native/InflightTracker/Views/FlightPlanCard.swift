import SwiftUI

/// The route this aircraft filed, fix by fix.
///
/// Collapsed it is what is coming: the fix being flown to and the next few
/// after it, which is what you want while watching an aeroplane move. Opened it
/// is the whole plan from the departure procedure to the approach, with what
/// has already been passed dimmed rather than dropped — a route reads as a
/// route, and cutting the flown half off leaves a list starting nowhere.
struct FlightPlanCard: View {

    let plan: FlightPlan
    let flight: Flight
    let theme: FlightInfoTheme

    @State private var isExpanded = false

    /// Where the aircraft has got to. Nil for one that has not started down the
    /// route yet — a plan filed at the gate — in which case nothing is passed
    /// and everything is still to come.
    private var activeIndex: Int? {
        plan.activeIndex(for: flight)
    }

    /// How many fixes the collapsed card shows, counting from the active one.
    /// Enough to see where the next turn is without the card becoming the
    /// window.
    private static let collapsedCount = 4

    private var visible: [(offset: Int, waypoint: FlightPlanWaypoint)] {
        let all = Array(plan.waypoints.enumerated()).map { (offset: $0.offset, waypoint: $0.element) }
        guard !isExpanded else { return all }

        let start = activeIndex ?? 0
        return Array(all[start...].prefix(Self.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                ForEach(visible, id: \.waypoint.id) { entry in
                    if entry.offset != visible.first?.offset {
                        Rectangle().fill(theme.stroke).frame(height: 1)
                    }

                    row(entry.waypoint, index: entry.offset)
                }
            }
            .flightInfoSurface(theme, radius: theme.radiusSmall)

            if plan.waypoints.count > visible.count || isExpanded {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded
                             ? "Show what is ahead"
                             : "Show all \(plan.waypoints.count) fixes")
                            .font(.system(size: 11, weight: .semibold))

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background { Capsule().fill(theme.elevatedFill) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("FILED ROUTE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)

            Spacer(minLength: 6)

            Text("\(plan.waypoints.count) fixes · \(Format.number(plan.totalDistanceNM)) NM")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .fixedSize()
        }
    }

    private func row(_ waypoint: FlightPlanWaypoint, index: Int) -> some View {
        let isActive = index == activeIndex
        let isPassed = activeIndex.map { index < $0 } ?? false

        return HStack(spacing: 10) {
            // The spine: a filled dot for the fix being flown to, hollow for
            // everything else, joined by the rule between rows. It reads as a
            // route rather than as a list of names.
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: isActive ? 13 : 9))
                .foregroundStyle(isActive ? theme.accent : theme.textDim)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.identifier)
                    .font(.system(size: 13.5, weight: isActive ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                if let group = waypoint.group.label {
                    Text(group)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(distanceLabel(to: waypoint))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)

                if let altitude = waypoint.altitudeLabel {
                    Text(altitude)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Passed fixes stay on the list and step back out of the way, the same
        // way an off filter row does.
        .opacity(isPassed ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(waypoint, isActive: isActive, isPassed: isPassed))
    }

    /// How far the fix is from the aircraft right now. Signed by nothing — a
    /// passed fix is dimmed rather than given a negative distance, which is not
    /// a thing a distance is.
    private func distanceLabel(to waypoint: FlightPlanWaypoint) -> String {
        let distance = FlightProgress.distanceNM(from: flight.coordinate, to: waypoint.coordinate)
        return "\(Format.number(distance)) NM"
    }

    private func accessibilityLabel(
        _ waypoint: FlightPlanWaypoint,
        isActive: Bool,
        isPassed: Bool
    ) -> String {
        var parts = [waypoint.identifier]
        if let group = waypoint.group.label { parts.append(group) }
        parts.append(distanceLabel(to: waypoint))
        if let altitude = waypoint.altitudeLabel { parts.append(altitude) }
        if isActive { parts.append("next fix") }
        if isPassed { parts.append("passed") }
        return parts.joined(separator: ", ")
    }
}
