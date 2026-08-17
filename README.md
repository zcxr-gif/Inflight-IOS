# Inflight — native iOS tracker

A bare-bones, fully native iOS rebuild of the Inflight tracker: SwiftUI + MapKit,
no web view, no Capacitor. It reads the same live traffic feed and draws the same
plane icons as the original tracker.

The previous Capacitor/web build is preserved untouched in [`old/`](old/).

## What the app does

- Live map of every aircraft on the selected server (MapKit — no API key, no tiles to pay for).
- The original sprite-sheet plane icons, picked per aircraft type and rotated to true heading.
- Tap an aircraft for callsign, pilot, type/livery, route, altitude, ground speed, vertical speed and heading. The sheet keeps updating while it's open, and the map can be set to follow the aircraft as it flies.
- The route the pilot actually filed, where there is one: drawn on the map fix by fix — out on the departure procedure, down the airways, in on the arrival — and listed in the window with the fix being flown to picked out. Aircraft that filed nothing but two ICAO codes still get the straight line, which is all anyone knows about them.
- Open a field — from the search results, from the ATC panel, from the airports board, or by tapping either end of an open flight's route — for its photograph, who is on frequency, its ATIS, its METAR and what that makes it (VFR through LIFR), its runways with the one the wind favours marked, what is inbound and how long it has to run, what has just left, and what is sitting on the apron. Every aircraft on it taps through to its own window, and a field reached from a flight offers the way back to it.
- Airports board: where the server actually is, ranked by the routes aircraft have filed, with controlled fields marked and each field's own photograph beside it.
- A rail of bubbles down the top right, which stays put when a flight window covers the bottom bar: weather for wherever you are looking, filters, and what the map itself is drawn on — chart, satellite or hybrid.
- Filters: phase, altitude band, aircraft kind (airliners, regional, light & private, military, helicopters), and filed-destination-only. All of them views onto traffic already received, so nothing is re-fetched.
- Server switcher: Expert / Training / Casual.
- Hints: one dim line at the foot of a screen, about that screen. Each retires after a few sessions or when dismissed; the whole thing can be switched off, or restored, under Settings.
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

## Data feed

Live traffic comes from the same ACARS backend the web tracker uses:

```
connect  https://site--acars-backend--6dmjph8ltlhv.code.run
emit     join_server_room  <server name>
on       all_flights_update  -> { server, flights: [...] }
```

Payloads are decoded off the main thread; a malformed aircraft is dropped rather
than failing the whole packet.

Everything else the app asks for is a plain REST call on top of that, and each
one is cached so a screen opened twice costs nothing:

| What | Where |
| --- | --- |
| Aircraft photo | `indgo /api/aircraft/lookup?type=&livery=` |
| Airport photo | `indgo /api/airports/{icao}` |
| Airport details — city, elevation, airspace class, timezone, 3D buildings | `acars /api/airport/{icao}` |
| Flown path so far | `acars /api/flights/{id}/history` |
| Filed route | `acars /flights/{session}/{id}/plan` |
| ATIS | `acars /api/live/airport/{session}/{icao}/atis` |
| METAR | `metar.vatsim.net` |

The last two are addressed by session rather than by server, so they resolve one
through `acars /if-sessions` first — held for five minutes, per server, because
switching servers must not hand the new one the old one's id.

## Bundled datasets

Three things ship in the app rather than being fetched, so the parts of the
tracker that don't need the network don't wait on it:

| File | Rows | From |
| --- | --- | --- |
| `airports.txt` | 17,737 | VAT-Spy, as the old tracker shipped it |
| `runways.txt` | 14,511 | `old/www/runways.json`, distilled |
| `sprite-uvs.json` | — | the old tracker's icon sheet |

`runways.json` is 26 MB of survey rows, most of them for strips the airport table
has never heard of. The bundled table keeps only the columns the field panel
shows, only for airports that resolve, and only for runways that are still open —
467 KB, parsed off the main thread at launch. To regenerate it after the source
changes, keep the pipe-delimited shape `ICAO|low|high|length|width|surface|lighted|lowHeading|highHeading`,
with `-1` for a heading neither the survey nor the designator gave.

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
