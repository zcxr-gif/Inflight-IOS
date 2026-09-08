# WeatherKit, and Apple's attribution

What the app asks Apple for, where the answer is shown, and where the mark that
has to accompany it is drawn. Written because App Review asked
(Guideline 5.2.5, 2026-09): *"we need to confirm if the app follows the
WeatherKit attribution requirements."*

## What Apple requires

Two things, together, **on every screen that displays WeatherKit data**:

- the ** Weather** trademark, and
- a link to Apple's **legal attribution** page.

Neither is optional and neither substitutes for the other. Apple's own
`WeatherAttribution` hands back artwork for the first and a URL for the second;
using them is the preferred way, but they arrive over the network and the
requirement does not wait for them.

## What is asked for

`Services/AppleWeatherService.swift`, and nowhere else. **One call per field**:

```swift
let weather = try await WeatherService.shared.weather(for: location)
```

The query-less overload returns the whole `Weather` value — current conditions,
the next hour minute by minute, the hourly and daily forecasts, and the alerts —
for the price of the one request the old three-dataset call already cost. That
is what makes runway wind components, a ten-day outlook and civil twilight
affordable: none of them is a second request.

Cached for 15 minutes per field, keyed by ICAO.

| Dataset | Used for |
| --- | --- |
| `currentWeather` | conditions, feels-like, dew point and spread, humidity, pressure and its trend, visibility, cloud cover, UV, and the **wind** the runway components are worked from |
| `minuteForecast` | the NEXT HOUR graph and its one-line summary. Apple models this over a handful of countries only, so it is nil elsewhere and the section is simply absent |
| `hourlyForecast` | 24 hours: symbol, temperature, precipitation chance, wind and gust |
| `dailyForecast` | 10 days: high and low, precipitation chance, wind — and today's **sun, civil twilight and moon** events |
| `weatherAlerts` | severe-weather warnings, each with the agency that issued it and the area it covers |

The entitlement is `com.apple.developer.weatherkit` in
`Support/InflightTracker.entitlements`, and the capability has to be on the
`com.tracker.Inflight` App ID as well. Without it every request throws, which
the app treats as "no forecast" — sections that do not appear — rather than as
an error laid over a working panel.

**A METAR always wins.** Where a field files its own observation, that is what
the app reports, and the runway wind is worked from the filed wind rather than
Apple's. WeatherKit answers for the large majority of the world's airfields that
file nothing at all, and for the forecast, the outlook and the alerts, which a
METAR cannot carry.

## Wind on the runways

The one piece of arithmetic on the panel, in `Models/RunwayWind.swift`.

Runway centrelines come from `AirportLayoutStore` — the same OpenStreetMap
pavement the ground chart is drawn from, already cached for a month. The
**geometry** gives the bearing, because it is true and current; the **painted
designator** is used only to say which end of the centreline is which, which is
the one thing a line drawn on a map cannot know. Both wind sources are true
directions — the wind group in a METAR body is true north — so they are directly
comparable with it.

Each end gets its headwind (negative for a tailwind), its crosswind (signed, so
the row can say *from the left*), and the crosswind worked from the gust where
one is reported. Ends are sorted by headwind, so the favoured one leads. The
section says outright that it is a wind calculation and not a recommendation:
nothing here knows the aircraft, the surface or the length.

## Where it is shown, and what carries the mark

| Screen | WeatherKit data | Attribution |
| --- | --- | --- |
| **Airport panel → WEATHER ALERTS** (`Views/WeatherForecastSection.swift`) | severe-weather alerts, with issuer and region | ** Weather** beside the heading, and `WeatherAttributionRow` as the card's last row |
| **Airport panel → NEXT HOUR** | minute-by-minute precipitation graph and summary | the same, head and foot |
| **Airport panel → WIND ON THE RUNWAYS** | the wind, but **only** where the field filed no METAR | the same — and both halves only on that condition, decided by the one value. See below |
| **Airport panel → FORECAST** | 24-hour strip, and eight current readings | the same, head and foot |
| **Airport panel → TEN DAYS** | the outlook. Optional — Weather settings, "Ten days and the sky" | the same, head and foot |
| **Airport panel → SUN AND MOON** | sunrise, sunset, civil dawn and dusk, moon phase and times. Same toggle | the same, head and foot |
| **Map weather chip, collapsed** (`Views/WeatherChip.swift`) | temperature, symbol, conditions and wind for a field that files no METAR | `AppleWeatherSourceMark` beside the ICAO in the capsule, and `collapsedAttribution` — the  Weather wordmark and a link — in a capsule under it |
| **Map weather chip, opened** | the same, for the field being passed and both ends of the route | `AppleWeatherSourceMark` on each Apple-sourced row, and `WeatherAttributionRow` as the card's last row |
| **Weather settings → SAMPLE** (`Views/WeatherSettingsPanel.swift`) | the sampled field's conditions and wind, where it files no METAR | ** Weather** beside the heading, `AppleWeatherSourceMark` beside the ICAO, and `WeatherAttributionRow` under the sample |

