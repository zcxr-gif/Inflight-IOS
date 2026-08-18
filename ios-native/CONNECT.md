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
  aircraft, in far more detail, and only sometimes.
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
| **One iPhone**, or iPad full screen | `127.0.0.1` | **None** | The landing, read when you come back |

Two things make the one-device case work.

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
Connect is enabled; the payload's `Addresses` array carries the IPs.

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

### The stale-landing trap

The sim holds the last landing until the next one. The first read after
attaching therefore returns whatever the pilot did before the app was even
looking — possibly days ago, possibly a flight already in the logbook. Without a
baseline, the first thing this feature would do on every single connection is
record a landing that did not happen. `ConnectSession.landingBaseline` adopts
whatever is already there, silently, and only a *change* from it counts.

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

**Backgrounding.** iOS suspends the app and the socket dies with it. The session
closes deliberately on `didEnterBackground` so the next foreground starts from a
known state rather than from a half-dead connection whose every read times out.

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
