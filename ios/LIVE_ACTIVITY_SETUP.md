# Live Activity Setup (one-time Xcode wiring)

The Swift source files for the Live Activity are already in the repo:

```
ios/App/InflightLiveActivity/
  InflightActivityAttributes.swift    # Shared attributes (must be in BOTH targets)
  InflightLiveActivity.swift          # Widget + SwiftUI views (widget target only)
  Info.plist                          # Widget extension Info.plist

ios/App/App/
  LiveActivityPlugin.swift            # Capacitor plugin (main app target)
  LiveActivityPlugin.m                # CAP_PLUGIN macro registration (main app target)
  Info.plist                          # Already has NSSupportsLiveActivities = YES
```

Xcode can't auto-discover a new target from disk — you have to add it once.

## Steps

1. Open `ios/App/App.xcworkspace` in Xcode.
2. **Add the Widget Extension target:**
   - File > New > Target
   - Choose **Widget Extension** (iOS)
   - Product Name: `InflightLiveActivity`
   - **Uncheck** "Include Live Activity" (the template inserts boilerplate we already have on disk)
   - **Uncheck** "Include Configuration App Intent"
   - Embed in Application: `App`
   - Click Finish. When prompted to activate the scheme, choose **Activate**.
3. Xcode will generate a starter `InflightLiveActivity.swift` and `Info.plist` inside the new target. **Delete the generated files** (move to trash) — keep the new target/folder.
4. In the Project Navigator, right-click the new `InflightLiveActivity` group and **Add Files to "App"…**
   - Add `ios/App/InflightLiveActivity/InflightLiveActivity.swift` to the **InflightLiveActivity target only**.
   - Add `ios/App/InflightLiveActivity/Info.plist` to the **InflightLiveActivity target only** (and set the target's `INFOPLIST_FILE` build setting to point at it if Xcode doesn't auto-detect).
   - Add `ios/App/InflightLiveActivity/InflightActivityAttributes.swift` to **BOTH** the `App` target **and** the `InflightLiveActivity` target. This shared file is what lets the main app and the widget agree on the data shape.
5. In the Project Navigator, add the main-app plugin files to the **App target only**:
   - `ios/App/App/LiveActivityPlugin.swift`
   - `ios/App/App/LiveActivityPlugin.m`
6. **Deployment target:** make sure the `InflightLiveActivity` target's iOS Deployment Target is **16.1 or later** (Build Settings > Deployment > iOS Deployment Target). The main app can stay where it is — the Live Activity code is gated with `@available(iOS 16.1, *)`.
7. **Signing:** select the `InflightLiveActivity` target > Signing & Capabilities, set the Team to the same one as the main app, and let Xcode auto-generate the bundle id (it will be something like `com.tracker.Inflight.InflightLiveActivity`).
8. Build and run on a real device (Live Activities don't render in the simulator pre-iOS 17).

## How the wiring works at runtime

- JS calls `window.InflightLiveActivity.start({...})` (defined in `www/liveActivity.js`).
- That hits the Capacitor plugin `LiveActivityPlugin` registered as `"LiveActivity"` via the `CAP_PLUGIN(...)` macro in `LiveActivityPlugin.m`.
- The plugin calls `Activity.request(...)` with `InflightActivityAttributes`. iOS displays the widget defined in `InflightLiveActivity.swift`.
- On every live-data tick in `flight.js` the JS calls `update(...)`, which the plugin forwards to `Activity.update(...)`. The widget's SwiftUI views re-render automatically.
- When the flight lands (or the user taps the bell off), `end(...)` dismisses the activity.

## Phase 2 (push-driven updates while the app is closed)

When you're ready, swap the `pushType: nil` argument in `LiveActivityPlugin.swift` for `pushType: .token`, observe the activity's `pushToken` updates, POST them to the backend, and have the backend send Live Activity push payloads via APNs (`apns-push-type: liveactivity`). The widget code does not change.
