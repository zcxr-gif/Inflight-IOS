# Languages

The app's text is translated into Spanish, French, German, Italian,
Portuguese (Brazil), Russian, Japanese, Korean, Chinese (Simplified) and Hindi.
iOS picks the language from the phone's settings, or from Settings → Inflight →
Language for this app alone.

## Where the text lives

`InflightTracker/Shared/Localization/<language>.lproj/Localizable.strings`, one
table per language. It is in `Shared/` so the widget extension and the Live
Activity get the same tables as the app. Each key is the English text exactly as
the code draws it, so `en.lproj` maps every key to itself.

## How text reaches the tables

- **A literal handed to `Text`, `Button`, `Label` and so on** is looked up by
  SwiftUI itself.
- **Everything else** goes through `L(_:)` in `Shared/Localization/Localization.swift`.
  Every text-drawing call wraps its argument in `L()`: row titles, enum labels,
  and computed sentences reach the screen as a `String`, and SwiftUI draws a
  `String` verbatim. A string with no entry comes back unchanged, which is why
  wrapping callsigns, airport names and numbers is harmless.
- **A sentence with values in it** uses `Lf(_:_:)`: the key has a `%@` for each
  value, and every value is passed as text.

  ```swift
  Lf("%@ of %@ aircraft shown", String(shown), String(total))
  ```

  Translations may reorder the values with `%1$@` and `%2$@`.

## Adding a string

1. Write the English in code as usual. If it is not a literal passed straight to
   a SwiftUI view, make sure it is drawn through `L()`, or `Lf()` if it has
   values in it.
2. Add the same English as a key to every `Localizable.strings`, with its
   translation. A key missing from a language falls back to English, so nothing
   breaks while a translation is pending.

## What is not translated yet

Every screen draws through the tables. What stays English on purpose: callsigns,
registrations, airport and airline names, aircraft types, and anything the
server or Infinite Flight sends as text (METAR, ATIS, controller names, pilot
bios). A string built from a few pieces is translated as one key with `Lf()`;
if a sentence shows up in English, it is usually one that is still glued
together with `+` in code.
