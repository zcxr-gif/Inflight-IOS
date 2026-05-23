# Mapbox → Apple MapKit migration

This branch swaps the Mapbox GL JS basemap for Apple's native MapKit
(`MKMapView`) via a local Capacitor plugin. The goal is to ship the same UX
without depending on the Mapbox CDN or Mapbox tile API while inside the iOS
Capacitor wrapper.

## What changed

| Area | Before | After |
|------|--------|-------|
| Map renderer | Mapbox GL JS (WebGL in WebView) | Native `MKMapView` positioned behind a transparent WebView |
| Map SDK source | `api.mapbox.com` CDN script + style URLs | Local Capacitor plugin `inflight-mapkit/` |
| Tiles | Mapbox raster/vector tiles cached by `sw.js` | Apple tiles served natively (no app-side cache) |
| Access tokens | `MAPBOX_ACCESS_TOKEN` required | Not required for MapKit |
| Service worker | Cached Mapbox responses | No-op (lifecycle preserved) |
| JS surface | Real `mapboxgl` library | `www/mapkit-shim.js` — a small compatibility layer that exposes `window.mapboxgl` and routes calls to the native plugin |

Because there are 300+ `mapboxgl.*` call sites in `www/flight.js` (and more
in `sectorOpsHud.js`, `natTracksLayer.js`, `mapAnimator.js`,
`atcHighlights.js`, `flownPath3D.js`), this branch does **not** rewrite each
call site. Instead the shim layer makes the existing API surface keep
working — most of it backed by real MapKit primitives, the rest stubbed.

## Architecture

```
JS                                    Native (Swift)
─────────────────────────────────────────────────────────────────
flight.js / sectorOpsHud.js / …
   │
   ▼
window.mapboxgl  (mapkit-shim.js)     InflightMapkitPlugin (Swift)
   │     translates                          │
   │  • addSource + addLayer + setData       │
   │      ↓                                  ▼
   │  • setMarkers / setPolylines /     MapKitController
   │      setPolygons                       ├── MKMapView (behind WebView)
   │                                        ├── MKPolyline / MKPolygon overlays
   │  • setCamera / fitBounds               └── MKAnnotationView markers
   │
   └── Capacitor bridge ──────────────► CAP_PLUGIN(InflightMapkitPlugin, …)
```

The WebView is made transparent in `InflightMapkitPlugin.load()` so the
`MKMapView` inserted *below* it is visible. The HTML map containers
(`#live-flights-map-container`, `#sector-ops-map-fullscreen`) get
`background: transparent` and a `ResizeObserver` keeps the native
`MKMapView` frame in sync with each container's `getBoundingClientRect()`.

## What works in this PR

- Map creation, destruction, camera control (`setCenter`, `setZoom`, `flyTo`/`easeTo`/`jumpTo`, `fitBounds`)
- 8 named styles mapped to MapKit equivalents (`dark`, `light`, `satellite`, `outdoors`, `nav-dark`, `nav-light`, `traffic-night`, `traffic-day`)
- GeoJSON sources (`addSource`, `getSource().setData(…)`, `removeSource`)
- Layer types:
  - `symbol` / `circle` → `MKPointAnnotation` with a triangular plane glyph (rotation, color)
  - `line` → `MKPolyline` overlays (color, width, dash)
  - `fill` → `MKPolygon` overlays (fill + stroke color)
- `setFilter` for `==`, `!=`, `>`, `<`, `>=`, `<=`, `in`, `!in`, `has`, `!has`, `all`, `any`
- `setLayoutProperty(layerId, 'visibility', 'none' | 'visible')`
- `setPaintProperty(layerId, prop, value)` for constant values
- Standalone `new mapboxgl.Marker(...)`
- `LngLatBounds` math
- `on('load')`, `on('style.load')`, `on('click')`, `on('idle')`
- Tap events surfaced as a `mapTap` native listener and forwarded as `click`

## What is deferred / stubbed

