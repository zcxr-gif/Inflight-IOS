# Inflight — native iOS tracker

A bare-bones, fully native iOS rebuild of the Inflight tracker: SwiftUI + MapKit,
no web view, no Capacitor. It reads the same live traffic feed and draws the same
plane icons as the original tracker.

The previous Capacitor/web build is preserved untouched in [`old/`](old/).

## What the app does

- Live map of every aircraft on the selected server (MapKit — no API key, no tiles to pay for).
- The original sprite-sheet plane icons, picked per aircraft type and rotated to true heading.
- **The traffic flies.** The server reports positions every few seconds; between those, an airborne aircraft carries on at the heading and ground speed it last reported, so an aeroplane crosses the map instead of jumping across it. A packet landing is never a jump either — the correction is spent as a slight change of pace along the aircraft's own track, so nothing ever slides sideways or stops. Aircraft on the ground are drawn exactly where they were reported, and the whole thing costs nothing at a zoom where the movement would be invisible. Settings › Appearance › Fly the traffic turns it off, and Reduce Motion turns it off for you.
- Tap an aircraft for callsign, pilot, type/livery, route, altitude, ground speed, vertical speed and heading. The sheet keeps updating while it's open, and the map can be set to follow the aircraft as it flies.
- **Flight instruments**, in every flight window and full screen from the arrows on the card. A **PFD** — artificial horizon, speed and altitude tapes, vertical speed, heading tape — and an **ND** in ARC or ROSE at 10 to 320 NM, drawing the filed route, both ends of it, and the traffic around the aircraft with how far above or below it each one is. Pitch and bank are read from the simulator when the pilot is broadcasting through Connect, and derived from the flight path and the rate of turn when they are not; the display says which, every time. Switched on by default, and switched off under Settings › Instruments.
- **The filed route**, drawn on the map for whichever aircraft is open — the line, and every fix on it as a named diamond, with procedures expanded to the fixes they contain. **On the drawn planet too**, the same fixes with the same names, joined by great circles between neighbours rather than chords across the sphere. The fix being flown to is filled and picked out in amber on both maps, and everything already behind the wing is dimmed, so how much of the route is left reads at a glance. Under Filters › Flight plan: whether the line ahead is the filed plan, the direct great circle, or neither — and a switch of its own for the **waypoint names**, since a long-haul plan is forty of them and at a zoom that fits the whole route the names cover the route. The flight window lists the same fixes, with the one being flown to picked out, how far it is and how long it will take.
- **The flown path** — the track the aircraft has actually covered, coloured by the height it was at, fetched from the server so it reaches back to departure rather than to when you opened the app. The curved-line button beside an open flight turns it on and puts the map on the track itself, rather than on the whole route with an ocean either side of it; there is a switch for the layer under Filters too.
- **Partner virtual airlines**, in words. A flight whose callsign belongs to a VA on the partner directory names it on a line under the route card — in the peak state and the full window both — saying whether the pilot is flying as a registered member, merely under that airline's callsign, or whether the VA is simply hubbed at an end of the route; those are different claims and the line never blurs them. The line opens the VA's own panel: who they are, what they fly, everyone of theirs in the air right now, and every way there is to reach them. A field's panel lists the VAs hubbed there. Text and links only — the directory's logos and banner artwork are never parsed, so there is nothing for a later change to start drawing.
- **Weather on the map**, from the weather button: precipitation **radar** and infrared **cloud** as tiles under the traffic, with the last two hours of frames animated or scrubbable from a strip over the map; **wind barbs** on a grid at any flight level from 050 to 390; and each marked field's own wind and temperature written under its code once the map is close enough to read them.
- **North Atlantic tracks**, under Filters: the organised track system coloured by letter with the levels each track is valid at, republished twice a day.
- Open a field — from the search results, from the ATC panel, from the airports board, or by tapping either end of an open flight's route — for who is on frequency, its METAR, what is inbound and how long it has to run, what has just left, and what is sitting on the apron. Every aircraft on it taps through to its own window, and a field reached from a flight offers the way back to it. Either end of an open route is marked when somebody is working it.
- A **ruler** beside the map-style button: tap two places for the great-circle distance in miles and kilometres, the heading to fly it on, and roughly how long it takes. Taps that land near a field name the field.
- **Stats**: what the server is doing right now, counted from the same packet the map is drawn from — how many are airborne, what everyone is doing, how high they are, the busiest departures, arrivals, routes and types, and the longest leg in the air. Any field in the lists opens from there.
- **Day and night** on the map, with civil twilight as a softer band at its edge. Worked out on the device from the date and the clock.
- Airports board: where the server actually is, ranked by the routes aircraft have filed, with controlled fields marked.
- Filters: phase, altitude band, aircraft kind (airliners, regional, light & private, military, helicopters), and filed-destination-only. All of them views onto traffic already received, so nothing is re-fetched.
- Server switcher: Expert / Training / Casual.
- Hints: one dim line at the foot of a screen, about that screen. Each retires after a few sessions or when dismissed; the whole thing can be switched off, or restored, under Settings.
- Map styles, from the control in the map's bottom corner or Settings › Appearance: Muted (the default), Detailed, Satellite, and **Globe** — MapKit's own 3D planet, free to spin and tilt, with the server's traffic on it. The globe is the only style that unlocks rotation, and sprite headings are corrected against the camera so a spun planet doesn't turn every aircraft on it.
- **The planet**, the app's own drawn globe, standing where MapKit usually does — with the traffic, the fields, the filed route, the flown track and the organised tracks on it. Free, and deliberately: it fetches nothing, and a shape of the world nobody can look at is one nobody can want. **Editing it is Pro** — ten colours, five skies behind it, and silhouettes instead of dots — under Settings › Map or the map's own corner control. A free account gets the planet in the look it has always opened on, and a lapsed subscription drops back to that look without forgetting the colour you picked.
- **The airline's own colour on the flight window**, under Settings › Appearance. The window's hairline edges, its dividers and the few pieces already drawn in the accent — the filled tile, the progress fill, the badge on the route — take the colour of the airline whose aeroplane is open, and nothing else does: the ground, the cards and the type are untouched, so it reads as a window with an airline's colour on its edges rather than as a poster for that airline. Brand colours are the same ones the web tracker holds, pulled into a lightness the window can actually draw a hairline in; a livery there is no colour for gets none, and the switch turns the whole thing off.
- **Figures that change rather than twitch.** Every readout the feed drives — the telemetry tiles, the distance to run, the counts on the toolbar and in the stats — rolls the digits that moved and leaves the ones that did not, and every label that swaps a word for another crosses into it. One vocabulary of movement (`Motion`), honoured everywhere, and switched off entirely by Reduce Motion.
- Light and dark, under Settings › Appearance: Auto follows iOS, or pin it either way. Every surface — the panels, the floating chrome, the info window, and MapKit's own cartography — turns together.
- Your profile is one tap from anywhere on the map — the avatar top right stays put while you are watching an aeroplane, and opens your page as other pilots see it. Hold it for your account and for Pro.
- An optional account, on the same Supabase project the web tracker uses, so an account made on inflight.info signs in here. **Sign in with Apple**, or an email and password. Sign up, reset a password, delete the account.
- Inflight Pro, sold in the app and only in the app: a year or a month. (The one-off lifetime unlock earlier builds sold is retired, and still honoured for everyone who bought one.) A web subscription (or the grandfathered `legacy_pro` flag) unlocks the same things, for anyone who already has one, and a purchase made here unlocks Pro on inflight.info too. Setup that has to happen outside the repo is in [`ios-native/PRO.md`](ios-native/PRO.md).
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
    Map/                          Icon drawing, annotations, MKMapView wrapper
    Views/                        SwiftUI screens
    Resources/                    airports.txt, app icon
  Support/Inflight.storekit       StoreKit config, for testing Pro in the simulator
