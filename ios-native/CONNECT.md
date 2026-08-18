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
* It needs **two devices** — the sim on one, Inflight on the other. Same-device
  does not work: iOS suspends the backgrounded app and the sim is the one that
  has to stay in front.
* Every consumer must work **without** it. The logbook records flights inferred
  from the feed exactly as it always has; Connect upgrades those rows rather
  than being required for them.

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
