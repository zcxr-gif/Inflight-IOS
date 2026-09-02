# Inflight Pro, and signing in with Apple

What has to be true outside this repository before the paywall can sell
anything and before the Apple button can sign anyone in. Same shape as
[`NOTIFICATIONS.md`](NOTIFICATIONS.md): none of it can be set from code, and
most of it fails quietly — the app builds, installs, runs, and simply shows a
paywall with no prices on it or a sign-in button that errors.

## What is sold

Two plans, in one subscription group, so moving between them is an upgrade
Apple handles rather than two things bought twice.

| Product ID | Type | Suggested US tier | Level |
| --- | --- | --- | --- |
| `com.tracker.Inflight.pro.annual` | Auto-renewable, 1 year | $19.99 | 1 |
| `com.tracker.Inflight.pro.monthly` | Auto-renewable, 1 month | $3.49 | 2 |

The identifiers are in `App/AppConfig.swift` (`ProProduct.forSale`) and have to
match App Store Connect exactly. **Prices are deliberately not in the app.**
Every storefront has its own number and the paywall shows the App Store's own
localised price or nothing at all; the tiers above are only what
`Support/Inflight.storekit` uses for local testing.

Annual is level 1 — the *higher* tier — on purpose. Monthly to annual is then
an upgrade: it takes effect immediately and Apple prorates a refund for the
unused part of the month. Annual to monthly is a downgrade and waits for the
renewal date, which is right, because the year has already been paid for. Put
both on the same level and the switch becomes a crossgrade that, because the
durations differ, would not take effect until the next renewal — somebody pays
for a year and waits up to a month to be on it.

### The retired lifetime unlock

`com.tracker.Inflight.pro`, the non-consumable earlier builds sold, is **no
longer offered**. On App Store Connect it should be **removed from sale**; it
is not deleted, and it must not be.

It stays in `ProProduct` — just not in `forSale` — because removing it from
sale does not revoke it. `Transaction.currentEntitlements` still returns it for
everyone who bought one, `ProStore` still recognises it, and
`pro_entitlement()` still answers `app-store-lifetime` for it. Somebody who
paid once for Pro keeps Pro; the pricing changing is not their problem. The
account panel has its own line for them, and no "Manage subscription" row,
because there is nothing to manage.

It stays in `Support/Inflight.storekit` too, so the already-bought-it path can
still be tested locally even though nothing sells it.

### App Store Connect

1. **Subscriptions → create a group** named `Inflight Pro` with reference
   `inflight.pro`, and put the annual and monthly products in it. Both at
   level 1: they are the same thing at two billing periods, not two tiers.
2. Give the group a **localised display name and description** — a group
   without one is why a subscription sits in "Missing Metadata" forever.
3. **No introductory offer on either product.** There is no free trial in this
   app: the paywall does not offer one, `ProStore` no longer asks StoreKit
   whether the Apple Account is eligible for one, and
   `Support/Inflight.storekit` has none to test against. An offer added on App
   Store Connect would be sold by the App Store without the paywall ever
   mentioning it, so if a trial is ever wanted again it is a decision to take
   here and there together.
4. **App Information → App Store Server Notifications**, both production and
   sandbox URLs:

   ```
   https://lcgaoiqwwpyqndaucyzu.supabase.co/functions/v1/apple-notifications
   ```

   Version 2 notifications. Without this, a renewal or a refund that happens
   while the app is closed never reaches the account, and the website goes on
   thinking a lapsed subscriber is Pro until they next open the app.

## Paying on the website instead

The paywall sells two things, and they are not the same product bought two
ways:

| | App Store | inflight.info |
| --- | --- | --- |
| What | a year or a month | **a month, and only a month** |
| Sold by | StoreKit, in the app | Stripe, on its own hosted page in Safari |
| Attached to | the Apple Account | the Inflight account |
| Free trial | none | none |
| Cancelled in | iOS Settings | inflight.info |

There is no yearly price on Stripe and the app does not pretend there is: the
web option is one button, not a plan list, because there is nothing to choose.

### What actually happens

1. `WebSubscription.begin()` calls `create-stripe-checkout` with this account's
   id and email, as an **upgrade** (`is_renew`) — the account already exists.
   Nothing asks for `trial_days`.
2. The hosted Stripe page opens in Safari. No payment detail ever touches this
   app.
3. Stripe returns the browser to `inflight.info/app-return.html`, which does
   nothing but bounce to `inflight://open`.
4. The app asks **`restore-pro-access`** — which identifies the caller from
   their own token, asks Stripe whether *that* account has a live
   subscription, and writes the row — then re-reads `pro_entitlement()`. Five
   tries over about twelve seconds while the paywall is up.
5. And again on **every foreground** afterwards, until it is accounted for.
   The claim is kept in `UserDefaults`, not in memory: the checkout happens in
   Safari and iOS may kill this app while it is there, so a pilot who pays and
   comes back to a freshly launched app is the case the claim exists for. It
   expires after a day.

Nothing in the app decides whether a payment worked, and nothing on the return
page grants anything — the server is asked, always. That is deliberate: a
redirect is the one step in this flow a person can close halfway.

### `stripe-webhook`, and why the app does not rely on it

`stripe-webhook` is deployed, handles `checkout.session.completed` and the
subscription lifecycle, and would make all of the above a mere speed-up. **It
is not currently receiving anything.** As of 2026-09-02, no row in
`public.subscriptions` had ever been written a second time — 19 rows going back
to 2026-07-29, fifteen of them active monthly subscriptions, so renewals had
certainly happened — and the function had no invocations at all in the
available log window. The endpoint looks unregistered in the Stripe dashboard.

Two consequences, and only the second is this app's problem:

- **On the website**, renewals never refresh `current_period_end` and
  cancellations never revoke. Eleven active rows carry a NULL period end,
  which `pro_entitlement()` reads as "never expires". That is a billing
  correctness bug, it predates any of this, and a subscription sold from this
  app would land in the same state — so it is worth fixing before this
  ships, not after.
- **Here**, it means step 4 is not a speed-up but the actual grant, which is
  why it repeats on every foreground rather than only on the return trip.

If the endpoint is registered later, none of this changes: `restore-pro-access`
is idempotent, and finding the row already written is a no-op.

### Sign-in is required

A subscription belongs to an account, so the button says so and stops rather
than taking a payment that nothing could be given for. The App Store plans have
no such requirement — a purchase made signed out attaches to the account the
next time the app runs signed in.

### App Review

Linking out of the app to pay for the app's own features is Guideline 3.1.1
territory. In the United States this is currently permitted following the
*Epic v. Apple* injunction; elsewhere it needs the **External Purchase Link**
entitlement, requested per-storefront in the Apple Developer portal. The App
Store purchase is kept as the primary path on the paywall for exactly this
reason — it is what most people will use, and it is what a reviewer sees first.

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
