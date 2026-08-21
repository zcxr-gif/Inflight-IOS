# Infinite Flight Connect

Reading the pilot's own aircraft out of the simulator, over the local network.

## The constraint everything else follows from

Connect is a **LAN API**. It is served by the copy of Infinite Flight running on
a device, to anything on the same Wi-Fi, with no account and no token. There is
no hosted endpoint, so `acars-backend` can never reach it and none of this can
happen server-side.

That single fact decides the shape of the feature:

* It **never replaces the live feed.** The feed is a cloud service describing
  everybody's flights and is what the map is built on. Connect describes one
  aircraft, in far more detail, and only sometimes. The two are joined rather
  than ranked: when Connect goes quiet mid-flight the server fills the position
  back in from the feed, and says which of them it came from — see *The position
  the server can see, and the one it cannot*.
* Every consumer must work **without** it. The logbook records flights inferred
  from the feed exactly as it always has; Connect upgrades those rows rather
  than being required for them.

## One device or two

Both work, differently. An earlier version of this document said same-device was
impossible; that was wrong, and wrong in a way worth writing down.

| | Address | Permission | What you get |
|---|---|---|---|
| **Two devices**, same Wi-Fi | LAN, discovered or typed | Local network prompt; discovery may need the multicast entitlement | Everything, live, for the whole flight |
| **One iPad**, Split View or Stage Manager | `127.0.0.1` | **None** | Everything, live, for the whole flight |
| **One iPhone**, or iPad full screen | `127.0.0.1` | **None** | A live sample and a status row each time you switch into the sim, the landing read when you come back — and the flight stays on other people's maps throughout, from the feed |

Three things make the one-device case work.

**Loopback needs no permission at all.** Apple's local-network privacy covers
the *network* — unicast to a LAN address, multicast, broadcast, Bonjour.
`127.0.0.1` is none of those, so a same-device connection never raises the
prompt and never touches the multicast entitlement question. Same-device is
therefore the configuration with the *fewest* obstacles, not the most.

**The simulator holds the last landing until the next one.** Nobody has to be
watching at the moment of touchdown. While you fly, iOS suspends Inflight behind
Infinite Flight — there is no honest way around that, since the background modes
that would keep a socket alive for fourteen hours are `audio` and `location` and
claiming either to poll a flight simulator would be a lie to the user and to App
Review. But the measurement is still sitting there afterwards. So the flight is
recorded from the live feed as it always is, and `ConnectSession.catchUp()` fills
the landing in when you next open the app.

**The link is made on the way out, not on the way in.** This is the part that
was wrong for as long as the feature existed, and it made same-device on a phone
do nothing at all. Infinite Flight answers on 10112 only while it is the app in
front; every attempt Inflight made was made from *its* own foreground, which is
exactly when iOS has the simulator suspended and its socket answering nobody. A
pilot switching back and forth to check was inspecting the one state in which it
cannot work, and the panel said "Waiting for Infinite Flight" through an entire
flight with nothing wrong at either end.

So `didEnterBackground` no longer tears the session down when the sim is on this
device. It asks iOS for a finite window — `beginBackgroundTask`, around thirty
seconds, no background mode and nothing claimed that is not true — and starts a
fresh attempt inside it, because the app that just replaced us *is* the
simulator. Thirty seconds is enough to attach, resolve the manifest, read the
flight id, take a telemetry sample, write one `pilot_live_status` row that the
server then keeps alive from the feed, and say whether it worked. It is one
window per app switch rather than a socket held for a flight, which is the
difference between "open Infinite Flight and come back" producing something and
producing nothing.

The saying-so matters as much as the connecting. The notice is posted from
inside that window, so it arrives on top of Infinite Flight — where the pilot
is, and where the setting that fixes a failure lives. A failure is announced
too, once, carrying the same sentence the panel would have shown
(`ConnectSession.announceOutcome`), and the same sentence is not sent twice in a
row: somebody who has not switched Connect on inside the sim needs telling once,
not on every app switch.

That is why `pilot_logbook_attach_landing` exists. `pilot_logbook` deliberately
has no UPDATE policy — *a logbook you can rewrite is a logbook nobody reading a
profile has any reason to believe* — so completing a row afterwards goes through
a `security definer` function that can only ever fill landing columns that are
still empty. It cannot change a flight's time, distance, route or altitude, and
it cannot overwrite a landing already recorded. Offering the same landing twice
is free.

## What it buys