These are intentionally not implemented in this PR. They either require
non-trivial work or have no direct MapKit equivalent:

1. **Style expressions beyond constants and `['get', 'prop']`.** Data-driven
   styling like `['interpolate', ['linear'], ['zoom'], …]` for `icon-size`,
   `circle-radius`, etc. falls through to defaults. The plane-glyph annotation
   ignores `icon-image` entirely.
2. **Feature-state hover effects** (`setFeatureState`, `feature-state` paint
   expressions). Calls are no-ops.
3. **`queryRenderedFeatures(...)`.** Returns `[]`. Use the new
   `annotationTap` plugin event for hit-testing — the native side already
   knows which annotation was tapped and reports its ID.
4. **HTML popups overlaid on the map.** `new mapboxgl.Popup(...)` is a
   structural no-op (methods chain so nothing crashes, but no UI renders).
   A follow-up could either (a) capture the popup HTML and project the
   anchor lat/lng each frame via a native projection helper, or (b) use
   `MKAnnotationView` callouts (loses HTML styling).
5. **Three.js / WebGL custom layers and `MercatorCoordinate.fromLngLat(...)`.**
   `flownPath3D.js` relies on these for the 3D flown path. The shim returns
   dummy `MercatorCoordinate` values so the module loads without throwing,
   but no 3D path renders. A native equivalent would need an
   `MKMultiPolyline` with altitude data plus a camera pitch — left as
   follow-up.
6. **`projection: 'globe'`.** MapKit renders on its own projection; the
   `setProjection` call is a no-op.
7. **Terrain / fog / sky / hillshade.** `setTerrain`, `setFog`, `setLight`,
   and DEM sources (`mapbox-dem`) are no-ops.
8. **`addImage` / `loadImage` for custom sprite icons.** Annotations always
   render the built-in plane glyph. Could be extended to receive PNG bytes
   and a per-feature icon name.

See the `_pushLayer`, `Popup`, and `MercatorCoordinate` blocks in
`www/mapkit-shim.js` and the `applyMapType` / `apply(view:annotation:)`
sections of `inflight-mapkit/ios/Plugin/MapKitController.swift` for the
exact extension points.

## Files

```
inflight-mapkit/                          local Capacitor plugin
├── package.json
├── InflightMapkit.podspec
├── dist/
│   ├── plugin.cjs.js
│   └── esm/{index.js,index.d.ts,web.js}
└── ios/Plugin/
    ├── InflightMapkitPlugin.swift        bridge methods + listener emit
    ├── InflightMapkitPlugin.m            CAP_PLUGIN macro registration
    └── MapKitController.swift            MKMapView wrapper + delegate

www/
├── mapkit-shim.js                        new — mapboxgl-compatible adapter
├── index.html                            loads the shim (Mapbox CDN removed)
└── sw.js                                 no-op (Mapbox cache removed)

codemagic.yaml                            installs ./inflight-mapkit before `cap add ios`
package.json                              adds inflight-mapkit as a file: dep
```

## Testing notes

This branch was not validated end-to-end in a simulator from this
environment — the container does not have Xcode. Before merging:

1. Run `npm install` locally; confirm `inflight-mapkit` resolves.
2. `npx cap sync ios`; confirm the plugin appears in `ios/App/Podfile`.
3. `pod install`; confirm `InflightMapkit.podspec` is picked up.
4. Build & run in a simulator. Open the live flights view and verify:
   - The native map background is visible.
   - Style-switcher buttons toggle between `MKMapType.standard` /
     `.satellite` / `.hybrid` / `.mutedStandard`.
   - Live flight markers appear as triangular plane glyphs that rotate
     with heading.
   - Pinned flown / planned routes render as polylines.
   - FIR / NAT polygons render with fill + stroke.
   - `fitBounds` after pinning a flight zooms to the route.
5. Check the JS console for `[mapkit-shim]` warnings — they signal calls
   that fell through to a stub.
