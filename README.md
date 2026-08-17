# Inflight — native iOS tracker

A bare-bones, fully native iOS rebuild of the Inflight tracker: SwiftUI + MapKit,
no web view, no Capacitor. It reads the same live traffic feed and draws the same
plane icons as the original tracker.

The previous Capacitor/web build is preserved untouched in [`old/`](old/).

## What the app does

- Live map of every aircraft on the selected server (MapKit — no API key, no tiles to pay for).
- The original sprite-sheet plane icons, picked per aircraft type and rotated to true heading.
- Tap an aircraft for callsign, pilot, type/livery, route, altitude, ground speed, vertical speed and heading. The sheet keeps updating while it's open, and the map can be set to follow the aircraft as it flies.
- Open a field — from the search results, from the ATC panel, from the airports board, or by tapping either end of an open flight's route — for who is on frequency, its METAR, what is inbound and how long it has to run, what has just left, and what is sitting on the apron. Every aircraft on it taps through to its own window, and a field reached from a flight offers the way back to it. Either end of an open route is marked when somebody is working it.
- Airports board: where the server actually is, ranked by the routes aircraft have filed, with controlled fields marked.
- Filters: phase, altitude band, aircraft kind (airliners, regional, light & private, military, helicopters), and filed-destination-only. All of them views onto traffic already received, so nothing is re-fetched.
- Server switcher: Expert / Training / Casual.
- Hints: one dim line at the foot of a screen, about that screen. Each retires after a few sessions or when dismissed; the whole thing can be switched off, or restored, under Settings.
- Light and dark, under Settings › Appearance: Auto follows iOS, or pin it either way. Every surface — the panels, the floating chrome, the info window, and MapKit's own cartography — turns together.
- An optional account, on the same Supabase project the web tracker uses, so an account made on inflight.info signs in here. Sign in, sign up, reset a password, delete the account.
- Inflight Pro: a one-off App Store purchase that unlocks flight replay and lifts the watchlist cap. A web subscription (or the grandfathered `legacy_pro` flag) unlocks the same things, for anyone who already has one.
- Connection status and live aircraft count.

## Layout

```
ios-native/
  project.yml                     XcodeGen spec — this IS the project
  Support/Info.plist
  InflightTracker/
    App/                          Entry point + configuration constants
    Models/Flight.swift           Feed payload decoding
    Services/LiveFeed.swift       Socket.IO client
    Map/                          Sprite slicing, annotations, MKMapView wrapper
    Views/                        SwiftUI screens
    Resources/                    markers.png, sprite-uvs.json, app icon
  Support/Inflight.storekit       StoreKit config, for testing Pro in the simulator
supabase/functions/               Edge Functions (account deletion)
codemagic.yaml                    CI: generate project -> sign -> IPA -> TestFlight
old/                              The previous Capacitor tracker, as it was
```

## Building

There is nothing to open in Xcode and no `.xcodeproj` in the repo — Codemagic
generates it on every build:

1. `xcodegen generate` turns `ios-native/project.yml` into `InflightTracker.xcodeproj`
2. the generated project is verified (scheme, SocketIO package, icon resources)
3. Swift packages resolve, build number is set from `$BUILD_NUMBER`
4. Codemagic's App Store Connect integration signs it, and the IPA is submitted to TestFlight

Push to any branch to trigger it. Bundle identifier is `com.tracker.Inflight`, the
same one the old build used, so signing and the TestFlight app record work as-is.

To change project settings — deployment target, capabilities, dependencies, build
settings — edit `ios-native/project.yml`. It is plain YAML and needs no Mac.

## App Store paperwork

The things App Store Connect rejects an upload over, and where each is answered.
Most of them fail *after* a green build, by email, which is why the generate step
checks what it can.