supabase/functions/               Edge Functions (account deletion, App Store purchases)
supabase/migrations/              Schema, as SQL that has been applied
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

The marks are vector, not a sprite sheet. `PlaneArtwork.swift` is generated and
holds them as flat path data; `PlanePath` turns that into a `CGPath` and
`PlaneIconRenderer` fits it to the canvas and gives it its halo, so each icon is
drawn at the size, colour and screen scale it is actually wanted at. Selection
and the watch-list tint are colours applied at render time rather than separate
artwork. `tools/plane-artwork/README.md` covers where the shapes come from,
under which licences, and how to regenerate them.

`PlaneSprites.fleet` says which artwork a sprite key draws and how big; that is
where a type gets a distinct mark or a different size.

`AircraftCatalog.spriteKey(for:)` is a port of `getAircraftCategory()` from
`old/www/flight.js`, so anything the old tracker recognised is still recognised.
It matches the same names, but hands a few of them their own icon now that the
set has one — a Chinook, an Apache, a Typhoon, an F-35. Extra type matches only
run where the old function fell through to its generic `B737` fallback.

## Restoring the old build

`old/codemagic.yaml` is the previous pipeline, kept for reference. To ship the
Capacitor app again, move `old/`'s contents back to the repo root and restore
that file as the root `codemagic.yaml`.
