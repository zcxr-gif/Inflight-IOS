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

### When the portal and the build disagree

If a change in the portal has no effect on the build at all — a profile
deleted there still turns up on the builder, a new one never does — then the
profiles being signed with are not coming from Apple. Codemagic stores uploaded
provisioning profiles under **Team settings → Code signing identities**, installs
them on every build machine, and those copies shadow the `ios_signing` fetch
entirely. Ones left over from the Capacitor pipeline will happily sign this one
for months.

Deleting them from Codemagic hands the portal back its authority. The signature
of having done so is the error changing to `No matching profiles found for
bundle identifier ...` — that is the API fetch running for the first time and
reporting honestly, rather than a stored file quietly standing in.

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

## Signing files, from Windows

The build signs with three files uploaded to Codemagic by hand, referenced by
name from `codemagic.yaml`. Two are downloaded from the portal; the third has to
be assembled, because Apple hands out a certificate and keeps the private key
question to itself.

A `.p12` is the certificate *and* its private key in one archive. Exporting one
from Keychain needs the Mac that generated the original request. Without that
Mac the key does not exist anywhere, and the only way forward is a new
certificate — which is a CSR, and a CSR is openssl, which runs anywhere.

```bash
# 1. A private key, and a request built from it. This key never leaves the
#    machine and is half of the .p12 at the end.
openssl genrsa -out inflight.key 2048
openssl req -new -key inflight.key -out inflight.csr \
  -subj "/emailAddress=you@example.com/CN=Inflight Distribution/C=US"

# 2. Upload inflight.csr at Certificates -> + -> Apple Distribution, download
#    the .cer, then join the two halves.
openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
openssl pkcs12 -export -inkey inflight.key -in distribution.pem \
  -out inflight_distribution.p12
```

In Git Bash, prefix the `req` line with `MSYS_NO_PATHCONV=1`. MSYS rewrites any
argument starting with `/` into a Windows path, so `-subj` silently arrives
mangled and the certificate comes out with the wrong subject.

Apple allows two Apple Distribution certificates per account, so a new one
usually means revoking an old one first. Revoking does not affect builds already
on the App Store, but it **does** invalidate every profile issued against that
certificate — so regenerate both profiles afterwards, selecting the new
certificate, and download them again.

Uploaded under **Team settings -> Code signing identities**, with reference
names matching what `codemagic.yaml` asks for:

| File | Reference name |
| --- | --- |
| `inflight_distribution.p12` (with its password) | `inflight_distribution_cert` |
| App Store profile for `com.tracker.Inflight` | `inflight_distribution` |
| App Store profile for `com.tracker.Inflight.widgets` | `inflight_widgets_distribution` |

Leave nothing else in that list. Profiles stored there are installed on every
builder whether or not anything asks for them, which is how a set left over from
the Capacitor pipeline came to sign this one for months — see above.

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

`APNS_HOST` picks which environment is tried **first**, not which one is used.
A token minted by a development-signed build is rejected by the production host
with `400 BadDeviceToken` — which is byte for byte the rejection for a token
that is genuinely rubbish, and `push.cjs` used to believe it. It pruned the
token, and with it the `device_watch` rows, which that token is the only owner
of. So the first event a mismatched build should have received deleted its
watchlist from the server and every later one had nothing to deliver to: the app
went silent, and the evidence went with it.

It now learns instead. One `BadDeviceToken` is retried against the other host,
whichever accepts it is remembered per token in `apns_environment`, and a token
is pruned only when both have refused it. Nothing to configure, and a fleet that
is a mixture of TestFlight and Xcode builds — which is every fleet during
development — works without anybody choosing a side.

`/api/admin/diagnostics` counts the ones that turned out to be on the other
environment, under `push.onAlternateEnvironment`. On a production deployment
that is a count of builds shipped with `aps-environment: development`, which is
worth knowing and was invisible before.

## Time Sensitive Notifications

`com.apple.developer.usernotifications.time-sensitive` is **deliberately not**
in `Support/InflightTracker.entitlements` yet.

The takeoff push is sent at `interruption-level: time-sensitive`, and the
descent and arrival notices at `active` with priority 10. Without the
capability iOS accepts them and quietly demotes the time-sensitive one to
`active` — a banner still arrives, it simply does not break through a Focus.
That is a real loss and a small one.

Adding the key before the capability exists on the App ID is a larger one. A
restricted entitlement missing from the provisioning profile does not degrade;
it fails codesign, and every release stops until somebody opens the portal. So
the order is:

1. **Identifiers → App IDs → `com.tracker.Inflight`**, enable **Time Sensitive
   Notifications**.
