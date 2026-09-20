# Real-world traffic

Off on every install. Settings › Real-world traffic, or Settings › Feed › The
real sky, turns it on.

What it does is draw actual aeroplanes — from ADS-B, the position reports real
aircraft broadcast continuously — alongside the traffic on the Infinite Flight
server, on the flat map and on the drawn planet alike.

## The shape of it

| Piece | File |
| --- | --- |
| The switch, the sweep clock, the network | `InflightTracker/Services/RealWorldTraffic.swift` |
| One ADS-B contact as a `Flight` | `InflightTracker/Models/Flight.swift` — `init?(adsb:)` and `Flight.Origin` |
| The colour, in one place | `InflightTracker/Map/RealWorldMark.swift` |
| The bar over the map, and its folded pill | `InflightTracker/Views/RealWorldTrafficBanner.swift` |
| The screen behind the switch | `InflightTracker/Views/SettingsSubpanels.swift` — `RealWorldTrafficSettingsPanel` |
| Endpoint and the numbers | `InflightTracker/App/AppConfig.swift` |

## Why real aircraft are `Flight`s

Because everything that puts an aeroplane on either map is written against
`Flight`: the sprite cache, the culling, the dead reckoning between updates,
the callsign plates, the planet's own projection. A second aircraft type would
have meant a second copy of all of that, free to drift from the first.

`Flight.origin` is what keeps the two apart, and the list of places they
actually differ is short:

- **Colour.** `Flight.originTint` paints real traffic mint; the flat map and
  the planet both read it behind the pilot highlighting.
- **The window.** Tapping one opens the same flight window the server's traffic
  does, with a **REAL LIFE** badge above the identity block. What is inside is
  thinner and honestly so: `FlightDetailView` skips the pilot card, the sim
  status, the filed plan and the VA lookup for `origin == .realWorld`, because
  every one of those is a round trip against our own backend keyed on a flight
  id it has never heard of.
- **Which clock the window keeps.** Everything live in it — the telemetry, the
  peek, the flown profile, the instruments — is read off the sweep rather than
  off a packet. Views handed a flight *id* rather than a `Flight` pick their
  source with `Flight.isRealWorld(id:)`: the id's `adsb:` namespace is the only
  thing they have to go on. The instruments were the panel that missed this and
  drew NO DATA over every real aeroplane for it, because `InstrumentSource` was
  fed `feed.flights` and nothing else.
- **The photograph.** One picture of that exact airframe, by Mode S address,
  from Planespotters. See below — their terms shape the whole of it.
- **VA logos.** Never drawn on real traffic. The partner directory is keyed on
  callsign, and real airline callsigns collide with virtual ones by design.
- **The grace period.** Simulator traffic missing from a packet keeps its last
  position for thirty seconds, because the feed drops an aircraft and has it
  back. Real traffic gets none: switching the layer off has to empty the map on
  the same frame.
- **The smoothing.** Real traffic is carried between reports whatever
  Settings › Appearance › Fly the traffic says. See below — it is the one
  difference that is not a matter of taste.

## The bar, and why it folds

The layer announces itself over the map for as long as it is on, and there is
no way to send that away short of turning the layer off. What there *is* now is
a size: the bar says its piece — the title, the count, the way out — and then
folds to the glyph and the number, which is the smallest thing that still makes
the statement. A tap opens it again, and another folds it.

It never folds while there is something to read. `waiting`, `tooFarOut` and
`failed` all hold it open until they resolve; only `live` collapses, and the
dwell is keyed on what the status is *saying* rather than on the status itself
— `live` carries a count, the count moves on every sweep, and a bar that
reopened each time one aeroplane left the area would be worse than one that
never closed.

## What it never touches

The layer is appended to what the maps draw and to nothing else. It does not
reach `LiveFeed`, the logbook, the home-screen widgets, Live Activities, the
watchlist, the friends list, map search, the airport panels, or any count
anywhere in the app. `feed.flights` still means "the server's traffic", which
is what every one of those is about.

It is also exempt from the map filters, deliberately. Those ask questions about
Infinite Flight — which phases, which altitude bands, which types, whether a
route has been filed — and "only aircraft with a destination filed" would
silently empty the layer, because an ADS-B receiver hears a position and never a
flight plan. Its own switch is the whole of what decides whether it is drawn.

## Being obvious about being on

This is the part that mattered most in the design, and it has three
independent answers so that no single one of them has to be noticed:

1. **A bar over the map**, up for as long as the layer is, on both shapes of
   the world, saying how many real aircraft are in range. It cannot be
   dismissed; the OFF button on it is the way out, and it is one tap.
2. **Mint aeroplanes.** Real traffic is drawn in a colour nothing else on the
   map uses — ordinary traffic is near-white, the open aircraft and your own
   are amber, the watchlist is amethyst, a staffed field is blue.
3. **The settings hub row** reads `On — real aircraft are on your map`, with
   its glyph in the layer's own colour, so the screen somebody opens to find
   out what they have left switched on answers without being opened.

The switch itself is persisted like every other preference. A setting that
silently resets itself is a setting nobody can rely on; what answers "did I
leave this on" is showing it, not forgetting it.

