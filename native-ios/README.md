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

## App Store Connect prerequisite

The first time this ships, App Store Connect needs an App ID for the
widget's bundle identifier: `com.tracker.Inflight.LiveActivity`. Codemagic's
App Store Connect integration creates this automatically the first time
`xcode-project use-profiles` runs against the new target, but if signing
fails on the first build with a "no profile" error, log into App Store
Connect → Identifiers → "+" and register `com.tracker.Inflight.LiveActivity`
manually.

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
