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

## Where the data comes from

`Services/AppleWeatherService.swift`, and nowhere else. One
`WeatherKit.WeatherService.shared.weather(for:including:)` call per field, for
`.current`, `.hourly` and `.alerts`, cached for 15 minutes.

The entitlement is `com.apple.developer.weatherkit` in
`Support/InflightTracker.entitlements`, and the capability has to be on the
`com.tracker.Inflight` App ID as well. Without it every request throws, which
the app treats as "no forecast" — a section that does not appear — rather than
as an error laid over a working panel.

**A METAR always wins.** Where a field files its own observation, that is what
is shown and no WeatherKit data is involved. Apple answers for the large
majority of the world's airfields that file nothing at all, and for the
forecast and alerts, which a METAR cannot carry.

## Where it is shown, and what carries the mark

| Screen | WeatherKit data | Attribution |
| --- | --- | --- |
| **Airport panel → FORECAST** (`Views/WeatherForecastSection.swift`) | hourly strip, feels-like, humidity, pressure, UV | `WeatherAttributionRow`, last row of the section |
| **Airport panel → WEATHER ALERTS** | severe-weather alerts, each linking to the issuing authority | the FORECAST section's row, immediately below |
| **Map weather chip, collapsed** (`Views/WeatherChip.swift`) | temperature, symbol and conditions for a field that files no METAR | `collapsedAttribution` — the  Weather wordmark and a link, in a capsule under the chip |
| **Map weather chip, opened** | the same, for the field being passed and both ends of the route | `WeatherAttributionRow`, last row of the card |
| **Weather settings → SAMPLE** (`Views/WeatherSettingsPanel.swift`) | the sampled field's conditions, where it files no METAR | `WeatherAttributionRow`, under the sample |

Every one of those rows is drawn **only when Apple's data is actually on
screen** — a field with its own METAR shows no mark, because there is nothing
of Apple's to attribute.

## How the mark cannot go missing

`WeatherAttributionRow` (`Views/WeatherForecastSection.swift`) draws both
halves unconditionally:

- **The mark.** Apple's own combined artwork (light or dark, to match the
  theme) where `WeatherAttribution` has arrived; `AppleWeatherWordmark` — the
  literal ** Weather** text, U+F8FF being the Apple logo on every Apple
  platform — while the image is still downloading, and for good if the fetch
  never lands. There is no state in which the row draws neither.
- **The link.** `WeatherAttribution.legalPageURL` where the framework has
  answered, and `AppleWeatherService.legalPageURL` — the same page, as a
  constant — where it has not.

That second half is the fix made for this rejection. The row previously
dropped the legal link entirely whenever the attribution fetch had not
returned, so a slow CDN or a failed request produced a row with a sentence on
it and nothing to tap. The collapsed weather chip is the other fix: it showed
Apple's temperature with the mark one tap away, inside the card, rather than on
the screen the data was on.

`AppleWeatherService.loadAttribution()` fetches the mark once, on its own,
retried by the next caller if it fails — separately from the weather, because a
screen showing a cached forecast asks for no weather at all and used to
therefore never ask for the mark either.

## For the screen recording App Review asked for

Shortest route that shows every WeatherKit surface on a physical device:

1. Open the map. Let the weather chip settle on a field with no METAR — the
   temperature appears with ** Weather** and a link under it. Tap the link;
   Apple's legal page opens.
2. Tap the chip to open it. The card lists the fields, with Apple's combined
   mark and **Legal** as its last row.
3. Open the map toolbar's weather control → **Weather settings**. Its SAMPLE
   section carries the same row.
4. Back on the map, open any airport. Scroll to **FORECAST** — the hourly
   strip, the readings, and the attribution row beneath them. If the field has
   an alert, **WEATHER ALERTS** sits above it.

Put the recording in **App Review Information → Notes** in App Store Connect.
