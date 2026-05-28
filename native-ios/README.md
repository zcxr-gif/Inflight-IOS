# native-ios/

Native iOS sources that get stitched into the Capacitor-generated Xcode
project at build time. The `ios/` folder itself is **not** committed —
`codemagic.yaml` wipes and regenerates it on every build, so any files
that live under `ios/` would be lost.

## Layout

```
native-ios/
  inject_live_activity.rb         # Build-time patcher (runs on Codemagic Mac)
  LiveActivityPlugin.swift        # Capacitor plugin (ActivityKit bridge)
  LiveActivityPlugin.m            # CAP_PLUGIN macro registration
  InflightLiveActivity/
    InflightActivityAttributes.swift   # Shared data model (app + widget)
    InflightLiveActivity.swift          # Widget SwiftUI views
    Info.plist                          # Widget extension Info.plist
```

## How it gets into the build

In `codemagic.yaml`, after the standard `npx cap add ios && npx cap sync`
steps, we run:

```bash
ruby native-ios/inject_live_activity.rb
```

That script uses the `xcodeproj` ruby gem (pre-installed on Codemagic
Mac runners via CocoaPods) to:

1. Copy the Swift files into `ios/App/App/` and `ios/App/InflightLiveActivity/`.
2. Add `NSSupportsLiveActivities = true` (+ `NSSupportsLiveActivitiesFrequentUpdates`)
   to the main app `Info.plist`, and write the `aps-environment` push
   entitlement to `App.entitlements` (see "Backend-driven push updates").
3. Add `LiveActivityPlugin.swift` + `.m` to the main `App` target.
4. Create a new `InflightLiveActivity` Widget Extension target.
5. Add the widget Swift files + Info.plist to the new target.
6. Add `InflightActivityAttributes.swift` to **both** targets (shared data
   model — the main app constructs activities, the widget renders them).
7. Make `App` depend on `InflightLiveActivity` and embed it via an "Embed
   App Extensions" copy phase.
8. Configure deployment target (16.1+), bundle id (`<app>.LiveActivity`),
   signing style (Automatic — inherits team from main app).

The script is **idempotent** — re-running on a project that already has
the target is a no-op.

## App Store Connect setup — handled automatically

The widget extension uses a separate bundle ID
(`com.tracker.Inflight.LiveActivity`). The "iOS Code Signing" step in
`codemagic.yaml` runs:

```
app-store-connect fetch-signing-files com.tracker.Inflight.LiveActivity \
  --platform IOS --type IOS_APP_STORE --create
```

With `--create`, Codemagic uses its App Store Connect API key to create
the App ID and the provisioning profile if either doesn't exist yet,
then `xcode-project use-profiles` wires the profile into the widget
target. No manual App Store Connect steps required.

If signing ever does fail with `"InflightLiveActivity" requires a
provisioning profile`, the likely cause is the Codemagic App Store
Connect integration losing its Admin role — re-check the key in
Codemagic's Team settings.

## Running locally (optional, requires Mac)

```bash
npm install
npx cap add ios
npx cap sync
gem install xcodeproj plist   # if not already
ruby native-ios/inject_live_activity.rb
open ios/App/App.xcodeproj
```

## Backend-driven push updates (APNs Live Activity)

The Live Activity is requested with `pushType: .token`, so ActivityKit
issues an APNs push token the backend can use to update the lock-screen
plane / NM / ETE **while the phone is locked and the app is suspended**.
The app does the plumbing; the backend (the same one serving the flight
sockets) needs to store the tokens and send APNs pushes.

### What the app emits (over the existing `sectorOpsSocket`)

| Socket event | Payload | When |
|---|---|---|
| `live_activity_token` | `{ platform:"ios", flightId, activityId, token, server, ts }` | When a pinned flight's activity gets/rotates its push token (re-sent on every socket reconnect). |
| `live_activity_pushtostart_token` | `{ platform:"ios", token, ts }` | Device-level token (iOS 17.2+). Lets the backend *create* an activity remotely. |
| `live_activity_unregister` | `{ platform:"ios", flightId, ts }` | When the user stops tracking or the flight lands. Stop pushing this token. |

The backend should map `token → flightId` and, whenever it has fresh
position data for that flight, send an APNs push to the token.

### APNs request the backend must send

- **Host:** `api.push.apple.com` (production — matches the distribution
  build; use `api.sandbox.push.apple.com` only for a debug-signed build).
- **`:path`:** `/3/device/<token>`
- **Headers:**
  - `apns-push-type: liveactivity`
  - `apns-topic: com.tracker.Inflight.push-type.liveactivity`
  - `apns-priority: 10` (use `5` for low-priority/budgeted updates)
  - `authorization: bearer <APNs JWT>` (token-based auth with your APNs key)
- **Body:**

```jsonc
{
  "aps": {
    "timestamp": 1748450400,          // seconds; when YOU generated this update
    "event": "update",                // or "end"
    "stale-date": 1748450700,         // optional: when iOS should grey it out
    "relevance-score": 100,           // optional
    "content-state": {
      "distanceToDestinationNm": 412.3,
      "totalDistanceNm": 980.0,
      "currentETA": 1748455800,       // Date -> Unix epoch SECONDS (number)
      "scheduledDeparture": 1748448000,
      "scheduledArrival": 1748455200,
      "currentATD": 1748448120,       // omit if unknown
      "isLanded": false
    }
  }
}
```

To **start** an activity remotely (push-to-start, iOS 17.2+) send the same
request to the `live_activity_pushtostart_token`, with
`"event": "start"`, an `"attributes-type": "InflightActivityAttributes"`,
an `"attributes": { flightId, callsign, airlineName, departureIcao,
arrivalIcao }` object, and the `content-state` above.

### Contract notes (must match the Swift model exactly)

- `content-state` keys are the `ContentState` property names verbatim:
  `distanceToDestinationNm`, `totalDistanceNm`, `currentETA`,
  `scheduledDeparture`, `scheduledArrival`, `currentATD`, `isLanded`.
- **All `Date` fields are Unix epoch *seconds*** (numbers), per Apple's
  ActivityKit push decoding — not milliseconds, not ISO-8601.
- Send `event:"end"` (optionally with a final `content-state`) to retire the
  activity; the app also ends it locally on landing.
- `currentETA` drives the lock-screen countdown, `distanceToDestinationNm` +
  `totalDistanceNm` drive the plane's position. Keep them consistent
  (ETA ≈ now + remaining/groundspeed) so the plane and the timer agree.

### Build / signing prerequisites (account side)

`pushType: .token` needs the `aps-environment` entitlement, which the
injector now writes, **plus** an App ID with Push Notifications enabled and
a provisioning profile that includes it:

1. Enable **Push Notifications** on App ID `com.tracker.Inflight`.
2. Regenerate the App's distribution profile so it carries that capability
   (the Codemagic `fetch-signing-files ... --create` step will do this for
   the App ID once the capability is enabled).
3. Create an **APNs Auth Key** (.p8) for the backend's token-based JWT.

Until those are in place the activity still starts and local (foreground)
updates work — the push token just won't be delivered.

## Why not just commit the `ios/` folder?

That was the obvious alternative. We picked the inject-at-build-time
approach because the existing pipeline already treats `ios/` as
disposable, and switching to a checked-in Xcode project would require
both keeping it in sync manually and removing the wipe step from CI.
The inject script is small enough to iterate on if something breaks,
and changes to the Swift code are reviewable in `native-ios/` without
the noise of a regenerated `pbxproj` diff.