| Requirement | Where it is answered |
| --- | --- |
| Privacy manifest (`ITMS-91053`) | `Support/Privacy/App/` and `Support/Privacy/Widgets/`. Declares the UserDefaults and file-timestamp APIs the code actually calls, with reasons `CA92.1`, `1C8F.1`, `C617.1`. Both are verified in CI. |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in `Support/Info.plist`. Only standard HTTPS is used, which is exempt. Without this key TestFlight holds every build asking the question by hand. |
| Build number always increasing | `agvtool` in CI, offset past the Capacitor build's high-water mark of 199. |
| Extension version matching the app | Both Info.plists read `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` from the same project-level settings, so they cannot drift. |
| App icon (`CFBundleIconName`) | Injected at build time from `Assets.xcassets` because `ASSETCATALOG_COMPILER_APPICON_NAME` is set — it is deliberately *not* in `Info.plist`. |
| Production push | Not set here at all. `aps-environment` is taken from the provisioning profile at signing, overriding whatever the entitlements file says — so the App Store profile must have **Push Notifications** enabled or the entitlement is dropped silently. See [NOTIFICATIONS.md](ios-native/NOTIFICATIONS.md). |

The one entry that is a judgement call rather than a fact about the code is
`NSPrivacyCollectedDataTypes`, currently empty — an assertion that the app
collects nothing. It has to agree with the privacy answers on the App Store
Connect record; the manifest's own comments set out what to weigh.

## Accounts and Inflight Pro

### The account

Sign-in talks to the same Supabase project the Capacitor build did — see
`old/www/flight.js` for where the URL and anon key come from — through a
hand-rolled client (`Services/SupabaseAuth.swift`) rather than the
`supabase-swift` package: it is four requests and one row, and the package would
add a dependency graph to a CI build that currently resolves exactly one.

The refresh token lives in the Keychain (`ThisDeviceOnly`); the access token is
held in memory only. The app works perfectly well signed out — the account
exists so Pro follows you between devices.

**Account deletion is required.** App Store Guideline 5.1.1(v) says an app that
lets you create an account has to let you delete it in-app. The button is in
Settings › Account, and it calls the Edge Function in
`supabase/functions/delete-account/`, which **has to be deployed** before that
button works:

```
supabase functions deploy delete-account --project-ref lcgaoiqwwpyqndaucyzu
```

Until it is, the button reports that deletion isn't available on the server yet.
Deleting an auth user needs the `service_role` key, which is why it cannot be
done from the client.

### Pro

`com.tracker.Inflight.pro`, a **non-consumable** at the US $1.99 tier. It needs
creating on the App Store Connect record under that exact identifier, with the
paid-apps agreement in place, or `Product.products(for:)` returns nothing and
the paywall shows no price.

Two things grant it, OR-ed rather than reconciled (`Services/Entitlements.swift`):

| Source | Where it comes from |
| --- | --- |
| App Store | `Transaction.currentEntitlements`, tied to the Apple Account. What the paywall sells. |
| `profiles.is_pro` / `legacy_pro` | The web subscription and the grandfathering flag. Read-only from the app. |

Nothing is written back the other way. An App Store purchase is **not** mirrored
into `profiles.is_pro`, because the only thing that could write it is the
client, and a client that can set its own `is_pro` can grant itself Pro.

What Pro gates is `ProFeature.allCases` and nothing else — the paywall lists the
same enum the gates check, so the two cannot describe different products.

## Data feed

Live traffic comes from the same ACARS backend the web tracker uses:

```
connect  https://site--acars-backend--6dmjph8ltlhv.code.run
emit     join_server_room  <server name>
on       all_flights_update  -> { server, flights: [...] }
```

Payloads are decoded off the main thread; a malformed aircraft is dropped rather
than failing the whole packet.

## Plane icons

`markers.png` and `sprite-uvs.json` are copied from the old tracker. The UV table
stores `[x, y, width, height]` as ratios of the sheet, and `PlaneSprites` crops
each icon out at runtime — the same source pixels the web build drew.

`AircraftCatalog.spriteKey(for:)` is a faithful port of `getAircraftCategory()`
from `old/www/flight.js`, so anything the old tracker recognised gets an identical
icon. Extra type matches only run where the old function fell through to its
generic `B737` fallback.

## Restoring the old build

`old/codemagic.yaml` is the previous pipeline, kept for reference. To ship the
Capacitor app again, move `old/`'s contents back to the repo root and restore
that file as the root `codemagic.yaml`.
