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
