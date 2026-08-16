# Notifications, Live Activities and widgets

What has to be true outside this repository before the friends list can
actually tell anyone anything. None of it can be set from code, and every item
here fails quietly rather than loudly — the app builds, installs and runs, and
simply never notifies.

## Apple Developer portal

Two App IDs are involved:

| App ID | Needs |
| --- | --- |
| `com.tracker.Inflight` | **Push Notifications**, **App Groups** |
| `com.tracker.Inflight.widgets` | **App Groups** |

Both must be in the **same** app group: `group.com.tracker.Inflight`. The
widgets read the flight the app wrote; a group that differs by a character
leaves every tile on its empty state with nothing logged anywhere.

Codemagic's signing block matches bundle identifiers by prefix, so the
extension's profile comes down with the app's — but only once the App ID
exists with the capability enabled.

### The one-time setup, in order

Nothing below can be done from CI. `--create` can register an App ID, but the
App Store Connect API cannot attach an app group to one, so the group has to be
ticked by hand in **Certificates, Identifiers & Profiles**.

1. **Identifiers → App Groups.** Create `group.com.tracker.Inflight` if it does
   not exist yet. Everything else refers back to it.
2. **Identifiers → App IDs → `com.tracker.Inflight`.** Enable **App Groups**
   and **Push Notifications**. Enabling App Groups is not enough on its own —
   click *Edit* next to it and tick `group.com.tracker.Inflight`. An identifier
   with the capability on and no group selected still signs nothing.
3. **Identifiers → App IDs → `com.tracker.Inflight.widgets`.** Register it as an
   explicit (non-wildcard) App ID if the build has not already created it, then
   enable **App Groups** and tick the same group. It does *not* need Push.
4. **Profiles.** Delete any App Store profile already issued for either App ID.
   A profile is a snapshot of the capabilities at the moment it was generated,
   so one issued before step 2 or 3 is wrong: changing an App ID's capabilities
   marks its existing profiles **Invalid**, and an invalid profile has to be
   regenerated before it can sign anything again. Deleting is the blunter half
   of the same fix and leaves nothing for the build to pick up by mistake — the
   next build fetches a fresh one.

   `com.tracker.Inflight` has been signing releases for a long time, so it
   certainly has a profile that predates all of this and needs replacing.
   `com.tracker.Inflight.widgets` most likely has none at all, which is the
   whole reason the archive failed — nothing to delete there.

**Do all of it before the next build.** Left until after, the pipeline's
`--create` registers `com.tracker.Inflight.widgets` for you *without* App
Groups — the API cannot add it — and issues a profile against that. Enabling
the capability afterwards then invalidates the profile that was just made, and
step 4 has to be done a second time.

The failure this prevents is:

```
"InflightWidgets" requires a provisioning profile with the App Groups feature.
Select a provisioning profile in the Signing & Capabilities editor.
```

which xcodebuild raises at archive time when the extension target ended up with
no profile at all — not, despite the wording, when a profile was chosen badly.
`Scripts/check-provisioning.py` runs in the signing step and fails earlier with
the specific App ID and capability at fault; it can be pointed at a profiles
directory by hand to diagnose the same thing off the builder:

```
python3 ios-native/Scripts/check-provisioning.py \
  --require "com.tracker.Inflight.widgets:com.apple.security.application-groups=group.com.tracker.Inflight"
```

## APNs key

The backend signs its own provider JWTs (`push.cjs`) and needs a `.p8` auth
key from **Certificates, Identifiers & Profiles → Keys**, with the Apple Push
Notifications service enabled.

Set on the backend:

| Variable | What |
| --- | --- |
| `APNS_KEY_P8` | Contents of the `.p8`. Literal `\n` sequences are accepted, so it pastes into a single-line env var. |
| `APNS_KEY_ID` | The key's ID. |
| `APNS_TEAM_ID` | Apple developer team ID. |
| `APNS_TOPIC` | Bundle id. Defaults to `com.tracker.Inflight`. |
| `APNS_HOST` | `https://api.push.apple.com` (default) or `https://api.sandbox.push.apple.com` for development builds. |

The sandbox host is not optional for TestFlight-adjacent testing: a token
minted by a development-signed build is rejected by the production host, and
the rejection looks exactly like a dead token.

`GET /api/watchlist/capabilities` reports `push: true` only when the key, key
id and team id are all present, so it is the fastest way to check the backend
half is configured.

## Entitlements per build type

`Support/InflightTracker.entitlements` ships `aps-environment` as
`development`. The App Store export rewrites it to `production`. A build
signed with the wrong one registers for APNs successfully and then never
receives anything.

## What each piece needs to work

| Feature | Needs |
| --- | --- |
| Takeoff / landing / online / offline pushes | APNs key on the backend, notification permission on the device |
| Live banner raised by a friend's takeoff | The above, plus `NSSupportsLiveActivities` (set) and a push-to-start token, which iOS only issues on a real device — never the simulator |
| Home-screen widgets | The app group on both targets |
| Aircraft photos on widgets | Nothing extra. The app caches them into the group as it fetches them for the flight window; a widget with no cached photo draws its own sky instead |

## Testing notes

Live Activities cannot be started by push on the simulator, and
`pushToStartTokenUpdates` never yields there. A takeoff banner has to be
tested on a device.

The backend's `/api/admin/diagnostics` includes a `friendEvents` block —
how many pilots are being watched, how many flights currently hold ground/air
state, and how many are mid-flip. A takeoff nobody received is diagnosed from
there first: `watched: 0` means the subscription never arrived, and
`tracking: 0` with a non-zero `watched` means nobody being watched is
currently online.