Two things the feed cannot give at any price.

**The landing.** `simulator/statistics/last_landing/…` — vertical speed at
touchdown, peak g, distance off the centreline, distance from the aiming point,
and Infinite Flight's own score. The feed cannot produce these: a touchdown
lasts a fraction of a second and the feed samples seconds apart, so any landing
rate derived from it is an average over an interval that mostly does not contain
the landing.

**The join.** `infiniteflight/live/current_flight/id` is the *same id the public
feed uses*. Without it, Connect telemetry would be numbers from nowhere in
particular. With it, the app knows rather than guesses which aeroplane on the map
is the one being flown here — and `infiniteflight/current_user` is the pilot's
handle read out of the running sim rather than typed into a settings field,
which is a materially stronger claim than anything `pilot_profiles.if_username`
carries today.

Both of those were read, displayed, and then dropped, which made the stronger
claim worth nothing. They are now the two ways the server knows whose flight it
is looking at when it announces a takeoff or a top of descent — the flight id
through the `pilot_live_status` row, and the handle through
`ConnectSession.adoptIdentity`, which fills in a blank `if_username` from the
sim and offers the swap in the panel when the profile says something else. See
*Your own flight, announced to you* in `NOTIFICATIONS.md`. This is also why the
username field carries several candidate spellings now and the other two do
not: a rename that costs a line in a panel is a nuisance, and a rename that
silently costs the join is a pilot who hears nothing about their own flight.

## The wire

Version 2, TCP port **10112**. Version 1 (JSON, 10111) is deprecated and not
spoken. Everything is little-endian.

```
request   [ Int32 state id ][ UInt8 0=read 1=write ][ value, if writing ]
response  [ Int32 state id ][ Int32 byte count     ][ value             ]
```

A String carries its length again inside the payload: `Int32 length` then that
many UTF-8 bytes, no terminator. Types are `0` bool, `1` Int32, `2` float,
`3` double, `4` string, `5` Int64, and `-1` for a command, which takes no value
and is invoked with a read frame.

The device announces itself as JSON over UDP broadcast on port **15000** while
Connect is enabled; the payload's addresses array carries the IPs. Its keys are
read case-insensitively — the v2 documentation spells them `addresses`,
`deviceName`, `version`, while older payload dumps use `Addresses`,
`DeviceName`, and a client that hard-codes either one reports "not found"
against the other.

### Two rules that are not obvious and are not optional

**Requests go one at a time.** A response carries the state id it answers and
nothing else — no sequence number. That distinguishes a latitude from an
altitude and *not* one read of latitude from the next, so two outstanding reads
of the same state cannot be told apart. Pipelining would be faster and would
occasionally file one state's value under another's name.

**A lost answer kills the connection.** Answers are matched to questions purely
by order, so abandoning a request whose reply is still in flight leaves every
later reply off by one — permanently, and silently. There is no resynchronising
a stream with no message boundaries. `ConnectTransport` therefore treats a read
timeout as fatal and reconnects.

## The manifest is the API

There are no constant state IDs. Send state `-1` and Infinite Flight returns its
whole catalogue as `id,type,path` records, one per line.

**It differs per aircraft and is not stable across releases.** An airliner
publishes slats and engine states a Cessna has no concept of. Nothing in the app
names a numeric id: every read resolves a path against the manifest fetched on
*this* connection, and `ConnectField` gives each logical reading a list of
candidate spellings so a rename costs a missing feature rather than a wrong
number.

Writability is not published at all — the manifest gives type and never
direction — so any future write is best-effort and worth reading back.

## What gets broadcast, and what survives

`LiveStatusPublisher` writes one row to `pilot_live_status`, upserted on the
account, every 45 seconds in the cruise and every 15 when something is
happening. It carries everything the poll loop reads and not a read more —
position, configuration, lights, the wind at the aircraft, **fuel on board**,
N1, thrust, squawk, true airspeed, pitch and bank, the stall and overspeed
warnings, and the sim's own elapsed clock.

Fuel is the one people ask for, and it is also the one that needs help. The app
cannot compute a burn rate: iOS suspends it behind Infinite Flight for most of
a flight, so it sees its own samples in bursts with hours missing. The server
sees the whole sequence, so `fuel_burn_kgh` is derived by a trigger from
consecutive readings — smoothed, ignoring gaps under a minute and over fifteen,
and reset outright by a refuel or an aircraft change. `enduranceLabel` is that
rate extrapolated flat, which is honest about being an estimate and is withheld
when it would read as days.

