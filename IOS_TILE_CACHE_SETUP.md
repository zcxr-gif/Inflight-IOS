# iOS Service-Worker Tile Caching — Build Setup

## Why
The map's `www/sw.js` service worker caches Mapbox tiles so the globe appears
instantly instead of visibly re-downloading tiles every session ("loading in and
out"). On Android this already works because the app uses the `https` scheme.

On iOS the app previously ran on the `capacitor://` scheme, where **service
workers are unavailable**, so the tile cache never ran. This change moves iOS to
the `https` scheme so the service worker can run.

## What changed in this repo
- `capacitor.config.json`
  - `server.iosScheme: "https"` — app origin becomes `https://inflight-secure`
    (a local virtual origin served by Capacitor; not a real DNS domain).
  - `ios.limitsNavigationsToAppBoundDomains: true` — required by Apple to enable
    service workers in WKWebView. This flag is **inert** until the Info.plist key
    below is added.
- `www/flight.js` — app self-detection no longer relies on the `capacitor:`
  scheme alone, so API/function calls keep routing to production under the new
  `https://inflight-secure` origin.

## REQUIRED native step (do this in the iOS project / build)
Apple only exposes service workers to WKWebView for **app-bound domains**. Add
this to the main app's `ios/App/App/Info.plist` (max 10 domains):

```xml
<key>WKAppBoundDomains</key>
<array>
    <string>inflight-secure</string>
    <string>inflight.info</string>
</array>
```

Notes:
- `inflight-secure` is the local app origin (must be listed for the SW to run on
  the bundled content).
- Cross-origin `fetch`/`XHR` (Mapbox, Supabase, backends) continues to work; the
  app-bound list governs WebView features/navigation, not ordinary network calls.
- If the `WKAppBoundDomains` key is omitted, the app still runs but the service
  worker stays disabled (same as before) — so this step is what actually turns
  tile caching on.

## One-time user impact
Switching schemes changes the WebView origin, so browser storage tied to the old
`capacitor://inflight-secure` origin (localStorage, auth session, local-only map
filters) is not carried over. Users sign in once more after the update; Pro
users' map filters restore automatically from Supabase cloud sync.

## How to verify on-device
Connect the device, open Safari ▸ Develop ▸ <device> ▸ the app's WebView, and
confirm the console logs `Map Tile Cache Service Worker Active`. Then pan/zoom,
relaunch, and revisit the same area — tiles should appear with no load-in.