Nothing else in the app touches WeatherKit. The map's airport annotations draw
their conditions line from the filed METAR only, and the widgets draw no
weather at all — so neither carries a mark, because neither has anything of
Apple's to attribute.

## One mark per card, not one per screen

The airport panel is six cards deep and scrolls past several screens' worth. A
single attribution at the foot of the block is a mark that is off screen for
most of the reading, so **every card that draws WeatherKit data ends with
`WeatherAttributionRow`** — Apple's own artwork where it has arrived, the
 Weather wordmark where it has not, and the legal link either way.

One card, one source, one mark. There is no card of Apple's data without one.

### And once at the top of it

The foot of the card is where the *link* has to be, but a card can be
twenty-four hours of forecast or ten days of outlook tall, and a reader half
way down one of those has the numbers on screen and the mark below the fold.
So the heading carries the trademark too: `PanelSection`'s `accessory` slot
draws ** Weather** opposite the title, in the title's own dim weight, on every
card the attribution row appears on and on no others.

The wordmark only. The legal link stays at the foot, once — a card with Apple's
legal page at both ends is not better attributed, only harder to read.

## The two exceptions, and why they are not oversights

**WIND ON THE RUNWAYS is Apple's only sometimes.** Where the field filed a
report, that arithmetic is the *report's* wind against OpenStreetMap's
centrelines, and Apple had no part in it — so the card carries no Apple mark.
Marking it would credit them with somebody else's observation, which is as
wrong as leaving their own unmarked. `isWindFromApple` decides, and the same
value writes the footnote, so the mark and the sentence under it cannot end up
naming different sources.

**Shared cards are marked per row.** The opened weather chip lists the field
being passed and both ends of the route, and any of the three can be a filed
report or Apple's model. A single mark at the foot of that card would attribute
all of them, so each Apple-sourced row carries `AppleWeatherSourceMark` — the
 glyph, beside the ICAO — and the card's attribution row supplies the wordmark
and the legal link. The same applies to the collapsed capsule and the weather
settings sample.

## How the mark cannot go missing

`WeatherAttributionRow` (`Views/WeatherForecastSection.swift`) draws both halves
unconditionally:

- **The mark.** Apple's own combined artwork (light or dark, to match the
  theme) where `WeatherAttribution` has arrived; `AppleWeatherWordmark` — the
  literal ** Weather** text, U+F8FF being the Apple logo on every Apple
  platform — while the image is still downloading, and for good if the fetch
  never lands. There is no state in which the row draws neither.
- **The link.** `WeatherAttribution.legalPageURL` where the framework has
  answered, and `AppleWeatherService.legalPageURL` — the same page, as a
  constant — where it has not.

That second half was one of the fixes made for this rejection. The row
previously dropped the legal link entirely whenever the attribution fetch had
not returned, so a slow CDN or a failed request produced a row with a sentence
on it and nothing to tap. The collapsed weather chip was the other: it showed
Apple's temperature with the mark one tap away, inside the card, rather than on
the screen the data was on.

`AppleWeatherService.loadAttribution()` fetches the mark once, on its own,
retried by the next caller if it fails — separately from the weather, because a
screen showing a cached forecast asks for no weather at all and used to
therefore never ask for the mark either.

## For the screen recording App Review asked for

Shortest route that shows every WeatherKit surface on a physical device:

1. Open the map. Let the weather chip settle on a field with no METAR — the
   temperature and wind appear with ** Weather** and a link under them. Tap the
   link; Apple's legal page opens.
2. Tap the chip to open it. The card lists the fields, with Apple's combined
   mark and **Legal** as its last row.
3. Open the map toolbar's weather control → **Weather settings**. Its SAMPLE
   section carries the same row.
4. Back on the map, open any airport and scroll the panel: **NEXT HOUR**,
   **FORECAST**, **TEN DAYS** and **SUN AND MOON**, each closing with Apple's
   mark and a **Legal** link. If the field has an alert, **WEATHER ALERTS**
   sits above all of it, marked the same way. **WIND ON THE RUNWAYS** carries
   the mark at a field that files no METAR, and is the report's own arithmetic
   — unmarked — at one that does; a recording that opens one of each shows
   both.

Put the recording in **App Review Information → Notes** in App Store Connect.