## Why it always flies

The simulator pushes positions every few seconds. ADS-B is *swept* every
fifteen. Drawn straight from the data, a real aeroplane therefore does not jump
a little often — it stands perfectly still for fifteen seconds and then
teleports about two miles. That is not the raw truth with the smoothing taken
off; it is an artefact of the polling interval, and there is no setting under
which it is the better picture. So `Flight.requiresSmoothing` is true for
real-world traffic and three things follow from it:

- **The preference does not gate it.** The flat map's frame clock and
  `GlobeScene.rebuild` both carry it regardless of `smoothsTraffic`.
  `isWorthSmoothing` still applies — an aeroplane on the ground is drawn where
  it was reported, exactly as the simulator's is.
- **The prediction's lead clears the sweep.** `FlightMotion` allows 12 s of
  dead reckoning for the simulator and **20 s** for real traffic. A lead
  shorter than the gap between reports is the one setting that guarantees the
  artefact: the prediction runs out, the aeroplane coasts to a halt, and the
  sweep lands and it jumps — once per cycle, on every real aeroplane at once.
- **The zoom floors move with it.** Both maps stop carrying traffic once the
  movement would be too small to see, and what that really measures is the size
  of the *jump* — speed times the gap between reports. Real traffic's gap is
  several times longer, so the jump stays visible several times further out:
  the flat map's floor drops from 0.2 to 0.05 points a second, and the planet's
  ceiling rises from 1,000 to 4,000 metres a point.

This also means real traffic keeps flying under Reduce Motion, which switches
the simulator's smoothing off. The alternative there is not stillness — it is a
two-mile teleport every fifteen seconds, which is the larger motion event of
the two.

## The photographs

