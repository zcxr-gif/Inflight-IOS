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
    @ObservedObject private var web = WebSubscription.shared
    @ObservedObject private var entitlements = Entitlements.shared
    /// Only for the website option: a subscription there belongs to an Inflight
    /// account, so whether there is one decides what that button does.
    @ObservedObject private var accounts = AccountStore.shared

    /// Up when somebody tapped the website option without an account. They came
    /// here to buy something, so it opens on "Create account" rather than on
    /// sign-in — and the moment there is an account, it closes and the checkout
    /// they were after carries on.
    @State private var isMakingAccount = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var theme: FlightInfoTheme { appearance.theme }

    /// The one they hit first, then the rest in their declared order.
    private var features: [ProFeature] {
        guard let highlighted = highlighted else { return ProFeature.allCases }
        return [highlighted] + ProFeature.allCases.filter { $0 != highlighted }
    }

    /// The paywall, and the two things it can put on screen over itself.
    ///
    /// Split in two for the same reason `ContentView`'s body is: one
    /// expression carrying twenty-odd modifiers, several of them presenting
    /// view trees of their own, is the sort the type-checker gives up on.
    var body: some View {
        paywall
        // Stripe's page, over the paywall rather than out in the Safari app.
        // Bound straight to `WebSubscription` because the thing that closes it
        // is the return link, which arrives there and not here.
        .sheet(item: $web.page) { checkout in
            WebCheckoutSheet(page: checkout.url, tint: theme.accent) {
                // Cancel, inside Safari's own chrome. It has nothing to dismiss
                // itself from, so clearing what presented it is this side's job.
                web.page = nil
            }
            // Whichever way it went — Cancel, a swipe, or the return link
            // closing it — ask the server what happened. This is the only ask
            // there is now: the app never backgrounded, so the foreground check
            // that used to cover the trip to Safari never fires.
            .onDisappear { Task { await web.checkoutSheetClosed() } }
        }
        // Sent here by the website option with nobody signed in.
        .sheet(isPresented: $isMakingAccount) {
            AccountPanel(initialIntent: .signUp)
        }
        // An account now exists, and the only reason that sheet was up is that
        // one didn't. Close it and go on to the payment they came for, rather
        // than leaving them on an account screen wondering what became of it.
        .onChange(of: accounts.account?.id) { _, id in
            guard id != nil, isMakingAccount else { return }
            isMakingAccount = false
            Task {
                // One sheet at a time: presenting the checkout while the
                // account sheet is still dismissing loses it silently.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await web.begin()
            }
        }
    }

    private var paywall: some View {
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
        // Now that the paywall is glass over a live map rather than a slab
        // over a dimmed one, its text wants the same halo every other window's
        // does.
        .flightInfoLegible(theme)
        .environment(\.colorScheme, theme.colorScheme)
        // Glass, hung on the sheet rather than drawn inside it — the same
        // ground the flight window and every panel sits on. Drawn as a layer
        // in the content it would have only the sheet behind it to sample and
        // would come out as a flat slab.
        .presentationBackground { theme.sheetBackground }
        .presentationCornerRadius(theme.radiusLarge + 8)
        .presentationDetents([.large])
        // No dimming wash behind it, for the same reason as every other
        // window: glass with a grey sheet behind it has nothing to lens.
        .presentationBackgroundInteraction(.enabled(upThrough: .large))
        // The cross stays here, and only here. This is a paywall: it has a
        // fixed bar of its own at the top and a purchase button pinned at the
        // bottom, so an obvious, unmissable way out is the point rather than
        // an admission that the gesture does not work.
        .presentationDragIndicator(.hidden)
        .task { await store.loadProducts() }
        // A checkout left unaccounted for — paid in the sheet on a launch that
        // has since ended, say. `ContentView` asks on every foreground too;
        // this is for the pilot who reopens the paywall rather than the app.
        .task { await web.confirmIfAwaitingReturn() }
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
                    .flightInfoSurface(theme, in: Circle(), interactive: true)
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
                        .flightInfoSurface(theme, in: Capsule(), interactive: true)
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

    /// Where a subscription bought somewhere else is recognised from.
    ///
    /// Not the same thing as the button at the bottom, and worth saying
    /// separately: somebody who already pays on the website has nothing to buy
    /// here at all, and the answer is to sign in rather than to pay again.
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
            ForEach(AppConfig.ProProduct.forSale) { plan in
                planRow(plan)
            }

            if let problem = store.problem {
                note(problem, symbol: "exclamationmark.triangle")
            }

            if let notice = store.notice {
                note(notice, symbol: "info.circle")
            }

            buyButton

            webOption

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
            .flightInfoSurface(theme, radius: theme.radiusMedium, interactive: true)
            // The chosen plan's ring, over the surface rather than in it.
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : theme.stroke,
                        lineWidth: isSelected ? 2 : 1
                    )
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
        // Not offered any more, so not reachable from the plan list — but
        // `ownedPlan` still returns it for somebody who bought one.
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
        return "Continue"
    }

    // MARK: - Paying on the website instead

    /// The other way to pay: the monthly subscription inflight.info sells
    /// through Stripe.
    ///
    /// Secondary on purpose, and drawn as a link rather than a second filled
    /// button — the App Store plans above are the ones most people should take
    /// and two equal buttons would only make the screen ask a question it does
    /// not need to. What this is for is the pilot who already pays for things
    /// on the website, or who wants the subscription on an account rather than
    /// on an Apple Account.
    ///
    /// One plan, because Stripe has one: a month. Nothing here offers a year,
    /// and nothing offers a trial.
    ///
    /// The tap creates the checkout and brings Stripe's own hosted page up in
    /// a sheet over this one — Safari's view controller, so it is Safari
    /// rendering the payment form and this app cannot see inside it. Nothing
    /// about the payment happens here, and nothing here decides whether it
    /// worked — see `WebSubscription`.
    ///
    /// Signed out, the tap does not attempt a checkout and then apologise: a
    /// website subscription is attached to an Inflight account, so it opens the
    /// account panel on "Create account" and picks the payment back up once
    /// there is one.
    private var webOption: some View {
        VStack(spacing: 8) {
            if let problem = web.problem {
                note(problem, symbol: "exclamationmark.triangle")
            }

            if let notice = web.notice {
                note(notice, symbol: "info.circle")
            }

            Button {
                guard accounts.account != nil else {
                    web.problem = nil
                    isMakingAccount = true
                    return
                }
                Task { await web.begin() }
            } label: {
                HStack(spacing: 7) {
                    if web.isStarting || web.isConfirming {
                        ProgressView().controlSize(.small).tint(theme.textSecondary)
                    }
                    Text(webButtonTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .flightInfoSurface(theme, radius: theme.radiusMedium, interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(web.isStarting || web.isConfirming || store.purchasing != nil)
            .opacity(web.isStarting || web.isConfirming ? 0.6 : 1)
        }
    }

    private var webButtonTitle: String {
        if web.isConfirming { return "Checking your subscription…" }
        if web.isStarting { return "Opening checkout…" }
        // Said before the tap rather than after it. The alternative is a button
        // that looks like it will sell you something and then tells you it
        // cannot — and an account is a step, not a refusal.
        if accounts.account == nil { return "Create an account to subscribe monthly" }
        return "Subscribe monthly on inflight.info"
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
        case .annual, .monthly:
            return "Renews automatically until cancelled. Your Apple Account is charged at confirmation and again each period; cancel any time in Settings, at least a day before it renews."
        case .lifetime:
            // Not selectable — it is not on the plan list — but the switch has
            // to be exhaustive and inventing a "can't happen" here would be
            // worse than saying the true thing.
            return "One payment on your Apple Account. Nothing to cancel."
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
