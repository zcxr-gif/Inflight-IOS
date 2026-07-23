// ─────────────────────────────────────────────────────────────────────────────
// iapService.js — InFlight Pro via Apple In-App Purchase (StoreKit 2)
//
// Thin JS wrapper around the native InAppPurchasePlugin (see
// native-ios/InAppPurchasePlugin.swift). It is the single place the web layer
// touches StoreKit, and it keeps the app's Pro entitlement (window.InflightUser
// / window.isInflightPro) in sync with what Apple reports on-device.
//
// Entitlement model:
//   • StoreKit's on-device `currentEntitlements` is the source of truth for iOS
//     — it is cryptographically signed by Apple, so gating on it is safe even
//     before any server round-trip.
//   • On every entitlement resolution we ALSO best-effort sync to Supabase
//     (`grant-ios-entitlement` edge function) so `profiles.is_pro` is consistent
//     for the web app and other devices. If that function isn't deployed yet the
//     app still gates Pro correctly on-device; only the cross-platform mirror is
//     delayed.
//
// On the web build (or any non-iOS shell) every method is a safe no-op and
// `isAvailable()` returns false, so callers can branch cleanly.
// ─────────────────────────────────────────────────────────────────────────────

// The App Store Connect product identifier for the auto-renewable "InFlight
// Pro" subscription. This MUST match the Product ID you create in App Store
// Connect. Override at runtime with window.INFLIGHT_PRO_PRODUCT_ID if needed.
const DEFAULT_PRODUCT_ID = 'com.tracker.Inflight.pro.monthly';

function productId() {
    return (typeof window !== 'undefined' && window.INFLIGHT_PRO_PRODUCT_ID) || DEFAULT_PRODUCT_ID;
}

function iosNative() {
    return typeof window !== 'undefined' && typeof window.isIOSNative === 'function' && window.isIOSNative();
}

function plugin() {
    return (typeof window !== 'undefined' && window.Capacitor && window.Capacitor.Plugins)
        ? window.Capacitor.Plugins.InAppPurchase
        : null;
}

export const InflightIAP = {
    _supabase: null,
    _product: null,
    _listenerAttached: false,

    init(supabaseClient) {
        this._supabase = supabaseClient || this._supabase;
        if (!this.isAvailable()) return;

        // React to renewals / cross-device purchases / Ask-to-Buy approvals that
        // StoreKit surfaces outside an explicit purchase() call.
        if (!this._listenerAttached) {
            try {
                plugin().addListener('entitlementsChanged', () => {
                    this.refresh().catch(() => {});
                });
                this._listenerAttached = true;
            } catch (_) { /* addListener unsupported — non-fatal */ }
        }

        // Resolve current entitlement once at startup so Pro unlocks silently for
        // users who already subscribed.
        this.refresh().catch(() => {});
    },

    // True only when a real StoreKit bridge is present (native iOS build).
    isAvailable() {
        return !!(iosNative() && plugin());
    },

    // Load + cache the Pro product so the paywall can show a real localized price.
    async getProduct() {
        if (!this.isAvailable()) return null;
        if (this._product) return this._product;
        try {
            const res = await plugin().getProducts({ productIds: [productId()] });
            this._product = (res && res.products && res.products[0]) || null;
            return this._product;
        } catch (e) {
            console.warn('[IAP] getProduct failed:', e?.message || e);
            return null;
        }
    },

    // Kick off a purchase. Returns { ok, status, message }.
    async purchase() {
        if (!this.isAvailable()) {
            return { ok: false, status: 'unavailable', message: 'In-app purchases are not available on this device.' };
        }
        try {
            const result = await plugin().purchase({ productId: productId() });
            if (result?.status === 'purchased') {
                await this._grant(result);
                return { ok: true, status: 'purchased' };
            }
            if (result?.status === 'pending') {
                return { ok: false, status: 'pending', message: 'Your purchase is pending approval. Pro will unlock once it is approved.' };
            }
            if (result?.status === 'cancelled') {
                return { ok: false, status: 'cancelled' };
            }
            return { ok: false, status: 'failed', message: 'Purchase did not complete.' };
        } catch (e) {
            return { ok: false, status: 'error', message: e?.message || 'Purchase failed. Please try again.' };
        }
    },

    // Restore an existing subscription (required by App Store review).
    async restore() {
        if (!this.isAvailable()) {
            return { ok: false, message: 'In-app purchases are not available on this device.' };
        }
        try {
            const res = await plugin().restorePurchases();
            if (res?.active && res.entitlements?.length) {
                await this._grant(res.entitlements[0]);
                return { ok: true, active: true };
            }
            this._setPro(false);
            return { ok: true, active: false, message: 'No active InFlight Pro subscription was found for this Apple ID.' };
        } catch (e) {
            return { ok: false, message: e?.message || 'Restore failed. Please try again.' };
        }
    },

    // Re-read current entitlement (no restore prompt) and update Pro state.
    async refresh() {
        if (!this.isAvailable()) return false;
        try {
            const res = await plugin().getEntitlements();
            const active = !!(res && res.active);
            if (active && res.entitlements?.length) {
                await this._grant(res.entitlements[0], /* silent */ true);
            } else {
                this._setPro(false);
            }
            return active;
        } catch (e) {
            console.warn('[IAP] refresh failed:', e?.message || e);
            return false;
        }
    },

    // Open Apple's manage-subscriptions sheet (cancel / change plan).
    async manageSubscriptions() {
        if (!this.isAvailable()) return false;
        try {
            await plugin().manageSubscriptions();
            return true;
        } catch (e) {
            console.warn('[IAP] manageSubscriptions failed:', e?.message || e);
            return false;
        }
    },

    // ── internal ────────────────────────────────────────────────────────────

    // Grant Pro locally (source of truth for gating) and mirror to Supabase.
    async _grant(transaction, silent = false) {
        this._setPro(true);
        if (!silent) {
            // Give StoreKit a beat, then re-affirm from currentEntitlements so a
            // just-completed purchase is reflected consistently.
            this.refresh().catch(() => {});
        }
        await this._syncToSupabase(transaction);
    },

    _setPro(isPro) {
        if (typeof window === 'undefined') return;
        const prev = !!(window.InflightUser && window.InflightUser.isPro);
        window.InflightUser = { isPro: !!isPro, loaded: true };
        if (prev !== !!isPro) {
            try {
                window.dispatchEvent(new CustomEvent('proStatusChanged', { detail: { isPro: !!isPro } }));
            } catch (_) { /* ignore */ }
        }
    },

    // Best-effort mirror of the Apple entitlement into profiles.is_pro so the
    // web app and other devices see the same Pro state. Never blocks the UX —
    // on-device StoreKit gating already unlocked Pro by this point.
    async _syncToSupabase(transaction) {
        if (!this._supabase || !transaction) return;
        try {
            const { data: sessionData } = await this._supabase.auth.getSession();
            if (!sessionData?.session?.user?.id) return; // not signed in — nothing to mirror yet
            await this._supabase.functions.invoke('grant-ios-entitlement', {
                body: {
                    jws: transaction.jws,
                    transactionId: transaction.transactionId,
                    productId: transaction.productId,
                    expiresAt: transaction.expiresAt || null
                }
            });
        } catch (e) {
            // Function may not be deployed yet — that's fine, gating still works.
            console.warn('[IAP] Supabase entitlement sync skipped:', e?.message || e);
        }
    }
};

if (typeof window !== 'undefined') {
    window.InflightIAP = InflightIAP;
}
