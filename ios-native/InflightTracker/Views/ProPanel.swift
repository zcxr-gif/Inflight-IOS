import StoreKit
import SwiftUI

/// The paywall.
///
/// It says what Pro is, what it costs in the user's own currency, and what
/// happens if they have already bought it — and then stops. No countdown, no
/// crossed-out price, no "most popular" badge on a product with one tier.
///
/// The list is `ProFeature.allCases` rather than prose, so what is advertised
/// here and what is actually gated cannot drift apart.
struct ProPanel: View {

    /// Which feature the user ran into, when they got here by running into one.
    /// It leads the list, so the answer to "why am I looking at this" is the
    /// first thing on screen.
    var highlighted: ProFeature? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var entitlements = Entitlements.shared

    @Environment(\.dismiss) private var dismiss

    private var theme: FlightInfoTheme { appearance.theme }

    /// The one the user hit first, then the rest in their declared order.
    private var features: [ProFeature] {
        guard let highlighted = highlighted else { return ProFeature.allCases }
        return [highlighted] + ProFeature.allCases.filter { $0 != highlighted }
    }

    var body: some View {
        MapPanel(title: "Inflight Pro", subtitle: subtitle) {
            if entitlements.isPro {
                owned
            } else {
                pitch
            }
        }
        .task { await store.loadProduct() }
        // Bought here, or bought on another device while this was open: either
        // way the sheet has nothing left to sell.
        .onChange(of: entitlements.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    private var subtitle: String {
        if entitlements.isPro { return "Active on this account" }
        guard let price = store.displayPrice else { return "One payment, no subscription" }
        return "\(price) once — not a subscription"
    }

    // MARK: - Already bought

    private var owned: some View {
        PanelSection(title: "ACTIVE") {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(theme.textPrimary)

                Text("You have Inflight Pro")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                Text("Everything below is unlocked.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    // MARK: - The pitch

    @ViewBuilder
    private var pitch: some View {
        PanelSection(title: "WHAT YOU GET") {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                if index > 0 { PanelDivider() }
                featureRow(feature, isHighlighted: feature == highlighted)
            }
        }

        PanelSection(title: "BUY") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await store.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPurchasing {
                            ProgressView().tint(theme.onAccent)
                        }
                        Text(buttonTitle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background {
                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                            .fill(theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isPurchasing || store.isRestoring)
                .opacity(store.isPurchasing || store.isRestoring ? 0.55 : 1)

                if let problem = store.problem {
                    note(problem, symbol: "exclamationmark.triangle")
                }

                if let notice = store.notice {
                    note(notice, symbol: "info.circle")
                }

                Text("Bought once, on your Apple Account. It comes back on any device you sign that account into — no subscription, nothing to cancel.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        PanelSection(title: "ALREADY PAID") {
            PanelActionRow(
                title: store.isRestoring ? "Restoring…" : "Restore purchases",
                symbol: "arrow.clockwise",
                detail: "For a reinstall or a new phone."
            ) {
                Task { await store.restore() }
            }

            PanelDivider()

            // The web subscription is honoured but deliberately not *sold*
            // here: an in-app link out to a payment page for the app's own
            // features is what App Review rejects builds over. This says where
            // an existing subscription is recognised from, and offers nothing
            // to tap.
            Text("Subscribed on inflight.info? Sign into that account under Settings › Account and Pro unlocks here too.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    private var buttonTitle: String {
        if store.isPurchasing { return "Contacting the App Store…" }
        guard let price = store.displayPrice else { return "Get Inflight Pro" }
        return "Get Inflight Pro · \(price)"
    }

    private func featureRow(_ feature: ProFeature, isHighlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isHighlighted ? theme.onAccent : theme.textPrimary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isHighlighted ? theme.accent : theme.elevatedFill)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                Text(feature.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