`PlanespottersPhotos` looks up one photo per airframe from
[Planespotters'](https://www.planespotters.net) free public API, by the hex code
the sweep already carries, falling back to the registration. Their terms of use
are conditions rather than suggestions, so each one is kept somewhere specific:

### Why the pictures are drawn big, and soft

`thumbnail_large` is 280 pixels tall and around 420 wide, and their terms allow
no other size — the two thumbnails are what the API returns and URLs may not be
rewritten to ask for more. Stretched across a 390-point sheet on a 3× phone,
that is a 1170-pixel draw from a 420-pixel source, and it is exactly as soft as
that arithmetic predicts.

There was an attempt to fix that by refusing to enlarge a photograph past 1.5×
its own pixels and drawing it at a size it could hold, on the blurred backdrop
already behind fitted shots. The arithmetic was right and the picture was wrong:
what it produced was a small aeroplane floating in the middle of a smudge, on
the one window whose whole job is to show you the aeroplane. A layout fault
reads worse than a soft photograph, and every other tracker draws the same file
at full width.

So `AircraftPhotoImage` draws the photograph at whatever size the frame asks
for. What it still will not do is *crop* one to fit a box it is the wrong shape
for: past `cropTolerance` (a quarter of one dimension) the whole airframe is
fitted onto the blurred copy of itself instead, which is what that backdrop was
always for. Inside the tolerance — which is nearly always, because the header's
height is worked out from the photograph's own ratio — the picture fills the
frame edge to edge with nothing behind it.

| Term | Where it is kept |
| --- | --- |
| Never a paid, premium or member-only feature | Nothing in the photo path consults `Entitlements`, and nothing should be added that does |
| Photographer credited in visible text beside the image | `PlanespottersCredit`, overlaid on every header that draws the picture — the peak and the open window both |
| Image leads back to its page, in one discoverable action | The same pill is a `Button` opening the API's `link`; the picture itself carries the tap too (`RealPhotoAttribution`) |
| Descriptive User-Agent with a contact address | `AppConfig.publicAPIUserAgent` — an iOS app is a non-browser client by their rules |
| JSON cached at most 24 h | `AppConfig.aircraftPhotoLifetime`, six hours, in memory |
| Images fetched straight from the returned URL, not written to storage, not kept after display | `PlanespottersImageLoader` and an `.ephemeral` session with `urlCache = nil`. Deliberately **not** `RemoteImageLoader`, which keeps sixty decoded images in a static cache and runs through `URLSession.shared` and its disk cache |
| URLs used unchanged | The `link` and image URLs are carried whole and never rebuilt |
| Not used to train models; not re-exposed | Nothing here does either |

A response without a photographer or a link is treated as *no photograph* rather
than as a photograph with a gap in it: a picture this app cannot credit or lead
back to is one it has no right to draw.

## Flown paths

There is one, and it starts when you do.

`RealWorldTraffic` records every sweep into `FlightTrailStore` exactly as the
socket records every packet, so a real aeroplane has a track on the map, a
profile in its window and something for the replay to scrub through. What it
does **not** have is the part before you were watching: the simulator's traffic
gets that from our own backend's history endpoint, and there is no equivalent
for an ADS-B contact.

The sampling threshold needed its own value. `initialSpacingNM` is two miles,
which is a few seconds at cruise and therefore keeps nearly every packet — but
on a fifteen-second sweep a jet covers 1.9 miles and fell *just* under it, so
the path kept roughly every other sweep. Slower aircraft were far worse: a light
aircraft at 120 knots recorded a point a minute, and a helicopter hovering
recorded nothing and drew no path at all. Swept traffic uses `sweptSpacingNM`,
four tenths of a mile, which is under one sweep for anything moving.
`maximumPoints` still bounds it — past 260 points a trail halves its own
resolution — so a long flight costs no more than a short one.

### Getting the part before you were watching

Not from the public API: it answers with one current position per aircraft and
no history at all. Two routes exist and neither is free:

- **adsb.lol's historical dumps** (`globe_history_20xx` on GitHub) are a daily
  per-aircraft archive. Openly licensed and excellent for research, useless
  here — it is yesterday's data, published as whole-day gzip files.
- **The traces behind their own globe UI**, written by readsb's
  `--write-globe-history`. That is an internal endpoint for their web front end
  rather than part of the documented API, and building on it would mean relying
  on a URL nobody has promised to keep.

Their terms end with *"For advanced use, please contact us with details about
your project and working implementation of our public API"* — which is the
sanctioned route if a real history is ever wanted here.

## The feed

```
GET https://api.adsb.lol/v2/lat/<lat>/lon/<lon>/dist/<nm>
->  { ac: [ { hex, flight, r, t, lat, lon, alt_baro, gs, track, baro_rate, ... } ] }
```

[adsb.lol](https://adsb.lol) is a community network of volunteer receivers that
publishes what they pick up under the ODbL, with an open API that takes no key
and no account — which is why it is the one here. Inflight has no affiliation
with them. `aircraft` is read as an alias for `ac`, because the readsb-shaped
endpoints differ on which name they use.

- One sweep every **15 s** while the layer is on, around the middle of the map,
  at the endpoint's maximum **250 NM**.
- Nothing is drawn past a span of about **14°** of latitude — one sweep at
  continent scale is a blot in the middle of an empty map, which looks like the
  world's traffic and is a fraction of one country's. The bar says so.
- A sweep that fails leaves what is drawn alone until it is **90 s** old, then
  empties the layer and says why. One dropped request on a train is not a
  reason to clear the map.
- Both maps report where they are pointed — the flat map when it settles, the
  planet from its own camera — and `RealWorldTraffic.report` defers the work a
  runloop turn, because one of its callers is `updateUIView`.

## Routes

ADS-B carries no origin and no destination. There is no field for either in the
protocol, so no receiver heard one and no feed — free or paid — can hand one
over. Every tracker that shows a route is joining the **callsign** to a separate
database afterwards, and so is this.

```
POST https://api.adsb.lol/api/0/routeset
     { planes: [ { callsign, lat, lng } ] }
->   [ { callsign, airport_codes: "KJFK-KSAN", plausible: 1, ... } ]
```

The same network as the positions, chosen for that reason: the free callsign
databases (adsbdb, hexdb.io, adsb.lol) all trace back to the same VRS standing
data anyway, so reading routes here means one source to credit instead of two.

### Why most of the answer is thrown away

The standing data is callsign-to-airport-pair with **no date and no operational
status**, and flight numbers are reused — they churn seasonally and regional
operators share them. Measured against filed flight plans it is right about four
times in five outside the United States and about **one time in four inside
it**, and that split is by region rather than by record age: Australian routes
verify at 100% on rows with a median age of 11.5 years.

So `RealWorldRoutes` takes a route only when the answer also says it is
`plausible` — adsb.lol's own check that the aircraft is where that route would
put it. It discards a good deal of what comes back. What survives is worth
drawing, and the window never calls it a filed plan, because it is not one.

The route is written onto `Flight.departureIcao` / `arrivalIcao` rather than
kept in a store beside it — which is the whole reason those two are `var`. It
means the route card, the board, the widget peek's route line and
`FlightProgress` (distance to run, time to get there) all work with no changes:
they go on reading one field instead of learning about a second kind of
aircraft.

Bookkeeping: one request in flight at a time, at most 60 callsigns per batch, a
two-hour cache, and **a miss is cached as firmly as a hit** — a light aircraft
with no schedule behind it must not be asked about every fifteen seconds for as
long as it is in range. Aircraft flying under a registration are never asked
about at all.

## Attribution

The ODbL requires it, so it is drawn rather than left to a settings screen.
`RealWorldAttribution` sits at the very foot of the open flight window, in the
smallest type the app uses, crediting the network and opening
[adsb.lol](https://adsb.lol) — a credit nobody can follow is not really a
credit.

**Only on real traffic.** The simulator's aircraft come off Infinite Flight's
own feed and owe adsb.lol nothing; a line crediting a network that had no part
in what is on screen would be a false statement about where the data came from.
It also names the route as an *estimate* separately from the position, because
one is what a receiver heard and the other is a callsign matched against a
database.

## What it is not

Not a certified traffic source, and never presented as one. Coverage is
wherever volunteers happen to have receivers: excellent over Europe and North
America, patchy over oceans, deserts and much of the southern hemisphere, and
military and other traffic that does not broadcast is simply absent. Nothing
here is fit for any operational purpose. The settings screen says exactly that,
in those words, before the switch is reached.
