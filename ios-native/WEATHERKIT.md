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
| **Airport panel → WEATHER ALERTS** (`Views/WeatherForecastSection.swift`) | severe-weather alerts, with issuer and region | the attribution card at the foot of the block |
| **Airport panel → NEXT HOUR** | minute-by-minute precipitation graph and summary | the same card |
| **Airport panel → WIND ON THE RUNWAYS** | only where the field filed no METAR — otherwise the wind is the report's | the same card |
| **Airport panel → FORECAST** | 24-hour strip, and eight current readings | the same card |
| **Airport panel → TEN DAYS** | the outlook. Optional — Weather settings, "Ten days and the sky" | the same card |
| **Airport panel → SUN AND MOON** | sunrise, sunset, civil dawn and dusk, moon phase and times. Same toggle | the same card |
| **Map weather chip, collapsed** (`Views/WeatherChip.swift`) | temperature, symbol, conditions and wind for a field that files no METAR | `collapsedAttribution` — the  Weather wordmark and a link, in a capsule under the chip |
| **Map weather chip, opened** | the same, for the field being passed and both ends of the route | `WeatherAttributionRow`, last row of the card |
| **Weather settings → SAMPLE** (`Views/WeatherSettingsPanel.swift`) | the sampled field's conditions and wind, where it files no METAR | `WeatherAttributionRow`, under the sample |

Every one of those is drawn **only when Apple's data is actually on screen** — a
field with its own METAR and no forecast loaded shows no mark, because there is
nothing of Apple's to attribute.

The airport panel's sections share one attribution card because they are one
screen and one scroll: the mark and the link sit at the foot of the block they
attribute, below the last section that came from Apple.

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

That second half is the fix made for this rejection. The row previously dropped
the legal link entirely whenever the attribution fetch had not returned, so a
slow CDN or a failed request produced a row with a sentence on it and nothing to
tap. The collapsed weather chip is the other fix: it showed Apple's temperature
with the mark one tap away, inside the card, rather than on the screen the data
was on.

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
   **WIND ON THE RUNWAYS**, **FORECAST**, **TEN DAYS**, **SUN AND MOON**, and
   Apple's mark and **Legal** link on the card that closes the block. If the
   field has an alert, **WEATHER ALERTS** sits above all of it.

Put the recording in **App Review Information → Notes** in App Store Connect.