### Three ways to stop, and they mean different things

| | What happens | What is left |
|---|---|---|
| **Sim detaches** — app closed, phone asleep | `pilot_live_stand_down()` | The flight: aircraft, route, phase, fuel, elapsed. No position from the sim. |
| **Nothing said at all** — battery flat mid-ocean | `housekeeping()` does it on a timer | The same, within four minutes |
| **Share switch off** | `pilot_live_clear()` | Nothing. The row is deleted. |

The distinction is the whole design. A position is true for four minutes and is
nulled *in the table* the moment it stops being — by the stand-down, or by
housekeeping if nobody got the chance — so the database never accumulates a
track. What outlives it is "they were at 3.2 tonnes an hour ago", which is a
fact about an aeroplane rather than a location, and it expires by itself after
a day. Turning broadcasting off is unchanged and still means *forget it*.

### The position the server can see, and the one it cannot

The first two rows of that table used to mean the pilot disappeared off
everybody else's map about four minutes into the flight — at exactly the point
it got interesting — because the only thing that could see them had been
suspended behind Infinite Flight.

It no longer does. `flight_id` is the same id the public feed uses, and the feed
is a cloud service the backend is already holding in memory for every server on
every poll. So `live_hydrate.cjs` matches the two, and refreshes the position of
any broadcasting pilot whose sim has gone quiet from the feed instead.

What it will not do is the point of it:

* **It never creates a row.** Hydration finds rows. The share switch is still
  the only thing that makes one, and turning it off still deletes.
* **It never outbids a sim that is talking.** The gate is in the database, not
  in the backend: `pilot_live_hydrate` only touches rows whose `sim_live_at` is
  already past the TTL. A pilot on an iPad in Split View is never hydrated at
  all.
* **It never invents what the feed cannot see.** Fuel, gear, flaps, lights, N1,
  the wind at the aircraft and the ATC transcript stay exactly as the sim last
  reported them. What they gain is a clock — `sim_live_at` — so a reader can say
  "3.2 t · 14 min ago" rather than implying it is now.

`position_source` says which of the two wrote the position currently on the row,
and every read function returns it. The privacy question is the same one as
before and has the same answer: nothing accumulates, because it is the same
upserted row, and housekeeping still strips the position four minutes after the
last sample of *either* kind — so a flight the feed has dropped ends on exactly
the clock it always did.

### And the notice, which only the server can send

A Connect link that drops mid-flight drops precisely when the app is too deeply
suspended to notice, retry, or announce a retry. `ConnectSession` posts a local
notice when a connection the pilot was kept waiting for finally comes up, and
one when a window ends without it coming up. Those now reach somebody — they
fire from the background window, over the top of the sim — but they can only
speak for the thirty seconds the app is awake for. A link that dies four hours
into a flight is still past anything the device can observe.

So the server says it instead. `pilot_connect_alerts_due` returns the pilots
whose flight is on the feed right now and whose sim has been quiet for twice the
TTL, and marks each flight as told **in the same statement** — dedupe that
survives a redeploy, because being told twice on one flight is worse than not
being told at all. Two conditions make it specific rather than nagging: the
`flight_id` has to match, which only the app can have written, and `sim_live_at`
has to be set, which means Connect worked on this flight and has since stopped.
Somebody who has never used Connect has no row and cannot be reached by it.

It arrives as a `passive` push, because interrupting a hand-flown approach to
report that the telemetry went quiet would be worse than the problem. Pilots who
would rather not hear it at all set `pilot_profiles.connect_alerts` to false.

Reaching the pilot at all needed one new piece of plumbing. Every other push in
the app is about somebody you are *watching* and is addressed by the APNs token
that registered the watch; this one is about your own flight and is addressed by
the account your live status is keyed on. `PushService.syncAccountRegistration`
posts the token to `/api/push/devices` with the account's own bearer token, which
is the only thing that joins the two — and sign-out deletes it, so the next
person to sign in on the phone does not inherit the last one's flight notices.

Liveness is therefore not a timestamp test. A row is live when it last arrived
carrying a position **and** that position is fresh; nulling the position is what
ends a flight, so the position is what the test reads. `updated_at` moves on any
write including a stand-down, so `last_live_at` is the clock everything else
uses — and it is stamped by a trigger from the server's own `now()`, never by
the client, which was previously able to claim any time it liked.

### Who can see it

