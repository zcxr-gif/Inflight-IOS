# InFlight Pro — iOS In-App Purchase setup

This app now sells **InFlight Pro** on iOS through Apple **In-App Purchase**
(StoreKit 2), which is what App Store review Guideline 3.1.1 requires. The code
is all in place; the steps below are the account/config work only you can do.

The app gates Pro **on-device** from Apple's signed StoreKit entitlement, so
purchases work as soon as the App Store Connect product exists — even before the
Supabase sync function is deployed. The Supabase function is only needed so the
**web app and other devices** see the same Pro state.

## What's in the code

| Piece | File |
|---|---|
| Native StoreKit 2 plugin | `native-ios/InAppPurchasePlugin.swift` / `.m` |
| Build injection (adds plugin to the Xcode target) | `native-ios/inject_live_activity.rb` |
| JS service (`window.InflightIAP`) | `www/iapService.js` |
| Paywall + Restore/Manage UI | `www/authUI.js`, `www/MobileDashboardUI.js` |
| Entitlement gating | `www/flight.js` (`window.isInflightPro`) |
| Server entitlement mirror | `supabase/functions/grant-ios-entitlement/index.ts` |

The product identifier the app requests is **`com.tracker.Inflight.pro.monthly`**
(override at runtime with `window.INFLIGHT_PRO_PRODUCT_ID` if you use a different
one). Change the default in `www/iapService.js` if needed.

## 1. Create the subscription in App Store Connect

1. **App Store Connect → your app → Subscriptions** → create a Subscription Group.
2. Add an **auto-renewable subscription**:
   - Product ID: `com.tracker.Inflight.pro.monthly` (must match the app).
   - Price: your $1.99/mo (or whatever you choose).
   - Add a localized display name, description, and a review screenshot.
3. Fill in the **App Privacy** and the subscription's **Review Information**.
4. The product must be at least **"Ready to Submit"** for it to load in the app.
5. Paste your **Terms of Use (EULA)** and **Privacy Policy** URLs in App Store
   Connect. (The paywall also links to the in-app `terms.html` / `privacy.html`.)

## 2. Enable the In-App Purchase capability

StoreKit 2 needs the **In-App Purchase** capability on the App target. The Xcode
project is regenerated on every Codemagic build, so add it via one of:
- add `com.apple.developer.in-app-payments` handling through your provisioning
  profile / App ID (In-App Purchase is enabled by default for paid apps once the
  subscription exists), **or**
- extend `native-ios/inject_live_activity.rb` to write the entitlement if a
  future Xcode/StoreKit change requires an explicit entitlements key.

In practice, once the subscription product exists under the app's bundle id, no
extra entitlement file is required for StoreKit 2 purchases.

## 3. Test with a Sandbox account

1. App Store Connect → **Users and Access → Sandbox → Testers** → create one.
2. On a device, sign that Sandbox Apple ID into **Settings → App Store → Sandbox**.
3. Build to the device, open the paywall (Settings → InFlight Pro → Upgrade, or
   tap any Pro-locked feature), and buy. Confirm Pro unlocks and **Restore
   Purchases** works after a reinstall.

## 4. Deploy the Supabase sync function (cross-platform Pro)

Needed only so web / other devices mirror the iOS purchase.

1. In App Store Connect → **Users and Access → Integrations → In-App Purchase**,
   create an **In-App Purchase key**; note the **Issuer ID** and **Key ID** and
   download the `.p8`.
2. Set the function secrets:
   ```
   supabase secrets set \
     APPLE_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
     APPLE_KEY_ID=XXXXXXXXXX \
     APPLE_BUNDLE_ID=com.tracker.Inflight \
     PRO_PRODUCT_ID=com.tracker.Inflight.pro.monthly \
     APPLE_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
   ```
3. Deploy:
   ```
   supabase functions deploy grant-ios-entitlement
   ```

Until this is deployed, `iapService.js` simply logs that the sync was skipped —
iOS Pro still works locally.

## 5. Follow-ups (not required to pass review, recommended for correctness)

- **Expiry / renewals across platforms.** On-device StoreKit handles lapses for
  the iOS app automatically (the entitlement disappears). To flip `is_pro` back
  to `false` on the server when an iOS sub lapses, add an **App Store Server
  Notifications V2** endpoint (another Supabase function) and set its URL in App
  Store Connect. This keeps the web `is_pro` accurate.
- **One `is_pro` shared with web billing.** A user could hold both a web (Stripe)
  and an iOS (Apple) subscription. `is_pro` is a single boolean, so "Pro from
  either source" already works; just make sure a lapse on one source doesn't
  clear `is_pro` while the other is still active when you build the notifications
  handler.
