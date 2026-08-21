# Aircraft marker artwork

`PlaneArtwork.swift` is generated. It holds the map marks as flat SVG path
data, pulled out of two upstream marker packs:

| Source | Licence | What it gives |
| --- | --- | --- |
| [Virtual Radar Server](https://github.com/vradarserver/vrs) — `VirtualRadar.WebSite/Site/Web/script/vrs/embeddedSvgs.js` | BSD 3-Clause | the size/engine-count families every airliner, turboprop and light aircraft draws as, plus the helicopter, balloon, glider and A340/A380 |
| [VRSCustomMarkers](https://github.com/rikgale/VRSCustomMarkers) — `MyMarkers1.html` | CC0 1.0 | the type-specific military, warbird, rotary and unmanned marks |

Both notices are reproduced in the generated file's header and, as the BSD
licence requires of a binary distribution, in the app's Acknowledgements panel.

## Regenerating

Clone both repos under `sources/` (or point `MARKER_SOURCES` at wherever they
are), extract the embedded SVGs, then run:

```sh
npm install svgpath playwright
node extract.js      # flattens the SVGs to transform-free path data
node gen-swift.js    # writes ios-native/InflightTracker/Map/PlaneArtwork.swift
```

`extract.js` renders each drawing in headless Chromium to resolve the nested
transforms and computed fills, so what it emits is the shape as drawn rather
than as authored. `sources.json` is the map from the artwork names the app uses
to the files they come from; adding a type means adding a line there, and a
line in `PlaneSprites.fleet` to say which sprite keys draw it and how big.
