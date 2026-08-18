# Inflight Pro, and signing in with Apple

What has to be true outside this repository before the paywall can sell
anything and before the Apple button can sign anyone in. Same shape as
[`NOTIFICATIONS.md`](NOTIFICATIONS.md): none of it can be set from code, and
most of it fails quietly — the app builds, installs, runs, and simply shows a
paywall with no prices on it or a sign-in button that errors.

## What is sold

Three products against one entitlement. The two subscriptions share a group, so
moving between them is an upgrade Apple handles rather than two things bought
twice.

| Product ID | Type | Suggested US tier |
| --- | --- | --- |
| `com.tracker.Inflight.pro.annual` | Auto-renewable, 1 year | $19.99 |
| `com.tracker.Inflight.pro.monthly` | Auto-renewable, 1 month | $3.49 |
| `com.tracker.Inflight.pro` | Non-consumable (lifetime) | $39.99 |

The identifiers are in `App/AppConfig.swift` (`ProProduct`) and have to match
App Store Connect exactly. **Prices are deliberately not in the app.** Every
storefront has its own number and the paywall shows the App Store's own
localised price or nothing at all; the tiers above are only what
`Support/Inflight.storekit` uses for local testing.

`com.tracker.Inflight.pro` is the product earlier builds sold. It stays,
unchanged in identifier, so nobody who bought it loses anything.

### App Store Connect

1. **Subscriptions → create a group** named `Inflight Pro` with reference
   `inflight.pro`, and put the annual and monthly products in it. Both at
   level 1: they are the same thing at two billing periods, not two tiers.
2. Give the group a **localised display name and description** — a group
   without one is why a subscription sits in "Missing Metadata" forever.
3. The annual product's **introductory offer** (a one-week free trial in the
   test configuration) is optional. The paywall's button reads "Start free
   trial" only when StoreKit says this Apple Account is actually eligible, so
   removing the offer changes the copy on its own.
4. **App Information → App Store Server Notifications**, both production and
   sandbox URLs:

   ```
   https://lcgaoiqwwpyqndaucyzu.supabase.co/functions/v1/apple-notifications
   ```

   Version 2 notifications. Without this, a renewal or a refund that happens
   while the app is closed never reaches the account, and the website goes on
   thinking a lapsed subscriber is Pro until they next open the app.

## Sign in with Apple

### Apple Developer portal

Add the **Sign in with Apple** capability to the `com.tracker.Inflight` App ID,
then **regenerate the App Store provisioning profile** and re-upload it to
Codemagic as `inflight_distribution`. A profile issued before the capability
was added still installs and still signs, and the request then fails at runtime
with error 1000 and nothing else to go on — which is why
`Scripts/check-provisioning.py` is now asked for
`com.apple.developer.applesignin` and the build stops there instead.

### Supabase

**Authentication → Providers → Apple → Enable.** For the native flow the only
field that matters is **Authorized Client IDs**, which must contain the bundle
id:

```
com.tracker.Inflight
```

The Services ID, team ID and key are for the *web* flow and are not needed by
the app. The app never sees a credential: it hands GoTrue Apple's identity
token and the raw nonce, and GoTrue verifies the signature against Apple's own
public keys.

## Where the entitlement lives

Two halves, OR-ed, and they answer different failure modes:

- **StoreKit**, on the device — `Transaction.currentEntitlements`, signed by
  Apple, needs no network. This is what unlocks Pro the instant somebody taps
  Buy.
- **`public.pro_entitlement()`**, on the server — folds together an App Store
  purchase linked to the account, the Stripe subscription sold on the website,
  and the `legacy_pro` grandfathering flag. This is what makes a purchase made
  in the app work on inflight.info.

Nothing flows the other way. The app posts Apple-signed transactions up; the
server never writes anything back down that the device treats as proof.

### Database

`supabase/migrations/`:

- `20260817000000_app_store_subscriptions.sql` — the table. RLS lets an account
  read its own row and nothing else; there is deliberately no insert or update
  policy, because a client that can write its own entitlement can grant itself
  Pro.
- `20260817000100_pro_entitlement_app_store.sql` — teaches the existing
  `pro_entitlement()` about it. Same five columns out, so the website reads it
  untouched; two new values of `source`, `app-store` and `app-store-lifetime`.

Sandbox rows are stored but ignored by `pro_entitlement()`, so a TestFlight
tester's sandbox subscription never unlocks Pro on the website.

### Edge Functions

| Function | Called by | `verify_jwt` |
| --- | --- | --- |
| `apple-subscription-sync` | the app, with its own access token | yes |
| `apple-notifications` | Apple, unprompted | **no** |

Both verify Apple's signature over the transaction before writing anything —
`supabase/functions/_shared/apple.ts`, using Apple's own
`@apple/app-store-server-library`. `apple-notifications` is public because
Apple has no Supabase token to present, so that signature *is* the
authentication.

Deploy:

```sh
supabase functions deploy apple-subscription-sync --project-ref lcgaoiqwwpyqndaucyzu
supabase functions deploy apple-notifications --project-ref lcgaoiqwwpyqndaucyzu --no-verify-jwt
```

Secrets (`supabase secrets set …`):

| Name | Needed | What it is |
| --- | --- | --- |
| `APPLE_APP_APPLE_ID` | **yes** | the app's numeric App Store id. Apple's library refuses to verify a *production* payload without it, so until this is set only sandbox purchases verify. |
| `APPLE_BUNDLE_ID` | no | defaults to `com.tracker.Inflight`. |
| `APPLE_LIFETIME_PRODUCT_ID` | no | defaults to `com.tracker.Inflight.pro`. |
| `APPLE_ROOT_CERTS` | no | comma-separated base64 DER. Set it to stop the function fetching Apple's roots at cold start. |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform.

### Checking it works

Send a **TEST notification** from App Store Connect (App Information → App
Store Server Notifications → Request a test notification) and read the function
log. A verified test payload logs its notification type and returns 200; a
payload that fails verification returns 401, which is what a missing
`APPLE_APP_APPLE_ID` looks like from the outside.

## Which account a purchase belongs to

Every purchase is stamped with `appAccountToken` — the signed-in Supabase user
id, which is already a UUID. Apple carries it on every transaction from then
on, so a notification arriving days later finds its way to the right profile
without the app being involved.

Buying while signed out still works; the purchase attaches to the account the
next time the app runs signed in. A purchase already claimed by a *different*
account is never moved: two accounts sharing one Apple Account is a real
situation, and the first to claim it keeps it rather than the entitlement
ping-ponging every time either of them opens the app.
