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
- **The tap.** `didSelect` on the flat map refuses a real-world annotation, and
  `PlanetSurface` refuses the same tap on the globe. A real aeroplane has no
  pilot profile, no plan filed with our backend and no history for the replay,
  so a flight window could only be empty. The flat map shows a callout instead
  — callsign, type, registration, height, speed.
- **VA logos.** Never drawn on real traffic. The partner directory is keyed on
  callsign, and real airline callsigns collide with virtual ones by design.
- **The grace period.** Simulator traffic missing from a packet keeps its last
  position for thirty seconds, because the feed drops an aircraft and has it
  back. Real traffic gets none: switching the layer off has to empty the map on
  the same frame.

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
