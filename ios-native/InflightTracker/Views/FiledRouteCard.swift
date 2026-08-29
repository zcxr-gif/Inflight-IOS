import SwiftUI

/// The route as filed, in the flight window: every fix on it, in order, with
/// the one being flown to picked out.
///
/// The map draws the same plan as a line with the fixes named along it. This is
/// the other half of the same answer — the map tells you the shape of the
/// route, and this tells you what it is called and how far the next bit of it
/// is.
///
/// Presentational: the window fetches the plan, and only puts this in the tree
/// when there is one. Most pilots file nothing, and a card that renders itself
/// as an invisible nothing still costs the stack it sits in a gap the width of
/// its spacing.
struct FiledRouteCard: View {

    let flight: Flight
    let waypoints: [PlanWaypoint]
    let theme: FlightInfoTheme

    private var leg: PlanProgress.Leg? {
        PlanProgress.next(in: waypoints, from: flight.coordinate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let leg = leg {
                nextFix(leg)
            }

            fixes
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("FILED ROUTE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)

            Spacer(minLength: 6)

            Text("\(waypoints.count) FIX\(waypoints.count == 1 ? "" : "ES")")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .fixedSize()
        }
    }

    private func nextFix(_ leg: PlanProgress.Leg) -> some View {
        HStack(spacing: 8) {
            MiniStat(label: "NEXT FIX", value: leg.waypoint.name, theme: theme)

            MiniStat(
                label: "DISTANCE",
                value: "\(Format.number(leg.distanceNM)) NM",
                theme: theme,
                alignment: .center,
                figure: leg.distanceNM
            )

            MiniStat(
                label: "TO RUN",
                value: leg.timeToRun(groundSpeedKnots: flight.groundSpeedKnots)
                    .map({ Format.duration($0) }) ?? "—",
                theme: theme,
                alignment: .trailing
            )
        }
    }

    /// The whole plan, scrolled sideways rather than wrapped: a long-haul files
    /// forty fixes, and a block of forty names is a paragraph nobody reads. It
    /// opens parked on the fix being flown to, which is the part anybody wants
    /// first.
    private var fixes: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(waypoints) { waypoint in
                        chip(for: waypoint)
                            .id(waypoint.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .onChange(of: leg?.waypoint.id) { _, id in
                guard let id = id else { return }
                withAnimation(Motion.row) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                guard let id = leg?.waypoint.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func chip(for waypoint: PlanWaypoint) -> some View {
        let isNext = waypoint.id == leg?.waypoint.id

        return Text(waypoint.name)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isNext ? theme.onAccent : theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isNext ? theme.accent : theme.elevatedFill)
            }
            .fixedSize()
    }
}