`live_visibility` on the profile, and it has always had three settings. Two of
them now have a query:

* `pilot_live_status_for(handle)` — one pilot, applying their visibility.
* `pilot_live_following(limit)` — everybody you follow who is flying **now**.
  Live-only on purpose: a "who is in the air" list filled with people who landed
  yesterday is a different, worse thing.
* `pilot_live_public(limit)` — everybody who set `public`, readable signed-out.
  This is what "broadcast to everyone" means, and it is opt-in twice over: the
  default is still followers, and a pilot has to choose `public` deliberately.
* `pilot_live_flight(flight_id)` — one flight, found by the id the public feed
  uses. For the web tracker, below.

The fourth one exists because every other reader comes at this table from the
pilot and the map comes at it from the other end: it has an aeroplane drawn, it
holds a flight id, and it has no handle to ask about. It is not a second
visibility policy — it calls the same `pilot_live_readable` the others do, so
asking by flight id reveals exactly what asking by handle would and a
followers-only pilot stays followers-only.

### Testing it

`supabase/tests/run.sh` applies every migration to a throwaway Postgres and runs
`supabase/tests/live_status.sql`, which asserts the parts that are about time
and absence and are invisible in a diff: that a burn rate of 6,000 kg/h comes
out of 500 kg in five minutes, that a refuel does not read as a negative burn,
that a stood-down row keeps its fuel and loses its position, that a phone that
went flat is treated the same way without being asked, and that the share switch
still leaves nothing behind.

Its third block is the by-flight-id reader, and asserts the thing that reader
could quietly get wrong: that it is as revealing as asking by handle and no
more — a stranger holding the id of a followers-only flight gets nothing, a
follower gets the row, the pilot always gets her own — that an empty or null id
is not a wildcard over every row whose `flight_id` was never written, and that
a quiet flight still answers with its fuel and configuration while withholding
the position it no longer has.

Its second block is hydration, and asserts the parts of *that* which are about
time and absence too: that a sim which is still talking is never overwritten,
that a suspended app's pilot comes back onto her follower's list and the public
one, that the fuel and the burn rate survive a hydrate rather than being dragged
to zero by a server reporting the same figure back to itself, that the sim clock
does not move when the feed writes, that the drop notice fires once and only
once and never for somebody who opted out, and that the sim takes the position
straight back when it returns. The clamping that keeps one strange feed reading
from aborting the whole batch is asserted on the other side, in the backend's
`live_hydrate.test.cjs`.

## How it fits together

```
ConnectSession  (@MainActor, the state machine and the poll loop)
  └── ConnectTransport  (actor: the socket, framing, one request at a time)
        └── ConnectProtocol   (encode/decode, ConnectFrameReader)
  └── ConnectManifest   (catalogue + ConnectField path resolution)
  └── ConnectTelemetry  (the snapshot, and ConnectLanding)
```

A session runs `discover (or take the address) → connect → manifest → resolve →
poll`. The fast loop reads position four times a second; the landing group is
read every fifth pass, and session identity every twentieth.

`LogbookRecorder` is the only consumer so far. When a flight closes and Connect
is attached *to that same flight id*, the row waits up to 15 seconds for the
touchdown to arrive before being written, and is marked `source = 'connect'`
only when a measurement actually landed on it.

### When the catch-up runs

On every start of the session, before the poll loop takes the socket — not on
`willEnterForeground`, which is where it used to live and which does not fire
for an object that does not exist yet. `ConnectSession.shared` is first touched
by `ContentView.onAppear`, by which time a cold launch's foreground
notification has been and gone; and a cold launch is not the edge case here but
the ordinary one, because iOS jettisons a backgrounded app over a
fourteen-hour flight to give Infinite Flight the memory. So the single path
that mattered most — land, come back, open the app — was the one path that
never caught up, and the pilot saw nothing happen.

### A remembered address is not a permanent one

`resolveHost` tries the remembered address first, because it is usually right,
costs nothing, and is the only thing that works where discovery is refused.
After three failed attempts it goes back out and listens for the broadcast
again, keeping the old address if nothing announces itself.

That is not a tuning decision, it is the difference between recovering and not.
The address is a DHCP lease: the device running the sim reboots, rejoins the
Wi-Fi, or is a different device today, and the number moves. Discovery only
ever ran when `host` was empty, so nothing ever went to look again — the
session dialled an address nobody was answering on, once a minute, for the
length of a flight, while the panel sat on "Waiting for Infinite Flight". The
panel's own way out was to type the new address, which is the thing the pilot
came there not knowing; it now also offers **Search the network again**, which
forgets the address and restarts.