2. Regenerate the App Store profile (changing capabilities marks the existing
   one Invalid) and re-upload it to Codemagic.
3. Add the key to the entitlements file, and add
   `--require "com.tracker.Inflight:com.apple.developer.usernotifications.time-sensitive"`
   to the `check-provisioning.py` call in `codemagic.yaml`, so a profile that
   loses it again fails in the signing step rather than at archive time.

`GET /api/watchlist/capabilities` reports `push: true` only when the key, key
id and team id are all present, so it is the fastest way to check the backend
half is configured.

## Entitlements per build type

`Support/InflightTracker.entitlements` ships `aps-environment` as
`development`. An App Store export rewrites it to `production` as part of
re-signing; a build run from Xcode keeps `development` and is handed a sandbox
token.

Both work now — see the APNs key section above, where the backend learns which
environment a token belongs to rather than assuming. Getting this wrong used to
mean a build that registered for APNs successfully and then never received
anything, and it is still worth getting right: the fallback costs one wasted
request per token, once.

## Your own flight, announced to you

This is the one people ask for by name, usually as "why can an airline's app
tell me when we start descending and this can't".

The answer is that those apps are not talking to the aeroplane. Nothing in a
phone's pocket is attached to an airliner: a server watches a feed describing
every flight, notices a state change on one row of it, and pushes a sentence to
the phones that asked about that row. The phone contributes an address and
nothing else — which is why it works with the phone asleep, or, in this app's
case, with Infinite Flight in the foreground and everything else suspended
behind it.

Every part of that was already here and pointed the wrong way.
`friend_events.cjs` diffs consecutive feed snapshots and decides, with
hysteresis, when an aircraft has left the ground. `push.notifyAccount`
addresses the person flying rather than the people watching them.
`pilot_profiles.if_username` joins a feed row to an account. But the detector
only ever ran for pilots *somebody else* was watching, and its pushes went to
the watcher — so the one person guaranteed to care about a flight, the pilot in
it, was the one person nothing was addressed to.

`own_flight_events.cjs` is that same detector, read for the pilot:

| | When | How it arrives |
| --- | --- | --- |
| **Airborne** | A confirmed ground → air transition | Active, silent |
| **Top of descent** | Reached a cruise above 12,000 ft, then several consecutive descending samples | Active, with a sound, at APNs priority 10 — it is the moment there is something to do |
| **30 minutes out** | The distance still to run over the speed being made good falls under `OWN_FLIGHT_APPROACH_MINUTES` | Active, with a sound, at priority 10 — same reasoning |
| **On the ground** | A confirmed air → ground transition | Passive, silent |

Nothing needing height above ground is announced, and that is a limit rather
than an omission: the feed carries MSL altitude only, so 2,000 ft over
Amsterdam and 2,000 ft over Denver are the same number and a different
situation. "On final" would be wrong in mountains, which is worse than absent.

### Thirty minutes out

The one people plan around: it is the difference between finding out you are on
approach and deciding to be at the controls for it. It needs no height above
ground and no filed schedule — only where the arrival field is, where the
aeroplane is, and how fast it is closing — so unlike "on final" it is derivable
from what the feed carries, and derivable everywhere.

Three guards, each for a way the naive version announces a moment that never
happened:

* **The flight must have been seen further out than the window first.** Without
  it, a redeploy mid-arrival, a short hop that begins inside the window, and a
  pilot who spawns twenty miles out all get told they are half an hour away when
  they are not.
* **A groundspeed floor of 120 kt.** A stationary aeroplane is infinitely far
  from everywhere, and dividing by a taxi speed says so.
* **A distance floor of 12 miles.** For the case the speed floor cannot catch —
  an aeroplane taxiing in four miles from its own destination.

The estimate is deliberately the simplest one there is, distance over the speed
being made good, because everything better needs a wind model or an arrival
profile that the feed does not carry. It runs a few minutes optimistic on a
flight that still has to slow down; the notice says "about", and being early to
warn somebody is the right direction to be wrong in.

A diversion is the honest limit: the estimate is against the field that was
filed. That is the same limit the route strip on the map has always had.

`OWN_FLIGHT_APPROACH_MINUTES` moves the window (default 30, clamped to 1–180),
and the backend reports the number it is actually using in
`/api/watchlist/capabilities` as `approachMinutes` — so the sentence in the
app's settings comes from the thing that decides it rather than being written
down twice.

### Knowing which aeroplane is yours

Two joins, and the app tries not to make the pilot supply either.

