# Weather: where every number on a panel comes from

Four sources, and which of them answers which question. Written because the
forecast used to be WeatherKit's and is not any more, and the reason for that
is worth keeping.

## Why WeatherKit is gone

It never worked in a shipped build.

WeatherKit needs the capability on the App ID as well as the entitlement in the
bundle. Without it the framework refuses every request **locally** — the call
never leaves the device — and from inside the app that is indistinguishable
from a service being down. The app's handling of a failure was, correctly, a
section that quietly does not appear. So the visible symptom was a set of cards
that were simply never there, on every field anybody opened, and nothing
anywhere said why.

The giveaway was Apple's own dashboard: **zero calls**, for a feature that was
supposedly running on every airport panel in the app.

That is not a bug that gets fixed by ticking the capability. It is a dependency
that fails silently, needs a portal, needs a provisioning profile rebuilt
whenever it changes, and drags a two-part trademark-and-legal-link obligation
onto every screen that shows so much as a temperature — which is its own class
of App Review rejection. The replacement has none of those properties.

## What answers what now

| Question | Source | Where |
| --- | --- | --- |
| What is it doing at this field *right now* | the field's own **METAR**, from VATSIM | `Services/WeatherService.swift` |
| …and at the four fields in five that file none | **Open-Meteo** current conditions | `Services/ForecastService.swift` |
| What is it about to do — two hours, a day, ten days | **Open-Meteo** forecast | the same call |
| Sunrise, sunset, civil twilight, the moon | **arithmetic**, on the device | `Models/SkyAlmanac.swift` |
| Severe-weather warnings | the **National Weather Service** | `ForecastService.alerts(near:)` |
| Radar and cloud under the traffic | **RainViewer**, **NASA GIBS** | `Map/RainViewerTileOverlay.swift` |
| Winds aloft, and the fields drawn from them | **Open-Meteo** pressure levels | `Services/WindsAloftStore.swift` |

**A METAR always wins.** Where a field files its own observation, that is what
the app reports, and the runway wind is worked from the filed wind rather than
the model's.

## The forecast request

One call per field, cached fifteen minutes, keyed by ICAO — the same shape the
old one had:

```
https://api.open-meteo.com/v1/forecast
  ?latitude=…&longitude=…
  &current=…&hourly=…&minutely_15=precipitation&daily=…
  &wind_speed_unit=kn&timeformat=unixtime&timezone=auto
  &past_hours=6&forecast_days=10
```

No key and no account. Open-Meteo answers for as many variables as the URL
names, which is what makes the current conditions, the near-term precipitation,
twenty-four hours of forecast and ten days of outlook one request between them
rather than four.

`timezone=auto` is what makes "Today" mean the day it is *at the field*, and
the offset it answers with is the zone the hour strip, the outlook and the sun
and moon times are all written in.

### Two things the model does not hand over finished

A meteorological service gives you numbers, not a rendered product. WeatherKit
gave a `condition` and a `symbolName`; losing those was the only real cost of
leaving, and both are made up here:

- **`Models/WeatherCode.swift`** turns the WMO present-weather code into a
  label and an SF Symbol. It is the international table the observations
  themselves are written in, and it is the same table for every provider — so a
  field's filed report and the model's answer for the field next to it now draw
  the same weather the same way.
- **`Models/SkyAlmanac.swift`** works out sunrise, sunset, civil dawn and dusk,
  and the moon's phase and times. None of that was ever weather; it was in
  WeatherKit's daily record only because that is where Apple happened to put
  it. The sun is NOAA's approximation, already in `SolarPosition`; the moon is
  the standard low-precision series, which puts a rise time within a couple of
  minutes. Being arithmetic, it also answers over an ocean with no signal.

## Warnings, and where they stop

`api.weather.gov/alerts/active` — open, no key, no quota, and **the United
States only**. No other agency covering a large area publishes anything
comparable for free.

So the WEATHER ALERTS card appears over Kansas and not over Bavaria. That is a
smaller thing to explain than a card that never appears at all, and where a
second agency opens up it is one function that changes. A failure here is an
empty list: a warnings service that is down must not take the forecast down
with it.

## Wind on the runways

The one piece of arithmetic on the panel, in `Models/RunwayWind.swift`, and
unchanged by any of the above.

Runway centrelines come from `AirportLayoutStore` — the same OpenStreetMap
pavement the ground chart is drawn from, already cached for a month. The
**geometry** gives the bearing, because it is true and current; the **painted
designator** is used only to say which end of the centreline is which. Both
wind sources are true directions — the wind group in a METAR body is true north
— so they are directly comparable.

Each end gets its headwind (negative for a tailwind), its crosswind (signed, so
the row can say *from the left*), and the crosswind worked from the gust where
one is reported. Ends are sorted by headwind, so the favoured one leads. The
section says outright that it is a wind calculation and not a recommendation:
nothing here knows the aircraft, the surface or the length.

## Attribution

Open-Meteo publishes under **CC-BY 4.0**. What is owed is a named credit and a
way through to them, and `ForecastSourceRow` (`Views/WeatherForecastSection.swift`)
is that — one line, drawn on every card that carries their numbers:

| Screen | Credit |
| --- | --- |
| Airport panel → NEXT TWO HOURS, FORECAST, TEN DAYS | `ForecastSourceRow` as the card's last row |
| Airport panel → WIND ON THE RUNWAYS | the same, but **only** where the field filed no METAR — crediting the model for somebody else's observation is as wrong as leaving its own uncredited |
| Airport panel → SUN AND MOON | none. It is the device's own arithmetic |
| Airport panel → WEATHER ALERTS | none from Open-Meteo; each row names the issuing agency |
| Map weather chip, opened | `ForecastSourceRow` as the card's last row, and `ForecastSourceMark` on each modelled row |
| Weather settings → SAMPLE | the same |

`ForecastSourceMark` — the scatter glyph — is a different job from the credit:
on a card that mixes a filed report with the model's answer for the field next
to it, it says row by row which is which. A forecast and an observation are
different claims about the same field, and that belongs next to the field
rather than in a footnote.

## When there is no forecast

The sections do not appear. That is right on screen and unreadable from outside
it, so the reason is kept: `ForecastService.lastFailure` holds whatever the
last request returned, cleared by the first one that succeeds, and **Weather
settings → SAMPLE** prints it under the sample.