### The stale-landing trap

The sim holds the last landing until the next one. The first read after
attaching therefore returns whatever the pilot did before the app was even
looking — possibly days ago, possibly a flight already in the logbook. Without a
baseline, the first thing this feature would do on every single connection is
record a landing that did not happen. `ConnectSession.landingBaseline` adopts
whatever is already there, silently, and only a *change* from it counts.

## On the web tracker

The site draws the same aeroplanes from the same feed, so it can join to this
the same way the app does — `pilot_live_flight(flight_id)` on the flight it has
open, with the anon key it already holds, signed in or not. What it adds to the
flight window is the half the feed cannot produce: fuel and the burn rate, gear
and flaps, the lights, N1 and thrust, the wind at the aircraft, and the sim's
own clock.

Two rules, and they are the same two the app's own readouts follow. **The block
is absent, not empty, when nobody is broadcasting** — a permanent "waiting for
aircraft data" on a flight that will never have any is worse than no block at
all, and it is what the site did before this existed. And **nothing is dated
now unless it is now**: a hydrated flight shows the sim's figures against
`sim_live_at` ("3.2 t · 14 min ago"), because the position came from the feed
and the fuel did not.

## Sharing it with other pilots

`pilot_live_status` is one row per pilot currently flying with Connect attached,
written by the app and never by the server — because the server cannot see any
of this. It carries position, phase, configuration, lights and the sim's own
weather at the aircraft.

Three things have to be true before a byte of it leaves the device: an account,
a claimed handle, and the sharing switch. Turning the switch off **deletes** the
row rather than hiding it, so there is nothing left to leak later.

Who may then read it is a fourth, separate decision — `pilot_profiles.
live_visibility` — and it defaults to **followers**, out of step with
`friends_visibility` and `logbook_visibility`, which default to public. That is
deliberate: the friends list says who you know and the logbook says where you
have been, and this says where you *are*. Real-time position attached to a named
person is a different category, and the default should not have to be found.

Rows go stale after `live_status_ttl()` (four minutes). The read functions ignore
anything older, so a phone that goes in a pocket over the Atlantic stops being
"flying now" rather than being shown at a position it left an hour ago.

Two read paths, both `security definer`, both re-deriving visibility rather than
leaning on RLS:

* `pilot_live_status_for(handle)` — one pilot, everything, for their profile.
* `pilot_live_following(limit)` — everybody you follow who is in the air, in the
  narrower `PilotLiveSummary` shape, for the friends panel. A follow alone is not
  enough: `live_visibility = 'private'` means private even to a follower.

The write cadence is 45 seconds in the cruise and 15 in the phases where somebody
watching actually cares — approach, takeoff, taxi. A row every few seconds for
fourteen hours to say "still cruising" is a lot of nothing.

## ATC on frequency

Infinite Flight can stream the ATC messages this aircraft sends and receives —
the sim's own log, not a global feed, and already public in the game because
everybody on the frequency heard it.

**These paths are not in any manifest dump we have.** They are named from the
developer reference (`api/stream/enable_atc_messages`,
`upstream/atc/message_received`) rather than observed, so each carries several
candidate spellings and the feature simply does not appear if none resolves. The
probe prints everything in the live manifest matching `atc|stream|upstream|
message`, which is what settles it.

It is genuinely **pushed**, not polled: once enabled, the sim sends a frame
every time something is said, without being asked. That broke an assumption —
`ConnectTransport` originally handed every arriving frame to the next waiter in
the queue, which would have given an ATC transcript to a read expecting an
altitude and then been permanently one answer behind. Waiters now record the
state id they asked about, and a frame that does not match goes to an
unsolicited sink instead. That fix is worth having regardless of whether ATC
turns out to be available.

## Storage: what grows and what cannot

The concern is real and worth being precise about, because the answer differs
per table.

**`pilot_live_status` cannot grow.** It is keyed on the account and written by
upsert, so it is bounded by the number of people who have ever flown with
Connect attached — not by how long or how often they fly. There is no row-count
problem to solve.

There were two real problems, and neither was row count:

* **Dead tuples.** Postgres does not overwrite a row; it writes a new version
  and leaves the old one for vacuum. A pilot on a fourteen-hour flight updating
  every 45 seconds makes ~1,100 dead versions of one row. The fix is HOT
  updates, which need free space on the page *and* no indexed column changing —
  and `pilot_live_status_fresh_idx` indexed `updated_at`, which changes on every
  single write. That index is dropped, `fillfactor` is 70, and autovacuum is
  tuned for a small hot table.
* **Stale rows.** Nothing read them, but a table of live positions that only
  accumulates is a table of *historical* positions. `housekeeping()` runs every
  ten minutes under pg_cron and removes anything past five times the TTL.

**The ATC transcript is stored in the live row and nowhere else.** The obvious
design is a messages table, and it is the one part of this feature that could
genuinely bloat a database — a row per message, per pilot, per flight is
hundreds of thousands of rows a month to serve a panel showing the last five.
Keeping them in a capped `jsonb` array inside the ephemeral row means the
transcript has exactly the lifetime of the flight, is deleted by the same sweep,
and adds no table, no index and no growth. Capped at 12 entries and 4 KB by
check constraint — enforced server-side, because "the app only ever sends
twelve" is a sentence about the version running today.

**The landing board stores nothing.** It is a query over the logbook every time
it is asked for. A stored leaderboard is a table to maintain, a backfill when
the rule changes, and a number that can be wrong.

**`pilot_logbook` grows, and should.** One row per completed flight, ~200 bytes,
already gated on three minutes airborne. That is the product, not trash.

## Known risks

**The iOS local-network entitlement.** Local network access needs
`NSLocalNetworkUsageDescription` (added) and the user's permission. Apple
additionally gates broadcast and multicast behind
`com.apple.developer.networking.multicast`, which is granted by application
rather than by request, and whether *passively receiving* a broadcast falls
under that gate is genuinely unclear. Discovery is therefore treated throughout
as a convenience: it is tried, given ten seconds, and on failure the panel asks
for the address by hand — which goes through the usage description alone and
always works. Nothing depends on discovery succeeding.

**Unverified state paths.** The position group — latitude, longitude, altitude,
heading, indicated airspeed — was not present in the third-party manifest dump
this was built against, so those spellings are educated guesses carrying
several candidates each. `tools/connect-probe` is what turns them into facts;
anything it prints as missing needs correcting in `ConnectField.candidates`.
Nothing else is affected by a wrong guess: an unresolved field is simply never
read, and the panel lists them.

**No authentication, at all.** Anyone on the same network can read the aircraft
and, with writes, fly it. That is Infinite Flight's decision rather than ours,
but it is why the socket is never relayed off the device and why the panel says
plainly what switching it on exposes.

**Backgrounding.** iOS suspends the app and the socket dies with it. With the sim
on another device the session closes deliberately on `didEnterBackground`, so the
next foreground starts from a known state rather than from a half-dead connection
whose every read times out. With the sim on *this* device it does the opposite
and holds a finite window open — see *The link is made on the way out* — because
that is the only moment the simulator is in front and answering.

This is not a bug with a fix waiting to be found, and it is worth writing down
why, because it is asked about repeatedly. The background modes that hold a TCP
socket open for fourteen hours are `audio`, `location` and `voip`; none of them
describes this app, and silent audio or an unused location subscription claimed
to keep a socket alive is a 2.5.4 rejection. `BGAppRefreshTask` gets about thirty
seconds, opportunistically, and iOS deprioritises it hardest exactly when a
flight simulator is holding the GPU and the thermal budget. What can be done
instead is above: the *server* keeps the flight on the map, the thirty-second
window catches a sample each time the pilot switches into the sim, and the two
configurations where the app genuinely stays foregrounded for the whole flight —
an iPad in Split View, or a second device on the same Wi-Fi — remain the ones
that get live Connect telemetry end to end.

## The probe

`tools/connect-probe/probe.mjs` — Node, no dependencies.

```
node probe.mjs                      # discover on the LAN
node probe.mjs 192.168.1.42         # connect directly
node probe.mjs 192.168.1.42 --watch # stay attached, print each landing
```

It dumps the manifest to `manifest.txt`, reports the namespace breakdown, reads
every path the app wants and prints in red anything that is not there, then —
with `--watch` — sits on the landing group so you can fly a circuit and see
exactly what the logbook would have recorded.

`selftest.mjs` exercises the framing and the decoders against synthetic frames,
including one frame split byte-by-byte and three arriving in a single chunk.
Run it with `node selftest.mjs`; it needs no device.