**The flight id**, `pilot_flight_alert_live_targets`. `pilot_live_status.
flight_id` is the id the public feed uses, written by the app out of the running
simulator, and a row carrying it is the pilot saying "this aeroplane on your map
is me" in terms that involve no name matching at all. Thirty seconds of Connect
in the background window as they switch into the sim is enough to publish one,
and the announcements then run for the rest of the flight with the app closed.

**The handle**, `pilot_flight_alert_targets`. `pilot_profiles.if_username`
against the name the feed carries — the only route for somebody who has never
used Connect. It is also the weaker one, and is treated as such: a handle
claimed by two accounts reaches **neither**, unless exactly one of them is
verified, because `if_username` is a claim that nothing checks and the
alternative is telling a stranger the movements of a pilot they merely said they
were. Asserted in `supabase/tests/flight_alerts.sql`.

Where the handle comes from matters, because a blank or misspelled one is the
commonest way to hear nothing. Connect has read `infiniteflight/current_user`
on every connection since it existed and used to display it and nothing more;
`ConnectSession.adoptIdentity` now fills in a **blank** `if_username` from it,
and when the profile says something *different* the Connect panel offers the
swap rather than rewriting a public profile behind the pilot's back.

Plus, on both routes:

* **A device registered against the account** — the same `/api/push/devices`
  row the sim-drop notice needs.
* **`pilot_profiles.flight_alerts`**, which defaults on and is a toggle in the
  profile editor.

Diagnosed from the `ownFlightEvents` block of `/api/admin/diagnostics`:
`targets` is how many pilots are reachable by handle and `liveTargets` how many
by a flight id they published, so both at zero while signed-in pilots are flying
means the join is missing rather than the detector being broken. `tracking` is
how many of their flights currently hold state.

## Where the switches live

One screen — `Views/NotificationsPanel.swift`, reached from Settings and from
the friends panel. Both directions are on it, because a person setting them does
not care which of the two the server had to address from.

The preferences are held **per device**, in `device_prefs`, keyed by the APNs
token — including the own-flight ones, which are addressed to an account. That
looks inconsistent and is not: this is a preference about a notification centre,
and the phone is what has one. Two phones signed into the same account are two
sets of opinions, and `notifyAccount` filters per device for that reason.

A kind `push.cjs` does not recognise is not filtered at all, so a client built
before a switch existed keeps receiving what it always did rather than losing it
to a preference it never sent.

The panel also draws the delivery chain, in the order it breaks: iOS permission,
the APNs token, the server's push capability, the account registration. Every
one of those fails silently on its own, which is exactly why a screen that shows
only the switches can say "on" to somebody who will never hear a thing.

## What each piece needs to work

| Feature | Needs |
| --- | --- |
| Takeoff / landing / online / offline pushes | APNs key on the backend, notification permission on the device |
| "Inflight stopped reading your sim" | The above, plus being signed in — it is the one push addressed to an account rather than to a device token, so it needs the `/api/push/devices` registration `PushService.syncAccountRegistration` makes on launch and on sign-in |
| Live banner raised by a friend's takeoff | The above, plus `NSSupportsLiveActivities` (set) and a push-to-start token, which iOS only issues on a real device — never the simulator |
| Airborne / top of descent / 30 minutes out / landed, about your own flight | The above, plus either an Infinite Flight username on your profile or one Connect session on the flight — either is enough to join an aeroplane on the map to your account |
| 30 minutes out, specifically | Also a destination on the flight plan. Without an arrival field there is nothing to be thirty minutes from, and nothing is announced |
| Home-screen widgets | The app group on both targets |
| Aircraft photos on widgets | Nothing extra. The app caches them into the group as it fetches them for the flight window; a widget with no cached photo draws its own sky instead |

## Testing notes

Live Activities cannot be started by push on the simulator, and
`pushToStartTokenUpdates` never yields there. A takeoff banner has to be
tested on a device.

`/api/admin/diagnostics` also carries a `liveHydration` block, which is where a
missing sim-drop notice is diagnosed. `watching: 0` means nobody is broadcasting
through Connect at all; a non-zero `watching` with `matched: 0` means none of
those pilots has a flight on the feed right now; and `alerts` counts the notices
actually delivered. A notice that was due and reached nobody is almost always
the account registration above — the pilot is signed in on the device, but the
device never posted its token to `/api/push/devices`, so `push_devices` has no
row to address.

The backend's `/api/admin/diagnostics` includes a `friendEvents` block —
how many pilots are being watched, how many flights currently hold ground/air
state, and how many are mid-flip. A takeoff nobody received is diagnosed from
there first: `watched: 0` means the subscription never arrived, and
`tracking: 0` with a non-zero `watched` means nobody being watched is
currently online.
