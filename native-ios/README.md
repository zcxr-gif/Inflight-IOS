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
2. Add `NSSupportsLiveActivities = true` to the main app `Info.plist`.
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

## Remote push groundwork (`INFLIGHT_ENABLE_PUSH`)

The plugin contains everything needed for ACARS-fed push: APNs device
token registration (`registerForRemotePush`, token surfaced via the
`remotePushToken` listener event), push-capable Live Activities
(`wantsPushUpdates` on `start`, token via `liveActivityPushToken`), and
push-to-start tokens on iOS 17.2+ (`liveActivityPushToStartToken`).
`www/WatchlistService.js` uploads these tokens to the ACARS backend when
its capabilities probe reports `push: true`.

None of it activates in today's builds, because APNs registration
requires the `aps-environment` entitlement. The inject script only adds
that entitlement (Phase A3) when `INFLIGHT_ENABLE_PUSH=1` is set in the
Codemagic environment — and the entitlement only signs successfully once
the App ID (`com.tracker.Inflight`) has the **Push Notifications**
capability enabled in App Store Connect. Flipping it on early fails the
signing step, which is why it's opt-in.

Checklist when the backend ships:
1. Enable Push Notifications on the App ID in App Store Connect
   (Codemagic's `fetch-signing-files` will then mint a profile that
   carries the entitlement).
2. Give the ACARS backend the APNs `.p8` signing key.
3. Set `INFLIGHT_ENABLE_PUSH=1` in `codemagic.yaml`.
4. Have `/api/watchlist/capabilities` return `push: true`.

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

## Why not just commit the `ios/` folder?

That was the obvious alternative. We picked the inject-at-build-time
approach because the existing pipeline already treats `ios/` as
disposable, and switching to a checked-in Xcode project would require
both keeping it in sync manually and removing the wipe step from CI.
The inject script is small enough to iterate on if something breaks,
and changes to the Swift code are reviewable in `native-ios/` without
the noise of a regenerated `pbxproj` diff.
