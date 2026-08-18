import StoreKit
import SwiftUI

/// The paywall.
///
/// It says what Pro is, what each plan costs in the user's own currency, and
/// what happens if they already have it — and then stops. No countdown, no
/// crossed-out price, no "most popular" badge invented for the occasion: the
/// only claim it makes about the yearly plan is the one arithmetic supports,
/// computed from the two real prices and absent when either hasn't arrived.
///
/// Laid out as a screen rather than as one of the app's settings panels,
/// because it is doing one thing and the reading order matters: what you get,
/// what it costs, one button. The plans and the button are pinned to the
/// bottom, so the decision is always on screen while the list above it scrolls.
///
/// The feature list is `ProFeature.allCases` rather than prose, so what is
/// advertised here and what is actually gated cannot drift apart.
struct ProPanel: View {

    /// Which feature the user ran into, when they got here by running into one.
    /// It leads the list, so the answer to "why am I looking at this" is the
    /// first thing on screen.
    var highlighted: ProFeature? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var entitlements = Entitlements.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var theme: FlightInfoTheme { appearance.theme }

    /// The one they hit first, then the rest in their declared order.
    private var features: [ProFeature] {
        guard let highlighted = highlighted else { return ProFeature.allCases }
        return [highlighted] + ProFeature.allCases.filter { $0 != highlighted }
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome

            if entitlements.isPro {
                owned
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 22) {
                        hero
                        featureList
                        alreadySubscribed
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)

                checkout
            }
        }
        .background { theme.windowFill.ignoresSafeArea() }
        .environment(\.colorScheme, theme.colorScheme)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await store.loadProducts() }
        // Bought here, or bought on another device while this was open: either
        // way the sheet has nothing left to sell.
        .onChange(of: entitlements.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    // MARK: - Chrome

    /// Close on the left, restore on the right. Restore lives up here rather
    /// than buried under the button because the people who need it are the
    /// ones who have *already paid*, and making them read a paywall to find it
    /// is the wrong way round.
    private var chrome: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background { Circle().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer(minLength: 8)

            if !entitlements.isPro {
                Button {
                    Task { await store.restore() }
                } label: {
                    Text(store.isRestoring ? "Restoring…" : "Restore")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background { Capsule().fill(theme.surfaceFill) }
                }
                .buttonStyle(.plain)
                .disabled(store.isRestoring || store.purchasing != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - The pitch

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(theme.accent)

            Text("Inflight Pro")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var subtitle: String {
        if let highlighted = highlighted {
            return "\(highlighted.title) is part of Pro, along with everything below."
        }
        return "Everything the tracker can do, on every device you sign into."
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                if index > 0 { PanelDivider() }
                featureRow(feature, isHighlighted: feature == highlighted)
            }
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func featureRow(_ feature: ProFeature, isHighlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isHighlighted ? theme.onAccent : theme.textPrimary)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(isHighlighted ? theme.accent : theme.elevatedFill)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                Text(feature.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    /// The web subscription is honoured but deliberately not *sold* here: an
    /// in-app link out to a payment page for the app's own features is what
    /// App Review rejects builds over. This says where an existing
    /// subscription is recognised from, and offers nothing to tap.
    private var alreadySubscribed: some View {
        Text("Already subscribed on inflight.info? Sign into that account under Account and Pro unlocks here too.")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.textDim)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Choosing and buying

    /// Pinned under the scroll view: the plans, the button, and the sentence
    /// App Review looks for.
    private var checkout: some View {
        VStack(spacing: 10) {
            ForEach(AppConfig.ProProduct.allCases) { plan in
                planRow(plan)
            }

            if let problem = store.problem {
                note(problem, symbol: "exclamationmark.triangle")
            }

            if let notice = store.notice {
                note(notice, symbol: "info.circle")
            }

            buyButton

            legal
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            // Lifts the decision off the list scrolling behind it. A hairline
            // and a ground, not a shadow — the app has no shadows anywhere else.
            VStack(spacing: 0) {
                Rectangle().fill(theme.stroke).frame(height: 1)
                theme.windowFill
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func planRow(_ plan: AppConfig.ProProduct) -> some View {
        let isSelected = store.selected == plan
        let isAvailable = store.product(for: plan) != nil

        return Button {
            store.selected = plan
            store.problem = nil
            store.notice = nil
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title(for: plan))
                            .font(.system(size: 15.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)

                        if plan == .annual, let saving = store.annualSavingPercent {
                            Text("SAVE \(saving)%")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background { Capsule().fill(theme.accent) }
                                .fixedSize()
                        }
                    }

                    if let detail = detail(for: plan) {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textDim)
                    }
                }

                Spacer(minLength: 6)

                Text(store.displayPrice(for: plan) ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? theme.accent : theme.textDim)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .fill(theme.surfaceFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accent : theme.stroke,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || store.purchasing != nil)
        .opacity(isAvailable ? 1 : 0.4)
    }

    private func title(for plan: AppConfig.ProProduct) -> String {
        switch plan {
        case .annual: return "12 months"
        case .monthly: return "1 month"
        case .lifetime: return "Lifetime"
        }
    }

    /// The line under each plan's name.
    ///
    /// The yearly one is the App Store's own price divided by twelve, in the
    /// storefront's own currency, rather than a number typed in here — which
    /// is the only way it is right outside the United States.
    private func detail(for plan: AppConfig.ProProduct) -> String? {
        switch plan {
        case .annual:
            guard let perMonth = store.perMonthPrice(for: .annual) else { return "Billed once a year" }
            return "\(perMonth) a month, billed yearly"
        case .monthly:
            return "Billed every month"
        case .lifetime:
            return "One payment. Nothing to cancel."
        }
    }

    private var buyButton: some View {
        Button {
            Task { await store.purchase(store.selected) }
        } label: {
            HStack(spacing: 8) {
                if store.purchasing != nil {
                    ProgressView().tint(theme.onAccent)
                }
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .fill(theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.product(for: store.selected) == nil || store.purchasing != nil || store.isRestoring)
        .opacity(store.product(for: store.selected) == nil || store.purchasing != nil ? 0.55 : 1)
        .padding(.top, 2)
    }

    private var buttonTitle: String {
        if store.purchasing != nil { return "Contacting the App Store…" }
        if store.product(for: store.selected) == nil { return "Loading prices…" }
        if store.selected == .lifetime { return "Get Inflight Pro" }
        if store.isEligibleForIntroOffer == true { return "Start free trial" }
        return "Continue"
    }

    /// The renewal terms, and the two links App Review requires to be on the
    /// paywall itself rather than three taps into Settings.
    private var legal: some View {
        VStack(spacing: 7) {
            Text(renewalTerms)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                if let terms = AppConfig.termsURL {
                    Button("Terms") { openURL(terms) }
                        .buttonStyle(.plain)
                }
                if let privacy = AppConfig.privacyURL {
                    Button("Privacy") { openURL(privacy) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var renewalTerms: String {
        switch store.selected {
        case .lifetime:
            return "One payment on your Apple Account. It comes back on any device you sign that account into — no subscription, nothing to cancel."
        case .annual, .monthly:
            return "Renews automatically until cancelled. Your Apple Account is charged at confirmation and again each period; cancel any time in Settings, at least a day before it renews."
        }
    }

    // MARK: - Already bought

    private var owned: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)

            Text("You have Inflight Pro")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            Text(ownedDetail)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)

            if entitlements.source == .appStore,
               store.ownedPlan?.isSubscription == true,
               let manage = AppConfig.manageSubscriptionsURL {
                Button("Manage subscription") { openURL(manage) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var ownedDetail: String {
        switch entitlements.source {
        case .appStore:
            return "Bought on the App Store. It follows your Apple Account to any device you sign in on."
        case .subscription:
            return "From your subscription on inflight.info. Everything here is unlocked."
        case .legacy:
            return "Your account has had Pro since before it was sold separately. It stays that way."
        case .free:
            return "Everything here is unlocked."
        }
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
