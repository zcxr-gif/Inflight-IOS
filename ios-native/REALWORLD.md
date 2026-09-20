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
| The bar over the map | `InflightTracker/Views/RealWorldTrafficBanner.swift` |
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

## What it is not

Not a certified traffic source, and never presented as one. Coverage is
wherever volunteers happen to have receivers: excellent over Europe and North
America, patchy over oceans, deserts and much of the southern hemisphere, and
military and other traffic that does not broadcast is simply absent. Nothing
here is fit for any operational purpose. The settings screen says exactly that,
in those words, before the switch is reached.
